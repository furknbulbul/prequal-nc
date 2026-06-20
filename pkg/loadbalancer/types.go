package loadbalancer

import (
	"sync"
	"time"
)

type Server struct {
	ID        string
	Address   string
	RIF       int32
	Latency   int64
	IsHealthy bool
}

type ProbeResult struct {
	Timestamp time.Time
	RIF       int32
	Latency   int64
	IsHealthy bool
}

type ProbePoolEntry struct {
	Server        *Server
	ReceivedAt    time.Time
	RIF           int32
	Latency       int64
	RemainingUses int
}

type Algorithm string

const (
	AlgorithmPrequal    Algorithm = "prequal"
	AlgorithmRoundRobin Algorithm = "roundrobin"
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
		ProbeTimeout:    2 * time.Second,
		HealthCheckPath: "/health",
		Algorithm:       AlgorithmPrequal,
		QRIF:            0.84,
		RProbe:          3,
		MinProbeRate:    10,
		PoolCap:         4,
		PoolTTL:         time.Second,
		RRemove:         1,
		Delta:           1,
	}
}
