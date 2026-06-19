package loadbalancer

import (
	"context"
	"log/slog"
	"math/rand"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const probePoolCap = 16

type LoadBalancer struct {
	servers        []*Server
	probePool      []*ProbePoolEntry
	config         *Config
	stats          *Stats
	logger         *slog.Logger
	metrics        *Metrics
	mutex          sync.RWMutex
	rrIndex        uint32
	lastProbeNanos int64
}

func NewLoadBalancer(config *Config, logger *slog.Logger) *LoadBalancer {
	if config == nil {
		config = &Config{
			ProbeInterval:    time.Second,
			ProbeTimeout:     time.Second * 2,
			HealthCheckPath:  "/health",
			Algorithm:        AlgorithmPrequal,
			QRIF:             0.84,
		}
	}
	if config.Algorithm == "" {
		config.Algorithm = AlgorithmPrequal
	}
	if config.QRIF == 0 {
		config.QRIF = 0.84
	}
	if config.RProbe == 0 {
		config.RProbe = 3
	}
	if config.MinProbeRate == 0 {
		config.MinProbeRate = 1
	}

	return &LoadBalancer{
		servers:   make([]*Server, 0),
		probePool: make([]*ProbePoolEntry, 0, probePoolCap),
		config:    config,
		stats:     &Stats{},
		logger:    logger,
		metrics:   NewMetrics(),
	}
}

// onQueryArrival emits floor(RProbe) probes per query, plus one extra
// with probability frac(RProbe) — stochastic rounding via a Bernoulli
// trial. RProbe may be fractional and may be < 1. Expected probes per
// query equals RProbe exactly; per-query count is integer.
//
//	r=0.3 → 0 probes 70% of the time, 1 probe 30% of the time
//	r=1.0 → 1 probe always
//	r=2.7 → 2 probes 30% of the time, 3 probes 70% of the time
//	r=3.0 → 3 probes always
func (lb *LoadBalancer) onQueryArrival() {
	r := lb.config.RProbe
	if r <= 0 {
		return
	}
	count := int(r)
	if frac := r - float64(count); frac > 0 && rand.Float64() < frac {
		count++
	}
	if count == 0 {
		return
	}
	lb.triggerProbes(count)
}

// triggerProbes samples `count` distinct servers uniformly at random
// without replacement from the available replicas and probes them
// concurrently. Updates lastProbeNanos so the MinProbeRate enforcer
// can detect that the query-driven rate is meeting the floor.
func (lb *LoadBalancer) triggerProbes(count int) {
	lb.mutex.RLock()
	n := len(lb.servers)
	if n == 0 {
		lb.mutex.RUnlock()
		return
	}
	if count > n {
		count = n
	}
	perm := rand.Perm(n)[:count]
	targets := make([]*Server, count)
	for i, idx := range perm {
		targets[i] = lb.servers[idx]
	}
	lb.mutex.RUnlock()

	atomic.StoreInt64(&lb.lastProbeNanos, time.Now().UnixNano())

	for _, server := range targets {
		go func(srv *Server) {
			result := lb.probeServer(srv)
			lb.handleProbeResult(srv, result)
		}(server)
	}
}

func (lb *LoadBalancer) handleProbeResult(srv *Server, result *ProbeResult) {
	algorithm := string(lb.config.Algorithm)

	lb.mutex.Lock()
	srv.IsHealthy = result.IsHealthy
	if result.IsHealthy {
		srv.Latency = result.Latency
		atomic.StoreInt32(&srv.RIF, result.RIF)
		lb.appendPoolEntry(&ProbePoolEntry{
			Server:     srv,
			ReceivedAt: result.Timestamp,
			RIF:        result.RIF,
			Latency:    result.Latency,
		})
	}
	lb.mutex.Unlock()

	if result.IsHealthy {
		lb.metrics.serverHealth.WithLabelValues(srv.ID, algorithm).Set(1)
		lb.metrics.serverRIF.WithLabelValues(srv.ID, algorithm).Set(float64(result.RIF))
	} else {
		lb.metrics.serverHealth.WithLabelValues(srv.ID, algorithm).Set(0)
	}
}

// appendPoolEntry adds entry to the pool, evicting the oldest entry if
// the pool would exceed probePoolCap. Caller must hold lb.mutex.
func (lb *LoadBalancer) appendPoolEntry(entry *ProbePoolEntry) {
	lb.probePool = append(lb.probePool, entry)
	if len(lb.probePool) > probePoolCap {
		lb.probePool = lb.probePool[len(lb.probePool)-probePoolCap:]
	}
}

func (lb *LoadBalancer) probeServer(server *Server) *ProbeResult {
	ctx, cancel := context.WithTimeout(context.Background(), lb.config.ProbeTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "GET",
		"http://"+server.Address+lb.config.HealthCheckPath, nil)
	if err != nil {
		lb.logger.Error("Failed to create probe request",
			slog.String("server", server.ID),
			slog.String("error", err.Error()))
		return &ProbeResult{Timestamp: time.Now(), IsHealthy: false}
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		lb.logger.Error("Probe request failed",
			slog.String("server", server.ID),
			slog.String("error", err.Error()))
		return &ProbeResult{Timestamp: time.Now(), IsHealthy: false}
	}
	defer resp.Body.Close()

	var rif int32
	if s := resp.Header.Get("X-Requests-In-Flight"); s != "" {
		if v, err := strconv.ParseInt(s, 10, 32); err == nil {
			rif = int32(v)
		}
	}

	var latency int64
	if s := resp.Header.Get("X-Latency-Estimate-Ms"); s != "" {
		if v, err := strconv.ParseInt(s, 10, 64); err == nil {
			latency = v
		}
	}

	timestamp := time.Now()
	if s := resp.Header.Get("X-Probe-Response-Time"); s != "" {
		if v, err := strconv.ParseInt(s, 10, 64); err == nil {
			timestamp = time.Unix(0, v)
		}
	}

	return &ProbeResult{
		Timestamp: timestamp,
		RIF:       rif,
		Latency:   latency,
		IsHealthy: resp.StatusCode == http.StatusOK,
	}
}

func (lb *LoadBalancer) AddServer(server *Server) {
	lb.mutex.Lock()
	defer lb.mutex.Unlock()
	lb.servers = append(lb.servers, server)
}

func (lb *LoadBalancer) SelectServer() *Server {
	if lb.config.Algorithm == AlgorithmRoundRobin {
		return lb.selectServerRR()
	}
	return lb.selectServerPrequal()
}

func (lb *LoadBalancer) selectServerRR() *Server {
	lb.mutex.RLock()
	defer lb.mutex.RUnlock()

	if len(lb.servers) == 0 {
		return nil
	}

	healthyServers := make([]*Server, 0, len(lb.servers))
	for _, server := range lb.servers {
		if server.IsHealthy {
			healthyServers = append(healthyServers, server)
		}
	}

	if len(healthyServers) == 0 {
		return nil
	}

	index := atomic.AddUint32(&lb.rrIndex, 1)
	return healthyServers[int(index-1)%len(healthyServers)]
}

// selectServerPrequal runs HCL over the whole probe pool: classify each
// pool entry as hot/cold by comparing its RIF against the Q_RIF quantile
// of pool RIF values; pick lowest-latency cold, else lowest-RIF hot.
// If the pool is empty or all its servers are unhealthy, fall back to a
// uniformly random healthy server (paper §4).
func (lb *LoadBalancer) selectServerPrequal() *Server {
	lb.mutex.RLock()
	defer lb.mutex.RUnlock()

	if len(lb.probePool) == 0 {
		return randomHealthy(lb.servers)
	}

	entries := make([]*ProbePoolEntry, 0, len(lb.probePool))
	for _, e := range lb.probePool {
		if e.Server.IsHealthy {
			entries = append(entries, e)
		}
	}

	if len(entries) == 0 {
		return randomHealthy(lb.servers)
	}

	rifs := make([]int32, len(entries))
	for i, e := range entries {
		rifs[i] = e.RIF
	}
	sort.Slice(rifs, func(i, j int) bool { return rifs[i] < rifs[j] })
	idx := int(float64(len(rifs)-1) * lb.config.QRIF)
	if idx < 0 {
		idx = 0
	}
	if idx >= len(rifs) {
		idx = len(rifs) - 1
	}
	threshold := rifs[idx]

	var hot, cold []*ProbePoolEntry
	for _, e := range entries {
		if e.RIF > threshold {
			hot = append(hot, e)
		} else {
			cold = append(cold, e)
		}
	}

	if len(cold) > 0 {
		best := cold[0]
		for _, e := range cold[1:] {
			if e.Latency < best.Latency {
				best = e
			}
		}
		return best.Server
	}

	best := hot[0]
	for _, e := range hot[1:] {
		if e.RIF < best.RIF {
			best = e
		}
	}
	return best.Server
}

func randomHealthy(servers []*Server) *Server {
	healthy := make([]*Server, 0, len(servers))
	for _, s := range servers {
		if s.IsHealthy {
			healthy = append(healthy, s)
		}
	}
	if len(healthy) == 0 {
		return nil
	}
	return healthy[rand.Intn(len(healthy))]
}

func (lb *LoadBalancer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	atomic.AddUint64(&lb.stats.TotalRequests, 1)

	lb.onQueryArrival()

	server := lb.SelectServer()
	if server == nil {
		lb.logger.Error("No available servers")
		atomic.AddUint64(&lb.stats.FailedRequests, 1)
		http.Error(w, "No available servers", http.StatusServiceUnavailable)
		return
	}

	start := time.Now()
	lb.forwardRequest(server, w, r)
	duration := time.Since(start)

	algorithm := string(lb.config.Algorithm)
	lb.metrics.requestDuration.WithLabelValues(algorithm).Observe(duration.Seconds())
	atomic.AddUint64(&lb.stats.SuccessfulRequests, 1)
}

func (lb *LoadBalancer) forwardRequest(server *Server, w http.ResponseWriter, r *http.Request) {
	algorithm := string(lb.config.Algorithm)
	lb.metrics.activeRequests.WithLabelValues(algorithm).Inc()

	defer func() {
		lb.metrics.activeRequests.WithLabelValues(algorithm).Dec()
	}()

	targetURL, _ := url.Parse("http://" + server.Address)
	proxy := httputil.NewSingleHostReverseProxy(targetURL)

	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		lb.logger.Error("Proxy error", slog.String("error", err.Error()))
		atomic.AddUint64(&lb.stats.FailedRequests, 1)
		http.Error(w, "Service unavailable", http.StatusServiceUnavailable)
	}

	proxy.ServeHTTP(w, r)
}
