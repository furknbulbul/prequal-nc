package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
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
	ctx := context.Background()
	port := flag.String("port", "8080", "Port to listen on")
	algorithm := flag.String("algorithm", "prequal", "Load balancing algorithm (prequal or roundrobin)")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	algo := *algorithm
	envAlgo := os.Getenv("LB_ALGORITHM")
	algo = envAlgo

	config := loadbalancer.DefaultConfig()
	config.Algorithm = loadbalancer.Algorithm(algo)

	lb := loadbalancer.NewLoadBalancer(config, logger)

	logger.Info("Load balancer configured", slog.String("algorithm", string(config.Algorithm)))

	backends := parseBackends(os.Getenv("BACKEND_SERVERS"))
	if len(backends) == 0 {
		logger.Log(ctx, LevelFatal, "BACKEND_SERVERS env var is empty; set a comma-separated list like 'server1:80,server2:80'")
		os.Exit(1)
	}

	for i, addr := range backends {
		lb.AddServer(&loadbalancer.Server{
			ID:        fmt.Sprintf("server-%d", i),
			Address:   addr,
			IsHealthy: true,
		})
	}
	logger.Info("Registered backend servers", slog.Int("count", len(backends)))

	mux := http.NewServeMux()
	mux.Handle("/", lb)
	mux.Handle("/metrics", promhttp.Handler())
	server := &http.Server{
		Addr:    ":" + *port,
		Handler: mux,
	}

	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan // blocks until SIGINT/SIGTERM

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
