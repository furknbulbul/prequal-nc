package loadbalancer

import (
	"context"
	"io"
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

var probeClient = &http.Client{
	Timeout: 2 * time.Second,
	Transport: &http.Transport{
		MaxIdleConns:        10000,
		MaxIdleConnsPerHost: 2000,
		IdleConnTimeout:     30 * time.Second,
	},
}

var forwardTransport = &http.Transport{
	MaxIdleConns:        10000,
	MaxIdleConnsPerHost: 2000,
	IdleConnTimeout:     30 * time.Second,
}

type poolSnapshot struct {
	entries []*ProbePoolEntry
}

type LoadBalancer struct {
	servers         []*Server
	poolPtr         atomic.Pointer[poolSnapshot]
	poolWriteMutex  sync.Mutex
	removeDebt      float64
	removeAltOldest bool
	recentPicks     [recentPicksCap]pickRecord
	recentPicksLen  int
	recentPicksIdx  int
	picksMutex      sync.Mutex
	rifDist         *RIFDistribution
	config          *Config
	stats           *Stats
	logger          *slog.Logger
	metrics         *Metrics
	rrIndex         uint32
	lastProbeNanos  int64
	stopCh          chan struct{}
	probeStats      ProbeStats
}

type ProbeStats struct {
	Triggered   uint64
	Succeeded   uint64
	FailedError uint64
	FailedHTTP  uint64
	PoolEmpty   uint64
	NoWinner    uint64
}

const (
	recentPicksCap = 100 // for debug
)

type pickRecord struct {
	Time          time.Time
	Winner        string
	Class         string
	QRIFThreshold int32
	PoolSize      int
	EligibleCount int
}

func NewLoadBalancer(cfg Config, logger *slog.Logger) *LoadBalancer {
	window := cfg.RIFWindow
	if window <= 0 {
		window = cfg.PoolTTL
	}
	lb := &LoadBalancer{
		servers: make([]*Server, 0),
		rifDist: NewRIFDistribution(window),
		config:  &cfg,
		stats:   &Stats{},
		logger:  logger,
		metrics: NewMetrics(),
		stopCh:  make(chan struct{}),
	}
	lb.poolPtr.Store(&poolSnapshot{entries: make([]*ProbePoolEntry, 0, cfg.PoolCap)})
	if cfg.Algorithm == AlgorithmPrequal {
		switch cfg.ProbeMode {
		case ProbeModeTicker:
			go lb.runTickerProbeLoop()
		default:
			if cfg.MinProbeRate > 0 {
				go lb.idleProbeLoop()
			}
		}
	}
	return lb
}

func (lb *LoadBalancer) runTickerProbeLoop() {
	interval := lb.config.ProbeInterval
	if interval <= 0 {
		interval = 1 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-lb.stopCh:
			return
		case <-t.C:
			lb.triggerProbes(len(lb.servers))
		}
	}
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
				lb.triggerProbes(int(lb.config.RProbe))
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
	n := len(lb.servers)
	if n == 0 {
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
	atomic.StoreInt64(&lb.lastProbeNanos, time.Now().UnixNano())

	algorithm := string(lb.config.Algorithm)
	metricsOn := lb.config.EnableMetrics
	for _, server := range targets {
		atomic.AddUint64(&lb.probeStats.Triggered, 1)
		if metricsOn {
			lb.metrics.probesTriggered.WithLabelValues(algorithm).Inc()
		}
		go func(srv *Server) { // spawns a goroutine
			if metricsOn {
				lb.metrics.probeInflight.WithLabelValues(algorithm).Inc()
			}
			start := time.Now()
			result := lb.probeServer(srv)
			if metricsOn {
				lb.metrics.probeDuration.WithLabelValues(algorithm).Observe(time.Since(start).Seconds())
				lb.metrics.probeInflight.WithLabelValues(algorithm).Dec()
			}
			lb.handleProbeResult(srv, result)
		}(server)
	}
}

func (lb *LoadBalancer) handleProbeResult(srv *Server, result *ProbeResult) {
	if result == nil {
		return
	}
	algorithm := string(lb.config.Algorithm)
	metricsOn := lb.config.EnableMetrics
	atomic.AddUint64(&lb.probeStats.Succeeded, 1)
	if metricsOn {
		lb.metrics.probesSucceeded.WithLabelValues(algorithm).Inc()
	}
	nServers := len(lb.servers)

	srv.Latency = result.Latency
	atomic.StoreInt32(&srv.RIF, result.RIF)

	entry := &ProbePoolEntry{
		Server:        srv,
		ReceivedAt:    result.Timestamp,
		RIF:           result.RIF,
		Latency:       result.Latency,
		RemainingUses: lb.computeBReuse(nServers),
	}
	lb.poolWriteMutex.Lock()
	cur := lb.poolPtr.Load().entries
	if lb.config.PoolTTL > 0 && len(cur) > 0 {
		cutoff := time.Now().Add(-lb.config.PoolTTL)
		pruned := make([]*ProbePoolEntry, 0, len(cur))
		for _, e := range cur {
			if e.ReceivedAt.After(cutoff) {
				pruned = append(pruned, e)
			}
		}
		cur = pruned
	}
	next := appendPool(cur, entry, lb.config.PoolCap)
	lb.poolPtr.Store(&poolSnapshot{entries: next})
	poolSize := len(next)
	lb.poolWriteMutex.Unlock()

	lb.rifDist.Observe(result.RIF, result.Timestamp)
	if metricsOn {
		lb.metrics.serverHealth.WithLabelValues(srv.ID, algorithm).Set(1)
		lb.metrics.serverRIF.WithLabelValues(srv.ID, algorithm).Set(float64(result.RIF))
		lb.metrics.poolSize.WithLabelValues(algorithm).Set(float64(poolSize))
	}
}

func appendPool(pool []*ProbePoolEntry, entry *ProbePoolEntry, cap int) []*ProbePoolEntry {
	next := make([]*ProbePoolEntry, 0, cap+1)
	next = append(next, pool...)
	next = append(next, entry)
	if len(next) > cap {
		next = next[1:]
	}
	return next
}

// not used
func (lb *LoadBalancer) computeBReuse(n int) int {
	if n == 0 {
		return 1
	}
	m := float64(lb.config.PoolCap)
	denom := (1-m/float64(n))*lb.config.RProbe - lb.config.RRemove
	bReuse := 1.0
	if denom > 0 { // if pool cap > nOfServers, denom is < 0
		if v := (1 + lb.config.Delta) / denom; v > 1 {
			bReuse = v
		}
	}
	floor := int(bReuse)
	if frac := bReuse - float64(floor); frac > 0 && rand.Float64() < frac {
		floor++
	}

	if floor > lb.config.MaxReusePool {
		floor = lb.config.MaxReusePool
	}

	return floor
}

func (lb *LoadBalancer) probeServer(server *Server) *ProbeResult {
	algorithm := string(lb.config.Algorithm)
	ctx, cancel := context.WithTimeout(context.Background(), lb.config.ProbeTimeout)
	defer cancel()

	metricsOn := lb.config.EnableMetrics
	req, err := http.NewRequestWithContext(ctx, "GET",
		"http://"+server.Address+lb.config.HealthCheckPath, nil)
	if err != nil {
		atomic.AddUint64(&lb.probeStats.FailedError, 1)
		if metricsOn {
			lb.metrics.probesFailed.WithLabelValues(algorithm, "build_req").Inc()
		}
		lb.logger.Error("Failed to create probe request",
			slog.String("server", server.ID),
			slog.String("error", err.Error()))
		return nil
	}

	resp, err := probeClient.Do(req)
	if err != nil {
		atomic.AddUint64(&lb.probeStats.FailedError, 1)
		reason := "transport"
		if ctx.Err() == context.DeadlineExceeded {
			reason = "timeout"
		}
		if metricsOn {
			lb.metrics.probesFailed.WithLabelValues(algorithm, reason).Inc()
		}
		lb.logger.Error("Probe request failed",
			slog.String("server", server.ID),
			slog.String("reason", reason),
			slog.String("error", err.Error()))
		return nil
	}
	defer func() {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}()
	if resp.StatusCode/100 != 2 {
		atomic.AddUint64(&lb.probeStats.FailedHTTP, 1)
		if metricsOn {
			lb.metrics.probesFailed.WithLabelValues(algorithm, "http_status").Inc()
		}
		return nil
	}

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
	}
}

func (lb *LoadBalancer) AddServer(server *Server) {
	lb.servers = append(lb.servers, server)
}

func (lb *LoadBalancer) SelectServer() *Server {
	if lb.config.Algorithm == AlgorithmRoundRobin {
		return lb.selectServerRR()
	}
	return lb.selectServerPrequal()
}

func (lb *LoadBalancer) selectServerRR() *Server {
	if len(lb.servers) == 0 {
		return nil
	}
	index := atomic.AddUint32(&lb.rrIndex, 1)
	return lb.servers[int(index-1)%len(lb.servers)]
}

func (lb *LoadBalancer) selectServerPrequal() *Server {
	theta, _ := lb.rifDist.Quantile(lb.config.QRIF, time.Now())

	entries := lb.poolPtr.Load().entries
	poolSize := len(entries)

	algorithm := string(lb.config.Algorithm)
	metricsOn := lb.config.EnableMetrics
	pickLogOn := lb.config.EnablePickLog
	if len(entries) == 0 {
		srv := lb.randomServer()
		atomic.AddUint64(&lb.probeStats.PoolEmpty, 1)
		if metricsOn {
			lb.metrics.pickClass.WithLabelValues(algorithm, "no-pool").Inc()
		}
		if pickLogOn {
			lb.recordPick(srv, "no-pool", 0, poolSize, 0)
		}
		return srv
	}

	var cutoff time.Time
	ttlEnabled := lb.config.PoolTTL > 0
	if ttlEnabled {
		cutoff = time.Now().Add(-lb.config.PoolTTL)
	}

	var bestHot, bestCold *ProbePoolEntry
	fresh := 0
	for _, e := range entries {
		if ttlEnabled && e.ReceivedAt.Before(cutoff) {
			continue
		}
		fresh++
		if e.RIF > theta {
			if bestHot == nil || e.RIF < bestHot.RIF {
				bestHot = e
			}
		} else {
			if bestCold == nil || e.Latency < bestCold.Latency {
				bestCold = e
			}
		}
	}

	if fresh == 0 {
		srv := lb.randomServer()
		atomic.AddUint64(&lb.probeStats.PoolEmpty, 1)
		if metricsOn {
			lb.metrics.pickClass.WithLabelValues(algorithm, "no-pool").Inc()
		}
		if pickLogOn {
			lb.recordPick(srv, "no-pool", 0, poolSize, 0)
		}
		return srv
	}

	winner := bestCold
	class := "cold"
	if winner == nil {
		winner = bestHot
		class = "hot"
	}
	if winner == nil {
		srv := lb.randomServer()
		atomic.AddUint64(&lb.probeStats.NoWinner, 1)
		if metricsOn {
			lb.metrics.pickClass.WithLabelValues(algorithm, "no-winner").Inc()
		}
		if pickLogOn {
			lb.recordPick(srv, "no-winner", theta, poolSize, fresh)
		}
		return srv
	}

	if metricsOn {
		lb.metrics.pickClass.WithLabelValues(algorithm, class).Inc()
	}
	if pickLogOn {
		lb.recordPick(winner.Server, class, theta, poolSize, fresh)
	}
	return winner.Server
}

func (lb *LoadBalancer) randomServer() *Server {
	if len(lb.servers) == 0 {
		return nil
	}
	return lb.servers[rand.Intn(len(lb.servers))]
}

func (lb *LoadBalancer) recordPick(srv *Server, class string, threshold int32, poolSize, eligible int) {
	id := ""
	if srv != nil {
		id = srv.ID
	}
	rec := pickRecord{
		Time:          time.Now(),
		Winner:        id,
		Class:         class,
		QRIFThreshold: threshold,
		PoolSize:      poolSize,
		EligibleCount: eligible,
	}
	lb.picksMutex.Lock()
	lb.recentPicks[lb.recentPicksIdx] = rec
	lb.recentPicksIdx = (lb.recentPicksIdx + 1) % recentPicksCap
	if lb.recentPicksLen < recentPicksCap {
		lb.recentPicksLen++
	}
	lb.picksMutex.Unlock()
}

// not used
func (lb *LoadBalancer) applyRRemove() {
	if lb.config.RRemove <= 0 {
		return
	}
	lb.poolWriteMutex.Lock()
	defer lb.poolWriteMutex.Unlock()

	lb.removeDebt += lb.config.RRemove
	n := int(lb.removeDebt)
	lb.removeDebt -= float64(n)
	if n == 0 {
		return
	}

	cur := lb.poolPtr.Load().entries
	if len(cur) == 0 {
		return
	}
	next := make([]*ProbePoolEntry, len(cur))
	copy(next, cur)
	for i := 0; i < n && len(next) > 0; i++ {
		if lb.removeAltOldest {
			next = removeOldest(next)
		} else {
			next = removeWorst(next, lb.config.QRIF)
		}
		lb.removeAltOldest = !lb.removeAltOldest
	}
	lb.poolPtr.Store(&poolSnapshot{entries: next})
}

func removeOldest(pool []*ProbePoolEntry) []*ProbePoolEntry {
	if len(pool) == 0 {
		return pool
	}
	return pool[1:]
}

func removeWorst(pool []*ProbePoolEntry, qrif float64) []*ProbePoolEntry {
	if len(pool) == 0 {
		return pool
	}
	rifs := make([]int32, 0, len(pool))
	for _, e := range pool {
		rifs = append(rifs, e.RIF)
	}
	sort.Slice(rifs, func(i, j int) bool { return rifs[i] < rifs[j] })
	qIdx := int(float64(len(rifs)-1) * qrif)
	if qIdx < 0 {
		qIdx = 0
	}
	if qIdx >= len(rifs) {
		qIdx = len(rifs) - 1
	}
	threshold := rifs[qIdx]

	var worstHotRIF int32
	var worstColdLatency int64
	worstHotIdx := -1
	worstColdIdx := -1
	for i, e := range pool {
		if e.RIF > threshold {
			if worstHotIdx == -1 || e.RIF > worstHotRIF {
				worstHotIdx = i
				worstHotRIF = e.RIF
			}
		} else {
			if worstColdIdx == -1 || e.Latency > worstColdLatency {
				worstColdIdx = i
				worstColdLatency = e.Latency
			}
		}
	}
	victimIdx := worstHotIdx
	if victimIdx == -1 {
		victimIdx = worstColdIdx
	}
	if victimIdx == -1 {
		return pool
	}
	next := make([]*ProbePoolEntry, 0, len(pool)-1)
	next = append(next, pool[:victimIdx]...)
	next = append(next, pool[victimIdx+1:]...)
	return next
}

func (lb *LoadBalancer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	atomic.AddUint64(&lb.stats.TotalRequests, 1)

	if lb.config.Algorithm == AlgorithmPrequal && lb.config.ProbeMode != ProbeModeTicker {
		go lb.onQueryArrival()
	}

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

	if lb.config.EnableMetrics {
		algorithm := string(lb.config.Algorithm)
		lb.metrics.requestDuration.WithLabelValues(algorithm).Observe(duration.Seconds())
	}
	atomic.AddUint64(&lb.stats.SuccessfulRequests, 1)
}

func (lb *LoadBalancer) forwardRequest(server *Server, w http.ResponseWriter, r *http.Request) {
	if lb.config.EnableMetrics {
		algorithm := string(lb.config.Algorithm)
		lb.metrics.activeRequests.WithLabelValues(algorithm).Inc()
		defer lb.metrics.activeRequests.WithLabelValues(algorithm).Dec()
	}

	targetURL, _ := url.Parse("http://" + server.Address)
	proxy := httputil.NewSingleHostReverseProxy(targetURL)
	proxy.Transport = forwardTransport
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		lb.logger.Error("Proxy error", slog.String("error", err.Error()))
		atomic.AddUint64(&lb.stats.FailedRequests, 1)
		http.Error(w, "Service unavailable", http.StatusServiceUnavailable)
	}
	proxy.ServeHTTP(w, r)
}

type PoolEntrySnapshot struct {
	Server     string `json:"server"`
	RIF        int32  `json:"rif"`
	LatencyMs  int64  `json:"latency_ms"`
	AgeMs      int64  `json:"age_ms"`
	ReusesLeft int    `json:"reuses_left"`
}

type PickSnapshot struct {
	Time          time.Time `json:"t"`
	Winner        string    `json:"winner"`
	Class         string    `json:"class"`
	QRIFThreshold int32     `json:"q_rif_threshold"`
	PoolSize      int       `json:"pool_size"`
	EligibleCount int       `json:"eligible_count"`
}

type DebugSnapshot struct {
	Algorithm   string              `json:"algorithm"`
	Servers     []string            `json:"servers"`
	PoolCap     int                 `json:"pool_cap"`
	PoolSize    int                 `json:"pool_size"`
	Pool        []PoolEntrySnapshot `json:"pool"`
	RecentPicks []PickSnapshot      `json:"recent_picks"`
	ProbeStats  ProbeStatsSnapshot  `json:"probe_stats"`
}

type ProbeStatsSnapshot struct {
	Triggered   uint64 `json:"triggered"`
	Succeeded   uint64 `json:"succeeded"`
	FailedError uint64 `json:"failed_error"`
	FailedHTTP  uint64 `json:"failed_http"`
	PoolEmpty   uint64 `json:"pool_empty"`
	NoWinner    uint64 `json:"no_winner"`
}

func (lb *LoadBalancer) DebugSnapshot() DebugSnapshot {
	now := time.Now()

	entries := lb.poolPtr.Load().entries
	pool := make([]PoolEntrySnapshot, 0, len(entries))
	for _, e := range entries {
		pool = append(pool, PoolEntrySnapshot{
			Server:     e.Server.ID,
			RIF:        e.RIF,
			LatencyMs:  e.Latency,
			AgeMs:      now.Sub(e.ReceivedAt).Milliseconds(),
			ReusesLeft: e.RemainingUses,
		})
	}
	sort.Slice(pool, func(i, j int) bool { return pool[i].Server < pool[j].Server })

	// Walk the picks ring newest -> oldest under picksMu.
	lb.picksMutex.Lock()
	picks := make([]PickSnapshot, 0, lb.recentPicksLen)
	for k := 0; k < lb.recentPicksLen; k++ {
		idx := (lb.recentPicksIdx - 1 - k + recentPicksCap) % recentPicksCap
		p := lb.recentPicks[idx]
		picks = append(picks, PickSnapshot{
			Time:          p.Time,
			Winner:        p.Winner,
			Class:         p.Class,
			QRIFThreshold: p.QRIFThreshold,
			PoolSize:      p.PoolSize,
			EligibleCount: p.EligibleCount,
		})
	}
	lb.picksMutex.Unlock()

	servers := make([]string, 0, len(lb.servers))
	for _, s := range lb.servers {
		servers = append(servers, s.ID)
	}

	return DebugSnapshot{
		Algorithm:   string(lb.config.Algorithm),
		Servers:     servers,
		PoolCap:     lb.config.PoolCap,
		PoolSize:    len(pool),
		Pool:        pool,
		RecentPicks: picks,
		ProbeStats: ProbeStatsSnapshot{
			Triggered:   atomic.LoadUint64(&lb.probeStats.Triggered),
			Succeeded:   atomic.LoadUint64(&lb.probeStats.Succeeded),
			FailedError: atomic.LoadUint64(&lb.probeStats.FailedError),
			FailedHTTP:  atomic.LoadUint64(&lb.probeStats.FailedHTTP),
			PoolEmpty:   atomic.LoadUint64(&lb.probeStats.PoolEmpty),
			NoWinner:    atomic.LoadUint64(&lb.probeStats.NoWinner),
		},
	}
}
