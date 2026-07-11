package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var (
	inflight       int32
	requestsTotal  uint64
	cancelledTotal uint64
)

const (
	latencyRingSize = 256
	rifWindowDelta  = 2 // "latency at (or near) the current RIF"
	workMean        = 4000.0
	// How often the work loop polls for cancellation. Coarse enough to be
	// free, fine enough that abandoned queries stop burning CPU quickly.
	cancelCheckEvery = 256
)

type latencySample struct {
	latencyUs    int64
	rifAtArrival int32
}

var (
	latencyRing      [latencyRingSize]latencySample
	latencyRingIdx   int
	latencyRingFill  int
	latencyRingMutex sync.Mutex
)

func recordLatency(latencyUs int64, rifAtArrival int32) {
	latencyRingMutex.Lock()
	defer latencyRingMutex.Unlock()
	latencyRing[latencyRingIdx] = latencySample{latencyUs, rifAtArrival}
	latencyRingIdx = (latencyRingIdx + 1) % latencyRingSize
	if latencyRingFill < latencyRingSize {
		latencyRingFill++
	}
}

func medianLatencyUs(currentRif int32) int64 {
	latencyRingMutex.Lock()
	n := latencyRingFill
	all := make([]int64, 0, n)
	near := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		s := latencyRing[i]
		all = append(all, s.latencyUs)
		d := s.rifAtArrival - currentRif
		if d < 0 {
			d = -d
		}
		if d <= rifWindowDelta {
			near = append(near, s.latencyUs)
		}
	}
	latencyRingMutex.Unlock()

	// If there is no sample near the current RIF, fall back to the median
	// over all recent samples (median for outlier robustness, per paper).
	if len(near) == 0 {
		if len(all) == 0 {
			return 0
		}
		sort.Slice(all, func(i, j int) bool { return all[i] < all[j] })
		return all[len(all)/2]
	}
	sort.Slice(near, func(i, j int) bool { return near[i] < near[j] })
	return near[len(near)/2]
}

// runAntagonist emulates a co-tenant competing for the machine's CPU.
// cpuLoad is the duty cycle (0-100) of a 10s period; cores is how many CPUs
// stress-ng pins while "on". cpuLoad=100 runs a constant antagonist, so the
// replica's effective capacity is permanently machine_cores - cores.
func runAntagonist(cpuLoad, cores int, serverID string) {
	if cpuLoad <= 0 || cores <= 0 {
		return
	}
	if cpuLoad > 100 {
		cpuLoad = 100
	}

	if cpuLoad == 100 {
		for {
			cmd := exec.Command("stress-ng",
				"--cpu", strconv.Itoa(cores),
				"--cpu-method", "matrixprod",
				"--timeout", "0", // run forever
			)
			cmd.Stdout = os.Stderr
			cmd.Stderr = os.Stderr
			if err := cmd.Run(); err != nil {
				log.Printf("antagonist stress-ng exited: %v", err)
			}
			time.Sleep(time.Second) // relaunch guard
		}
	}

	const cyclePeriodSeconds = 10
	onSec := cyclePeriodSeconds * cpuLoad / 100
	offSec := cyclePeriodSeconds - onSec

	// Phase offset: explicit ANTAGONIST_PHASE env var wins; fall back to
	// SERVER_ID-based stagger so unstaggered setups still work.
	phaseOffsetSec := extractServerNum(serverID) % cyclePeriodSeconds
	if v := os.Getenv("ANTAGONIST_PHASE"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			phaseOffsetSec = ((n % cyclePeriodSeconds) + cyclePeriodSeconds) % cyclePeriodSeconds
		}
	}

	now := time.Now()
	secOfCycle := int(now.Unix()) % cyclePeriodSeconds
	delayToNextStart := (phaseOffsetSec - secOfCycle + cyclePeriodSeconds) % cyclePeriodSeconds
	time.Sleep(time.Duration(delayToNextStart) * time.Second)

	for {
		if onSec > 0 {
			cmd := exec.Command("stress-ng",
				"--cpu", strconv.Itoa(cores),
				"--cpu-method", "matrixprod",
				"--timeout", fmt.Sprintf("%ds", onSec),
			)
			cmd.Stdout = os.Stderr
			cmd.Stderr = os.Stderr
			if err := cmd.Run(); err != nil {
				log.Printf("antagonist stress-ng exited: %v", err)
			}
		}
		if offSec > 0 {
			time.Sleep(time.Duration(offSec) * time.Second)
		}
	}
}

// extractServerNum pulls the trailing integer from an ID like "server3"
// so we can use it as a stagger offset. Returns 0 if no integer suffix.
func extractServerNum(id string) int {
	i := len(id)
	for i > 0 && id[i-1] >= '0' && id[i-1] <= '9' {
		i--
	}
	if i == len(id) {
		return 0
	}
	n, err := strconv.Atoi(id[i:])
	if err != nil {
		return 0
	}
	return n
}

func tvSeconds(tv syscall.Timeval) float64 {
	return float64(tv.Sec) + float64(tv.Usec)/1e6
}

func main() {
	port := os.Getenv("PORT")
	serverID := os.Getenv("SERVER_ID")

	cpuLoad := 0
	if loadStr := os.Getenv("CPU_LOAD"); loadStr != "" {
		if val, err := strconv.Atoi(loadStr); err == nil {
			cpuLoad = val
		}
	}
	antagonistCores := 6
	if s := os.Getenv("ANTAGONIST_CORES"); s != "" {
		if v, err := strconv.Atoi(s); err == nil && v >= 0 {
			antagonistCores = v
		}
	}

	if cpuLoad > 0 {
		go runAntagonist(cpuLoad, antagonistCores, serverID)
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		rifAtArrival := atomic.AddInt32(&inflight, 1)
		defer atomic.AddInt32(&inflight, -1)
		atomic.AddUint64(&requestsTotal, 1)

		start := time.Now()
		ctx := r.Context()

		work := int(rand.NormFloat64()*workMean + workMean)
		if work < 0 {
			work = 0
		}
		for i := 0; i < work; i++ {
			if i%cancelCheckEvery == 0 && ctx.Err() != nil {
				// The client/LB gave up on this query (deadline exceeded);
				// stop burning CPU on it, and don't pollute the latency ring.
				atomic.AddUint64(&cancelledTotal, 1)
				return
			}
			hash := sha256.Sum256([]byte(fmt.Sprintf("%d-%d", time.Now().UnixNano(), i)))
			_ = hex.EncodeToString(hash[:])
		}

		duration := time.Since(start)
		recordLatency(duration.Microseconds(), rifAtArrival)

		w.Header().Set("Content-Type", "text/html")
		w.Header().Set("X-Served-By", serverID)
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `<!DOCTYPE html>
<html>
<head><title>Backend Server</title></head>
<body>
<h1>Backend Server: %s</h1>
<p>Request processed in %v</p>
<p>CPU Load: %d%% (simulated antagonist contention)</p>
</body>
</html>`, serverID, duration, cpuLoad)
	})

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		currentRif := atomic.LoadInt32(&inflight)
		w.Header().Set("X-Requests-In-Flight", strconv.FormatInt(int64(currentRif), 10))
		w.Header().Set("X-Latency-Estimate-Us", strconv.FormatInt(medianLatencyUs(currentRif), 10))
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"status":"healthy","server_id":"%s"}`, serverID)
	})

	// Prometheus scrape target. backend_cpu_seconds_total is the serving
	// process only: the antagonist runs as a child process and is excluded
	// by RUSAGE_SELF, so this is the paper's "job CPU" that Figure 6(c)
	// plots as a percentage of the allocation.
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		var ru syscall.Rusage
		_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
		cpu := tvSeconds(ru.Utime) + tvSeconds(ru.Stime)
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		fmt.Fprintf(w, "# TYPE backend_cpu_seconds_total counter\n")
		fmt.Fprintf(w, "backend_cpu_seconds_total %.6f\n", cpu)
		fmt.Fprintf(w, "# TYPE backend_inflight gauge\n")
		fmt.Fprintf(w, "backend_inflight %d\n", atomic.LoadInt32(&inflight))
		fmt.Fprintf(w, "# TYPE backend_requests_total counter\n")
		fmt.Fprintf(w, "backend_requests_total %d\n", atomic.LoadUint64(&requestsTotal))
		fmt.Fprintf(w, "# TYPE backend_cancelled_total counter\n")
		fmt.Fprintf(w, "backend_cancelled_total %d\n", atomic.LoadUint64(&cancelledTotal))
	})

	log.Printf("Server %s starting on port %s (CPU load: %d%%, antagonist cores: %d)",
		serverID, port, cpuLoad, antagonistCores)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
