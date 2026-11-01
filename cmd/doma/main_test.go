package main

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRunUsageAndVersion(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run(context.Background(), nil, &out, &errb); code != 2 || !strings.Contains(errb.String(), "doma serve") {
		t.Errorf("no args: code %d, stderr %q", code, errb.String())
	}
	out.Reset()
	errb.Reset()
	if code := run(context.Background(), []string{"--version"}, &out, &errb); code != 0 || !strings.HasPrefix(out.String(), "doma ") {
		t.Errorf("--version: code %d, stdout %q", code, out.String())
	}
	errb.Reset()
	if code := run(context.Background(), []string{"migrate"}, &out, &errb); code != 2 || !strings.Contains(errb.String(), `unknown command "migrate"`) {
		t.Errorf("unknown: code %d, stderr %q", code, errb.String())
	}
	errb.Reset()
	if code := run(context.Background(), []string{"serve", "extra"}, &out, &errb); code != 1 || !strings.Contains(errb.String(), "no arguments") {
		t.Errorf("serve extra: code %d, stderr %q", code, errb.String())
	}
}

func TestServePrintConfig(t *testing.T) {
	t.Setenv("DOMA_SERVER_LISTEN", ":1234")
	t.Setenv("DOMA_METRICS_TOKEN", "hidden")
	var out, errb bytes.Buffer
	if code := run(context.Background(), []string{"serve", "--print-config"}, &out, &errb); code != 0 {
		t.Fatalf("code %d: %s", code, errb.String())
	}
	s := out.String()
	if !strings.Contains(s, "listen = ':1234'") || strings.Contains(s, "hidden") || !strings.Contains(s, "token = '***'") {
		t.Errorf("print-config: %s", s)
	}
}

func TestServeBadConfig(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run(context.Background(), []string{"serve", "--config", filepath.Join(t.TempDir(), "missing.toml")}, &out, &errb); code != 1 || !strings.Contains(errb.String(), "read config") {
		t.Errorf("code %d, stderr %q", code, errb.String())
	}
}

func TestServeRunsUntilCancelled(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	t.Setenv("DOMA_SERVER_LISTEN", addr)
	t.Setenv("DOMA_DB_PATH", filepath.Join(t.TempDir(), "doma.db"))
	ctx, cancel := context.WithCancel(context.Background())
	var out, errb bytes.Buffer
	done := make(chan int, 1)
	go func() { done <- run(ctx, []string{"serve"}, &out, &errb) }()
	var resp *http.Response
	for range 100 {
		resp, err = http.Get("http://" + addr + "/healthz")
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("server did not come up: %v\n%s", err, errb.String())
	}
	_ = resp.Body.Close()
	cancel()
	select {
	case code := <-done:
		if code != 0 {
			t.Errorf("exit %d: %s", code, errb.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("serve did not stop")
	}
	if !strings.Contains(errb.String(), `"msg":"starting"`) || !strings.Contains(errb.String(), `"msg":"stopped"`) {
		t.Errorf("log: %s", errb.String())
	}
}
