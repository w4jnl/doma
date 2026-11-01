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
