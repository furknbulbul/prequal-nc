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

type LoadBalancer struct {
	servers         []*Server
	probePool       []*ProbePoolEntry
	config          *Config
	stats           *Stats
	logger          *slog.Logger
	metrics         *Metrics
	mutex           sync.RWMutex
	rrIndex         uint32
	removeDebt      float64
	removeAltOldest bool
	lastProbeNanos  int64
	stopCh          chan struct{}
}

const (
	poolThreshold = 2 // if there is less than or equal to this threshold pool entries, uniformly select from available replicas.
)

func NewLoadBalancer(cfg Config, logger *slog.Logger) *LoadBalancer {
	lb := &LoadBalancer{
		servers:   make([]*Server, 0),
		probePool: make([]*ProbePoolEntry, 0, cfg.PoolCap),
		config:    &cfg,
		stats:     &Stats{},
		logger:    logger,
		metrics:   NewMetrics(),
		stopCh:    make(chan struct{}),
	}
	if cfg.MinProbeRate > 0 {
		go lb.idleProbeLoop() // this is a goroutine
	}
	return lb
}

func (lb *LoadBalancer) Stop() {
	close(lb.stopCh)
}

func (lb *LoadBalancer) idleProbeLoop() {
	maxIdle := time.Duration(float64(time.Second) / lb.config.MinProbeRate)
	if maxIdle <= 0 {
		return
	}
	t := time.NewTicker(maxIdle / 2)
	defer t.Stop()
	for {
		select {
		case <-lb.stopCh: // if lb.close() is called
			return
		case <-t.C:
			last := atomic.LoadInt64(&lb.lastProbeNanos)
			if time.Since(time.Unix(0, last)) >= maxIdle {
				lb.triggerProbes(1)
			}
		}
	}
}

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
			Server:        srv,
			ReceivedAt:    result.Timestamp,
			RIF:           result.RIF,
			Latency:       result.Latency,
			RemainingUses: lb.computeBReuse(),
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

func (lb *LoadBalancer) appendPoolEntry(entry *ProbePoolEntry) {
	lb.probePool = append(lb.probePool, entry)
	if len(lb.probePool) > lb.config.PoolCap {
		lb.probePool = lb.probePool[len(lb.probePool)-lb.config.PoolCap:]
	}
}

func (lb *LoadBalancer) computeBReuse() int {
	n := len(lb.servers)
	if n == 0 {
		return 1
	}
	m := float64(lb.config.PoolCap)
	denom := (1-m/float64(n))*lb.config.RProbe - lb.config.RRemove
	bReuse := 1.0
	if denom > 0 {
		if v := (1 + lb.config.Delta) / denom; v > 1 {
			bReuse = v
		}
	}
	floor := int(bReuse)
	if frac := bReuse - float64(floor); frac > 0 && rand.Float64() < frac {
		floor++
	}
	if floor < 1 {
		floor = 1
	}
	return floor
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

func (lb *LoadBalancer) selectServerPrequal() *Server {
	lb.mutex.Lock()
	defer lb.mutex.Unlock()

	lb.sweepExpiredLocked()

	if len(lb.probePool) <= poolThreshold {
		return randomHealthy(lb.servers)
	}

	healthyIdx := make([]int, 0, len(lb.probePool))
	for i, e := range lb.probePool {
		if e.Server.IsHealthy {
			healthyIdx = append(healthyIdx, i)
		}
	}
	if len(healthyIdx) == 0 {
		return randomHealthy(lb.servers)
	}

	rifs := make([]int32, len(healthyIdx))
	for i, idx := range healthyIdx {
		rifs[i] = lb.probePool[idx].RIF
	}
	sort.Slice(rifs, func(i, j int) bool { return rifs[i] < rifs[j] })
	qIdx := int(float64(len(rifs)-1) * lb.config.QRIF)
	if qIdx < 0 {
		qIdx = 0
	}
	if qIdx >= len(rifs) {
		qIdx = len(rifs) - 1
	}
	threshold := rifs[qIdx]

	bestCold, bestHot := -1, -1
	for _, idx := range healthyIdx {
		e := lb.probePool[idx]
		if e.RIF > threshold {
			if bestHot < 0 || e.RIF < lb.probePool[bestHot].RIF {
				bestHot = idx
			}
		} else {
			if bestCold < 0 || e.Latency < lb.probePool[bestCold].Latency {
				bestCold = idx
			}
		}
	}

	winnerIdx := bestCold
	if winnerIdx < 0 {
		winnerIdx = bestHot
	}
	if winnerIdx < 0 {
		return randomHealthy(lb.servers)
	}

	winner := lb.probePool[winnerIdx]
	winner.RemainingUses--
	if winner.RemainingUses <= 0 {
		lb.probePool = append(lb.probePool[:winnerIdx], lb.probePool[winnerIdx+1:]...)
	}
	return winner.Server
}

func (lb *LoadBalancer) sweepExpiredLocked() {
	if lb.config.PoolTTL <= 0 || len(lb.probePool) == 0 {
		return
	}
	cutoff := time.Now().Add(-lb.config.PoolTTL)
	kept := lb.probePool[:0]
	for _, e := range lb.probePool {
		if e.ReceivedAt.After(cutoff) {
			kept = append(kept, e)
		}
	}
	lb.probePool = kept
}

func (lb *LoadBalancer) applyRRemove() {
	if lb.config.RRemove <= 0 {
		return
	}
	lb.mutex.Lock()
	defer lb.mutex.Unlock()

	lb.removeDebt += lb.config.RRemove
	n := int(lb.removeDebt)
	lb.removeDebt -= float64(n)
	for i := 0; i < n && len(lb.probePool) > 0; i++ {
		if lb.removeAltOldest {
			lb.removeOldestLocked()
		} else {
			lb.removeWorstLocked()
		}
		lb.removeAltOldest = !lb.removeAltOldest
	}
}

func (lb *LoadBalancer) removeOldestLocked() {
	if len(lb.probePool) == 0 {
		return
	}
	oldest := 0
	for i, e := range lb.probePool {
		if e.ReceivedAt.Before(lb.probePool[oldest].ReceivedAt) {
			oldest = i
		}
	}
	lb.probePool = append(lb.probePool[:oldest], lb.probePool[oldest+1:]...)
}

func (lb *LoadBalancer) removeWorstLocked() {
	if len(lb.probePool) == 0 {
		return
	}
	rifs := make([]int32, len(lb.probePool))
	for i, e := range lb.probePool {
		rifs[i] = e.RIF
	}
	sort.Slice(rifs, func(i, j int) bool { return rifs[i] < rifs[j] })
	qIdx := int(float64(len(rifs)-1) * lb.config.QRIF)
	if qIdx < 0 {
		qIdx = 0
	}
	if qIdx >= len(rifs) {
		qIdx = len(rifs) - 1
	}
	threshold := rifs[qIdx]

	worstHot, worstCold := -1, -1
	for i, e := range lb.probePool {
		if e.RIF > threshold {
			if worstHot < 0 || e.RIF > lb.probePool[worstHot].RIF {
				worstHot = i
			}
		} else {
			if worstCold < 0 || e.Latency > lb.probePool[worstCold].Latency {
				worstCold = i
			}
		}
	}
	victim := worstHot
	if victim < 0 {
		victim = worstCold
	}
	if victim < 0 {
		return
	}
	lb.probePool = append(lb.probePool[:victim], lb.probePool[victim+1:]...)
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

	lb.applyRRemove()

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
