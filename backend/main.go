package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

var inflight int32

const latencyRingSize = 128

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

func medianLatencyMs() int64 {
	latencyRingMutex.Lock()
	n := latencyRingFill
	samples := make([]int64, n)
	for i := 0; i < n; i++ {
		samples[i] = latencyRing[i].latencyMs
	}
	latencyRingMutex.Unlock()

	if n == 0 {
		return 0
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	return samples[n/2]
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	serverID := os.Getenv("SERVER_ID")
	if serverID == "" {
		serverID = "unknown"
	}

	cpuLoad := 0
	if loadStr := os.Getenv("CPU_LOAD"); loadStr != "" {
		if val, err := strconv.Atoi(loadStr); err == nil {
			cpuLoad = val
		}
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		rifAtArrival := atomic.AddInt32(&inflight, 1)
		defer atomic.AddInt32(&inflight, -1)

		start := time.Now()

		work := 1000 + rand.Intn(500)
		for i := range work {
			hash := sha256.Sum256([]byte(fmt.Sprintf("%d-%d", time.Now().UnixNano(), i)))
			_ = hex.EncodeToString(hash[:])
		}

		if cpuLoad > 0 {
			baseDelay := 10 * time.Millisecond
			additionalDelay := time.Duration(float64(cpuLoad)/100.0*30) * time.Millisecond
			variance := time.Duration(rand.Intn(5)) * time.Millisecond
			time.Sleep(baseDelay + additionalDelay + variance)
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
		if cpuLoad > 0 {
			baseDelay := 10 * time.Millisecond
			additionalDelay := time.Duration(float64(cpuLoad)/100.0*30) * time.Millisecond
			variance := time.Duration(rand.Intn(5)) * time.Millisecond
			time.Sleep(baseDelay + additionalDelay + variance)
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Requests-In-Flight", strconv.FormatInt(int64(atomic.LoadInt32(&inflight)), 10))
		w.Header().Set("X-Latency-Estimate-Ms", strconv.FormatInt(medianLatencyMs(), 10))
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"status":"healthy","server_id":"%s"}`, serverID)
	})

	log.Printf("Server %s starting on port %s (CPU load: %d%%)", serverID, port, cpuLoad)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
