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
	// RemainingUses is the reuse budget b_reuse from paper §4 eq. (1),
	// stochastically rounded to integer at insert. Decremented each
	// time the entry is chosen as the selection winner; the entry is
	// removed from the pool when it reaches zero.
	RemainingUses int
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
	Algorithm        Algorithm
	QRIF             float64
	// RProbe is the average number of probes issued per query
	// (paper §4). May be fractional and may be < 1.
	RProbe float64
	// MinProbeRate is the floor on the probing rate in probes/sec.
	// Effective rate = max(QPS * RProbe, MinProbeRate).
	MinProbeRate float64
	// PoolCap is the maximum number of probe pool entries (m in paper
	// §4 eq. (1)). Oldest is evicted on overflow.
	PoolCap int
	// PoolTTL is the age limit on probe pool entries. Entries older
	// than PoolTTL are dropped before selection.
	PoolTTL time.Duration
	// RRemove is the average number of probes removed from the pool
	// per query (r_remove in paper §4). May be fractional.
	RRemove float64
	// Delta is the drift parameter δ governing the net rate at which
	// probes accumulate in the pool (paper §4 eq. (1)).
	Delta float64
}

type Stats struct {
	TotalRequests      uint64
	SuccessfulRequests uint64
	FailedRequests     uint64
	AverageLatency     float64
	mutex              sync.RWMutex
}
