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
	Server     *Server
	ReceivedAt time.Time
	RIF        int32
	Latency    int64
}

type Algorithm string

const (
	AlgorithmPrequal     Algorithm = "prequal"
	AlgorithmRoundRobin  Algorithm = "roundrobin"
)

type Config struct {
	ProbeInterval    time.Duration
	ProbeTimeout     time.Duration
	HealthCheckPath  string
	SelectionChoices int
	Algorithm        Algorithm
	QRIF             float64
	// RProbe is the average number of probes issued per query
	// (paper §4). May be fractional and may be < 1.
	RProbe float64
	// MinProbeRate is the floor on the probing rate in probes/sec.
	// Effective rate = max(QPS * RProbe, MinProbeRate).
	MinProbeRate float64
}

type Stats struct {
	TotalRequests      uint64
	SuccessfulRequests uint64
	FailedRequests     uint64
	AverageLatency     float64
	mutex              sync.RWMutex
}
