package loadbalancer

import (
	"sync"
	"time"
)

type Server struct {
	ID      string
	Address string
	RIF     int32 // accessed atomically
	Latency int64 // microseconds; accessed atomically
}

type ProbeResult struct {
	Timestamp time.Time // LB receipt time (paper fn. 9: never the server clock)
	RIF       int32
	Latency   int64 // microseconds
}

type ProbePoolEntry struct {
	Server     *Server
	ReceivedAt time.Time
	// RIF and RemainingUses are mutated after the entry is published to the
	// pool (overuse compensation and reuse accounting); access atomically.
	RIF           int32
	Latency       int64 // microseconds; immutable after publication
	RemainingUses int32
}

type Algorithm string

const (
	AlgorithmPrequal    Algorithm = "prequal"
	AlgorithmRoundRobin Algorithm = "roundrobin"
)

type ProbeMode string

const (
	ProbeModePerQuery ProbeMode = "per_query"
	ProbeModeTicker   ProbeMode = "ticker"
)

type Config struct {
	ProbeTimeout    time.Duration
	HealthCheckPath string
	Algorithm       Algorithm
	QRIF            float64
	RProbe          float64
	MinProbeRate    float64
	PoolCap         int
	PoolTTL         time.Duration
	RRemove         float64
	Delta           float64
	MaxReusePool    int
	RIFWindow       time.Duration
	ForwardTimeout  time.Duration // query deadline on the forward path (paper: 5s); 0 disables
	EnableMetrics   bool
	EnablePickLog   bool
	ProbeMode       ProbeMode     // ticker or per_query trigger
	ProbeInterval   time.Duration // used only for ticker
}

type Stats struct {
	TotalRequests      uint64
	SuccessfulRequests uint64
	FailedRequests     uint64
	AverageLatency     float64
	mutex              sync.RWMutex
}

// DefaultConfig mirrors the paper's baseline parameters (§5): pool size 16,
// probes age out after 1s, r_probe=3, r_remove=1, Q_RIF=2^-0.25, delta=1,
// and a 5s query deadline.
func DefaultConfig() Config {
	return Config{
		ProbeTimeout:    1 * time.Second,
		HealthCheckPath: "/health",
		Algorithm:       AlgorithmPrequal,
		QRIF:            0.84,
		RProbe:          3,
		MinProbeRate:    10,
		PoolCap:         16,
		PoolTTL:         1 * time.Second,
		RRemove:         1,
		Delta:           1,
		RIFWindow:       time.Second,
		MaxReusePool:    3,
		ForwardTimeout:  5 * time.Second,
		EnableMetrics:   false,
		EnablePickLog:   false,
		ProbeMode:       ProbeModePerQuery,
		ProbeInterval:   1 * time.Second,
	}
}
