package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/omarshaarawi/loadbalancer/pkg/loadbalancer"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	LevelTrace = slog.Level(-8)
	LevelFatal = slog.Level(12)
)

func main() {
	runtime.SetMutexProfileFraction(5)
	runtime.SetBlockProfileRate(1_000_000)

	ctx := context.Background()
	port := flag.String("port", "8080", "Port to listen on")
	algorithm := flag.String("algorithm", "prequal", "Load balancing algorithm (prequal or roundrobin)")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	algo := *algorithm
	if envAlgo := os.Getenv("LB_ALGORITHM"); envAlgo != "" {
		algo = envAlgo
	}

	config := loadbalancer.DefaultConfig()
	switch loadbalancer.Algorithm(algo) {
	case loadbalancer.AlgorithmPrequal, loadbalancer.AlgorithmRoundRobin:
		config.Algorithm = loadbalancer.Algorithm(algo)
	default:
		logger.Log(ctx, LevelFatal, "invalid algorithm '"+algo+"'; use 'prequal' or 'roundrobin'")
		os.Exit(1)
	}
	if v, ok := os.LookupEnv("LB_METRICS"); ok {
		config.EnableMetrics = parseBool(v)
	}
	if v, ok := os.LookupEnv("LB_PICK_LOG"); ok {
		config.EnablePickLog = parseBool(v)
	}
	if v, ok := os.LookupEnv("LB_RPROBE"); ok {
		if f, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil && f > 0 {
			config.RProbe = f
		}
	}
	if v, ok := os.LookupEnv("LB_RPROBE_ADAPTIVE"); ok {
		config.AdaptiveProbe = parseBool(v)
	}
	if v, ok := os.LookupEnv("LB_RPROBE_MIN"); ok {
		if f, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil && f > 0 {
			config.RProbeMin = f
		}
	}
	if v, ok := os.LookupEnv("LB_PROBE_LOAD_LOW"); ok {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n >= 0 {
			config.ProbeLoadLow = int32(n)
		}
	}
	if v, ok := os.LookupEnv("LB_PROBE_LOAD_HIGH"); ok {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n >= 0 {
			config.ProbeLoadHigh = int32(n)
		}
	}
	if v, ok := os.LookupEnv("LB_FORWARD_TIMEOUT_MS"); ok {
		if ms, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && ms >= 0 {
			config.ForwardTimeout = time.Duration(ms) * time.Millisecond
		}
	}
	if v, ok := os.LookupEnv("LB_PROBE_MODE"); ok {
		switch strings.ToLower(strings.TrimSpace(v)) {
		case "ticker":
			config.ProbeMode = loadbalancer.ProbeModeTicker
		case "per_query", "perquery", "":
			config.ProbeMode = loadbalancer.ProbeModePerQuery
		default:
			logger.Log(ctx, LevelFatal, "invalid LB_PROBE_MODE; use 'per_query' or 'ticker'")
			os.Exit(1)
		}
	}
	if v, ok := os.LookupEnv("LB_PROBE_INTERVAL_MS"); ok {
		if ms, err := time.ParseDuration(v + "ms"); err == nil && ms > 0 {
			config.ProbeInterval = ms
		}
	}

	lb := loadbalancer.NewLoadBalancer(config, logger)

	logger.Info("Load balancer configured",
		slog.String("algorithm", string(config.Algorithm)),
		slog.String("probe_mode", string(config.ProbeMode)),
		slog.Duration("probe_interval", config.ProbeInterval),
		slog.Float64("r_probe", config.RProbe),
		slog.Bool("adaptive_probe", config.AdaptiveProbe),
		slog.Float64("r_probe_min", config.RProbeMin),
		slog.Int("probe_load_low", int(config.ProbeLoadLow)),
		slog.Int("probe_load_high", int(config.ProbeLoadHigh)),
		slog.Duration("forward_timeout", config.ForwardTimeout),
		slog.Bool("enable_metrics", config.EnableMetrics),
		slog.Bool("enable_pick_log", config.EnablePickLog))

	backends := parseBackends(os.Getenv("BACKEND_SERVERS"))
	if len(backends) == 0 {
		logger.Log(ctx, LevelFatal, "BACKEND_SERVERS env var is empty; set a comma-separated list like 'server1:80,server2:80'")
		os.Exit(1)
	}

	for i, addr := range backends {
		lb.AddServer(&loadbalancer.Server{
			ID:      fmt.Sprintf("server-%d", i),
			Address: addr,
		})
	}
	logger.Info("Registered backend servers", slog.Int("count", len(backends)))

	mux := http.NewServeMux()
	mux.Handle("/", lb)
	mux.Handle("/metrics", promhttp.Handler())
	mux.Handle("/debug/pprof/", http.DefaultServeMux)
	mux.HandleFunc("/debug/pool", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		_ = enc.Encode(lb.DebugSnapshot())
	})
	server := &http.Server{
		Addr:    ":" + *port,
		Handler: mux,
	}

	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan

		logger.Info("Shutting down server...")
		ctx, cancel := context.WithTimeout(context.Background(), time.Second*10)
		defer cancel()

		if err := server.Shutdown(ctx); err != nil {
			logger.Error("Server shutdown error", slog.String("error", err.Error()))
		}
		lb.Stop()
	}()

	logger.Info("Starting server on port " + *port)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		logger.Log(ctx, LevelFatal, "Server error")
	}
}

func parseBool(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func parseBackends(raw string) []string {
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
