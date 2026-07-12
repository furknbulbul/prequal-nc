package loadbalancer

import (
	"sync"
	"time"
)

type Server struct {
	ID      string
	Address string
	RIF     int32
	Latency int64
}

type ProbeResult struct {
	Timestamp time.Time
	RIF       int32
	Latency   int64
}

type ProbePoolEntry struct {
	Server        *Server
	ReceivedAt    time.Time
	RIF           int32
	Latency       int64
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
	ForwardTimeout  time.Duration
	EnableMetrics   bool
	EnablePickLog   bool
	ProbeMode       ProbeMode
	ProbeInterval   time.Duration
	AdaptiveProbe   bool
	RProbeMin       float64
	ProbeLoadLow    int32
	ProbeLoadHigh   int32
}

type Stats struct {
	TotalRequests      uint64
	SuccessfulRequests uint64
	FailedRequests     uint64
	AverageLatency     float64
	mutex              sync.RWMutex
}

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
		AdaptiveProbe:   false,
		RProbeMin:       1,
		ProbeLoadLow:    100,
		ProbeLoadHigh:   1000,
	}
}
