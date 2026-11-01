// Package metrics holds the Prometheus collectors of the design document
// and serves /metrics, behind a bearer when metrics.token is set.
package metrics

import (
	"crypto/subtle"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics is every collector.
type Metrics struct {
	reg          *prometheus.Registry
	Households   prometheus.Gauge
	Members      *prometheus.GaugeVec
	Events       *prometheus.CounterVec
	SyncRequests *prometheus.CounterVec
	SyncDuration prometheus.Histogram
	Push         *prometheus.CounterVec
	PhotoBytes   *prometheus.GaugeVec
	SnapshotAge  *prometheus.GaugeVec
	DBWrite      prometheus.Histogram
}

// New registers the collectors on a fresh registry.
func New(version string) *Metrics {
	m := &Metrics{reg: prometheus.NewRegistry()}
	m.Households = prometheus.NewGauge(prometheus.GaugeOpts{Name: "doma_households", Help: "Households on this server."})
	m.Members = prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "doma_members", Help: "Members and owners per household."}, []string{"household"})
	m.Events = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "doma_events_total", Help: "Events appended, per household and kind."}, []string{"household", "kind"})
	m.SyncRequests = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "doma_sync_requests_total", Help: "Sync requests by result."}, []string{"result"})
	m.SyncDuration = prometheus.NewHistogram(prometheus.HistogramOpts{Name: "doma_sync_duration_seconds", Help: "Sync request duration.", Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5}})
	m.Push = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "doma_push_total", Help: "Push attempts by result."}, []string{"result"})
	m.PhotoBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "doma_photo_bytes", Help: "Photo bytes stored per household."}, []string{"household"})
	m.SnapshotAge = prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "doma_snapshot_age_seconds", Help: "Age of the newest snapshot per household."}, []string{"household"})
	m.DBWrite = prometheus.NewHistogram(prometheus.HistogramOpts{Name: "doma_db_write_duration_seconds", Help: "Write transaction duration.", Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1}})
	info := prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "doma_build_info", Help: "Build information."}, []string{"version"})
	info.WithLabelValues(version).Set(1)
	m.reg.MustRegister(m.Households, m.Members, m.Events, m.SyncRequests, m.SyncDuration, m.Push, m.PhotoBytes, m.SnapshotAge, m.DBWrite, info)
	return m
}

// Handler serves the registry; with a token, only to a matching bearer.
func (m *Metrics) Handler(token string) http.Handler {
	h := promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{})
	if token == "" {
		return h
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("Authorization")
		if subtle.ConstantTimeCompare([]byte(got), []byte("Bearer "+token)) != 1 {
			w.Header().Set("WWW-Authenticate", `Bearer realm="doma metrics"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		h.ServeHTTP(w, r)
	})
}

// ObserveWrite records one write transaction.
func (m *Metrics) ObserveWrite(d time.Duration) { m.DBWrite.Observe(d.Seconds()) }
