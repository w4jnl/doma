package metrics

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHandlerToken(t *testing.T) {
	m := New("test")
	m.SyncRequests.WithLabelValues("ok").Inc()
	open := httptest.NewRecorder()
	m.Handler("").ServeHTTP(open, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if open.Code != http.StatusOK || !strings.Contains(open.Body.String(), "doma_sync_requests_total") {
		t.Fatalf("open: %d", open.Code)
	}
	denied := httptest.NewRecorder()
	m.Handler("s3cret").ServeHTTP(denied, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if denied.Code != http.StatusUnauthorized {
		t.Errorf("no bearer: %d", denied.Code)
	}
	r := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	r.Header.Set("Authorization", "Bearer s3cret")
	ok := httptest.NewRecorder()
	m.Handler("s3cret").ServeHTTP(ok, r)
	if ok.Code != http.StatusOK {
		t.Errorf("bearer: %d", ok.Code)
	}
}

// The collectors the spec lists (docs/design.md, "Observability of the server itself"), by
// name and label set; a rename or a lost label fails here before a dashboard goes blank.
func TestCollectorsAsTheSpecNamesThem(t *testing.T) {
	m := New("test")
	m.Households.Set(1)
	m.Members.WithLabelValues("h").Set(2)
	m.Events.WithLabelValues("h", "entry.added").Inc()
	m.SyncRequests.WithLabelValues("ok").Inc()
	m.SyncDuration.Observe(0.01)
	m.Push.WithLabelValues("sent").Inc()
	m.PhotoBytes.WithLabelValues("h").Set(3)
	m.SnapshotAge.WithLabelValues("h").Set(4)
	m.DBWrite.Observe(0.001)
	rec := httptest.NewRecorder()
	m.Handler("").ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := rec.Body.String()
	for _, want := range []string{
		"doma_households 1",
		`doma_members{household="h"} 2`,
		`doma_events_total{household="h",kind="entry.added"} 1`,
		`doma_sync_requests_total{result="ok"} 1`,
		"doma_sync_duration_seconds_bucket{",
		`doma_push_total{result="sent"} 1`,
		`doma_photo_bytes{household="h"} 3`,
		`doma_snapshot_age_seconds{household="h"} 4`,
		"doma_db_write_duration_seconds_bucket{",
		`doma_build_info{version="test"} 1`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q in:\n%s", want, body)
		}
	}
}
