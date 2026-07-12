package loadbalancer

import (
	"github.com/prometheus/client_golang/prometheus"
)

type Metrics struct {
	requestDuration    *prometheus.HistogramVec
	activeRequests     *prometheus.GaugeVec
	serverHealth       *prometheus.GaugeVec
	serverRIF          *prometheus.GaugeVec
	probesTriggered    *prometheus.CounterVec
	probesSucceeded    *prometheus.CounterVec
	probesFailed       *prometheus.CounterVec
	probeDuration      *prometheus.HistogramVec
	probeInflight      *prometheus.GaugeVec
	probeRateEffective *prometheus.GaugeVec
	poolSize           *prometheus.GaugeVec
	pickClass          *prometheus.CounterVec
}

func NewMetrics() *Metrics {
	m := &Metrics{
		requestDuration: prometheus.NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "request_duration_seconds",
				Help:    "Time spent processing request",
				Buckets: prometheus.DefBuckets,
			},
			[]string{"algorithm"},
		),
		activeRequests: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "active_requests",
				Help: "Number of requests currently being processed",
			},
			[]string{"algorithm"},
		),
		serverHealth: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "server_health",
				Help: "Health status of servers",
			},
			[]string{"server_id", "algorithm"},
		),
		serverRIF: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "server_rif",
				Help: "Server-reported requests in flight (from probe response header)",
			},
			[]string{"server_id", "algorithm"},
		),
		probesTriggered: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "prequal_probes_triggered_total",
				Help: "Probes initiated by the LB",
			},
			[]string{"algorithm"},
		),
		probesSucceeded: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "prequal_probes_succeeded_total",
				Help: "Probes that returned a valid result",
			},
			[]string{"algorithm"},
		),
		probesFailed: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "prequal_probes_failed_total",
				Help: "Probes that errored or timed out",
			},
			[]string{"algorithm", "reason"},
		),
		probeDuration: prometheus.NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "prequal_probe_duration_seconds",
				Help:    "End-to-end wall time of a /health probe from the LB",
				Buckets: []float64{.0005, .001, .002, .005, .01, .025, .05, .1, .2, .5, 1, 2},
			},
			[]string{"algorithm"},
		),
		probeInflight: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "prequal_probes_inflight",
				Help: "Currently in-flight probe requests",
			},
			[]string{"algorithm"},
		),
		probeRateEffective: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "prequal_probe_rate_effective",
				Help: "Adaptive probes-per-query currently in effect (de-rated from r_probe under load)",
			},
			[]string{"algorithm"},
		),
		poolSize: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "prequal_pool_size",
				Help: "Current entries in the probe pool",
			},
			[]string{"algorithm"},
		),
		pickClass: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "prequal_pick_class_total",
				Help: "Picks broken down by HCL class (cold, hot, no-pool, no-winner)",
			},
			[]string{"algorithm", "class"},
		),
	}

	prometheus.MustRegister(m.requestDuration)
	prometheus.MustRegister(m.activeRequests)
	prometheus.MustRegister(m.serverHealth)
	prometheus.MustRegister(m.serverRIF)
	prometheus.MustRegister(m.probesTriggered)
	prometheus.MustRegister(m.probesSucceeded)
	prometheus.MustRegister(m.probesFailed)
	prometheus.MustRegister(m.probeDuration)
	prometheus.MustRegister(m.probeInflight)
	prometheus.MustRegister(m.probeRateEffective)
	prometheus.MustRegister(m.poolSize)
	prometheus.MustRegister(m.pickClass)

	return m
}
