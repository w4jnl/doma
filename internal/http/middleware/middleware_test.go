package middleware

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRequestID(t *testing.T) {
	var seen string
	h := RequestID(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { seen = GetRequestID(r.Context()) }))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if seen == "" || rec.Header().Get("X-Request-Id") != seen {
		t.Errorf("id %q, header %q", seen, rec.Header().Get("X-Request-Id"))
	}
}

func TestRealIP(t *testing.T) {
	cases := []struct {
		name, remote, xff, want string
		trusted                 []string
	}{
		{"no proxy", "203.0.113.5:1234", "198.51.100.1", "203.0.113.5", nil},
		{"trusted proxy", "10.0.0.2:1234", "198.51.100.1", "198.51.100.1", []string{"10.0.0.0/8"}},
		{"two proxies", "10.0.0.2:1234", "198.51.100.1, 10.0.0.3", "198.51.100.1", []string{"10.0.0.0/8"}},
		{"untrusted peer ignores header", "203.0.113.5:1234", "198.51.100.1", "203.0.113.5", []string{"10.0.0.0/8"}},
		{"garbage header", "10.0.0.2:1234", "nope", "10.0.0.2", []string{"10.0.0.0/8"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var got string
			h := RealIP(c.trusted)(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { got = ClientIP(r) }))
			r := httptest.NewRequest(http.MethodGet, "/", nil)
			r.RemoteAddr = c.remote
			if c.xff != "" {
				r.Header.Set("X-Forwarded-For", c.xff)
			}
			h.ServeHTTP(httptest.NewRecorder(), r)
			if got != c.want {
				t.Errorf("ClientIP = %q, want %q", got, c.want)
			}
		})
	}
}

func TestLoggerLine(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	h := Chain(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		AddLogFields(r.Context(), slog.String("household", "h1"))
		w.WriteHeader(http.StatusTeapot)
		_, _ = w.Write([]byte("short and stout"))
	}), RequestID, Logger(log))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/sync/v1", nil))
	var rec map[string]any
	if err := json.Unmarshal(buf.Bytes(), &rec); err != nil {
		t.Fatalf("log line is not JSON: %q", buf.String())
	}
	if rec["method"] != "POST" || rec["path"] != "/sync/v1" || rec["status"] != float64(418) || rec["household"] != "h1" || rec["bytes"] != float64(15) || rec["req_id"] == "" {
		t.Errorf("log line: %v", rec)
	}
}

func TestRecover(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	h := Recover(log)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic("boom") }))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusInternalServerError || !strings.Contains(buf.String(), "boom") {
		t.Errorf("status %d, log %q", rec.Code, buf.String())
	}
}
