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
	"time"
)

var inflight int32

const (
	latencyRingSize = 256
	rifWindowDelta  = 10
	workMean        = 4000.0
)

type latencySample struct {
	latencyMs    int64
	rifAtArrival int32
}

var (
	latencyRing      [latencyRingSize]latencySample
	latencyRingIdx   int
	latencyRingFill  int
	latencyRingMutex sync.Mutex
)

func recordLatency(latencyMs int64, rifAtArrival int32) {
	latencyRingMutex.Lock()
	defer latencyRingMutex.Unlock()
	latencyRing[latencyRingIdx] = latencySample{latencyMs, rifAtArrival}
	latencyRingIdx = (latencyRingIdx + 1) % latencyRingSize
	if latencyRingFill < latencyRingSize {
		latencyRingFill++
	}
}

func medianLatencyMs(currentRif int32) int64 {
	latencyRingMutex.Lock()
	n := latencyRingFill
	all := make([]int64, 0, n)
	near := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		s := latencyRing[i]
		all = append(all, s.latencyMs)
		d := s.rifAtArrival - currentRif
		if d < 0 {
			d = -d
		}
		if d <= rifWindowDelta {
			near = append(near, s.latencyMs)
		}
	}
	latencyRingMutex.Unlock()

	// if there is no sample near RIF value, just return the average latency
	if len(near) == 0 {
		if len(all) == 0 {
			return 0
		}
		var sum int64
		for _, v := range all {
			sum += v
		}
		return sum / int64(len(all))
	}
	sort.Slice(near, func(i, j int) bool { return near[i] < near[j] })
	return near[len(near)/2]
}

func runAntagonist(cpuLoad int, serverID string) {
	if cpuLoad <= 0 {
		return
	}
	if cpuLoad > 100 {
		cpuLoad = 100
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
				"--cpu", "1",
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

func main() {
	port := os.Getenv("PORT")
	serverID := os.Getenv("SERVER_ID")

	cpuLoad := 0
	if loadStr := os.Getenv("CPU_LOAD"); loadStr != "" {
		if val, err := strconv.Atoi(loadStr); err == nil {
			cpuLoad = val
		}
	}

	if cpuLoad > 0 {
		go runAntagonist(cpuLoad, serverID)
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		rifAtArrival := atomic.AddInt32(&inflight, 1)
		defer atomic.AddInt32(&inflight, -1)

		start := time.Now()

		work := int(rand.NormFloat64()*workMean + workMean)
		if work < 0 {
			work = 0
		}
		for i := 0; i < work; i++ {
			hash := sha256.Sum256([]byte(fmt.Sprintf("%d-%d", time.Now().UnixNano(), i)))
			_ = hex.EncodeToString(hash[:])
		}

		duration := time.Since(start)
		recordLatency(duration.Milliseconds(), rifAtArrival)

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
		w.Header().Set("X-Latency-Estimate-Ms", strconv.FormatInt(medianLatencyMs(currentRif), 10))
		w.Header().Set("X-Probe-Response-Time", strconv.FormatInt(time.Now().UnixNano(), 10))
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"status":"healthy","server_id":"%s"}`, serverID)
	})

	log.Printf("Server %s starting on port %s (CPU load: %d%%)", serverID, port, cpuLoad)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
