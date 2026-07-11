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
	RemainingUses int //not used now
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

func DefaultConfig() Config {
	return Config{
		ProbeTimeout:    1 * time.Second,
		HealthCheckPath: "/health",
		Algorithm:       AlgorithmPrequal,
		QRIF:            0.84,
		RProbe:          1.3,
		MinProbeRate:    10,
		PoolCap:         16,
		PoolTTL:         300 * time.Millisecond,
		RRemove:         0.2,
		Delta:           1,
		RIFWindow:       time.Second,
		MaxReusePool:    3,
		EnableMetrics:   false,
		EnablePickLog:   false,
		ProbeMode:       ProbeModePerQuery,
		ProbeInterval:   1 * time.Second,
	}
}
