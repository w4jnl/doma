package http

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/config"
)

func TestHealthz(t *testing.T) {
	var buf bytes.Buffer
	d := Deps{Cfg: config.Default(), Log: slog.New(slog.NewJSONHandler(&buf, nil))}
	rec := httptest.NewRecorder()
	Handler(d).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK || !strings.HasPrefix(rec.Body.String(), "ok ") {
		t.Fatalf("healthz: %d %q", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("X-Request-Id") == "" {
		t.Error("no request id")
	}
	if !strings.Contains(buf.String(), `"path":"/healthz"`) {
		t.Errorf("request not logged: %s", buf.String())
	}
	rec = httptest.NewRecorder()
	Handler(d).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/healthz", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /healthz = %d, want 405", rec.Code)
	}
}

func TestRunServesAndStops(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	done := make(chan error, 1)
	go func() { done <- Run(ctx, log, addr, Handler(Deps{Cfg: config.Default(), Log: log})) }()
	var resp *http.Response
	for range 50 {
		resp, err = http.Get("http://" + addr + "/healthz")
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status %d", resp.StatusCode)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Run returned %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not stop after cancel")
	}
}
