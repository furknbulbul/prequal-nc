package loadbalancer

import (
	"math"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const (
	minRIFSamples    = 16
	quantileCacheTTL = 100 * time.Millisecond
)

type rifSample struct {
	rif int32
	t   time.Time
}

type quantileCache struct {
	q          float64
	theta      int32
	valid      bool
	computedAt time.Time
}

type RIFDistribution struct {
	mu      sync.Mutex
	samples []rifSample
	counts  map[int32]int
	maxAge  time.Duration
	cache   atomic.Pointer[quantileCache]
}

func NewRIFDistribution(window time.Duration) *RIFDistribution {
	return &RIFDistribution{
		samples: make([]rifSample, 0, 256),
		counts:  make(map[int32]int),
		maxAge:  window,
	}
}

func (d *RIFDistribution) Observe(rif int32, now time.Time) {
	d.mu.Lock()
	d.samples = append(d.samples, rifSample{rif, now})
	d.counts[rif]++
	d.mu.Unlock()
}

func (d *RIFDistribution) Quantile(q float64, now time.Time) (int32, bool) {
	if c := d.cache.Load(); c != nil && c.q == q && now.Sub(c.computedAt) < quantileCacheTTL {
		return c.theta, c.valid
	}
	theta, valid := d.computeQuantile(q, now)
	d.cache.Store(&quantileCache{q: q, theta: theta, valid: valid, computedAt: now})
	return theta, valid
}

func (d *RIFDistribution) computeQuantile(q float64, now time.Time) (int32, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.evictLocked(now.Add(-d.maxAge))

	if len(d.samples) < minRIFSamples {
		return 0, false
	}
	if q >= 1.0 {
		return math.MaxInt32, true
	}
	if q < 0 {
		q = 0
	}

	keys := make([]int32, 0, len(d.counts))
	for r := range d.counts {
		keys = append(keys, r)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })

	target := q * float64(len(d.samples))
	acc := 0
	for _, r := range keys {
		acc += d.counts[r]
		if float64(acc) >= target {
			return r, true
		}
	}
	return keys[len(keys)-1], true
}

func (d *RIFDistribution) evictLocked(cutoff time.Time) {
	cut := 0
	for cut < len(d.samples) && !d.samples[cut].t.After(cutoff) {
		r := d.samples[cut].rif
		d.counts[r]--
		if d.counts[r] == 0 {
			delete(d.counts, r)
		}
		cut++
	}
	if cut == 0 {
		return
	}
	if cut >= len(d.samples) {
		d.samples = d.samples[:0]
		return
	}
	if cut > len(d.samples)/2 {
		remaining := len(d.samples) - cut
		copy(d.samples, d.samples[cut:])
		d.samples = d.samples[:remaining]
	} else {
		d.samples = d.samples[cut:]
	}
}
