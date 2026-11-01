package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/push"
)

// TestNoOutboundWhenPushOff runs a whole server with push.enabled = false,
// takes a household from setup to a synced event, and proves that neither
// the push dialer nor the default transport ever opened a connection. The
// egress gate in CI covers the code; this covers the running process.
func TestNoOutboundWhenPushOff(t *testing.T) {
	var dials atomic.Int32
	oldDial := push.DialContext
	push.DialContext = func(_ context.Context, network, addr string) (net.Conn, error) {
		dials.Add(1)
		return nil, errors.New("egress refused in test: " + network + " " + addr)
	}
	t.Cleanup(func() { push.DialContext = oldDial })
	oldTransport := http.DefaultTransport
	http.DefaultTransport = &http.Transport{DialContext: func(_ context.Context, network, addr string) (net.Conn, error) {
		dials.Add(1)
		return nil, errors.New("default transport used: " + network + " " + addr)
	}}
	t.Cleanup(func() { http.DefaultTransport = oldTransport })

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	dir := t.TempDir()
	t.Setenv("DOMA_SERVER_LISTEN", addr)
	t.Setenv("DOMA_SERVER_BASE_URL", "http://"+addr)
	t.Setenv("DOMA_DB_PATH", filepath.Join(dir, "doma.db"))
	t.Setenv("DOMA_PUSH_ENABLED", "false")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan int, 1)
	var outb, errb strings.Builder
	go func() { done <- run(ctx, []string{"serve"}, &outb, &errb) }()

	// our own transport, so the test's requests are not the thing we measure
	own := &http.Client{Transport: &http.Transport{}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	base := "http://" + addr
	var resp *http.Response
	for range 100 {
		resp, err = own.Get(base + "/healthz")
		if err == nil {
			_ = resp.Body.Close()
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("server did not come up: %v\n%s", err, errb.String())
	}
	// form posts and returns the status, the headers and the cookies; the body is closed here
	form := func(path string, v url.Values, cookie *http.Cookie) (int, http.Header, []*http.Cookie) {
		t.Helper()
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, base+path, strings.NewReader(v.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if cookie != nil {
			req.AddCookie(cookie)
		}
		r, err := own.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = r.Body.Close()
		return r.StatusCode, r.Header, r.Cookies()
	}
	status, _, cookies := form("/setup", url.Values{"login": {"j"}, "password": {"long enough password"}, "confirm": {"long enough password"}}, nil)
	if status != http.StatusSeeOther || len(cookies) == 0 {
		t.Fatalf("setup: %d", status)
	}
	session := cookies[0]
	page := func(path string) string {
		t.Helper()
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+path, nil)
		req.AddCookie(session)
		res, err := own.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		var b strings.Builder
		buf := make([]byte, 64<<10)
		for {
			n, err := res.Body.Read(buf)
			b.Write(buf[:n])
			if err != nil {
				break
			}
		}
		_ = res.Body.Close()
		return b.String()
	}
	csrf := regexp.MustCompile(`name="_csrf" value="([^"]+)"`).FindStringSubmatch(page("/admin"))[1]
	_, headers, _ := form("/admin/households", url.Values{"_csrf": {csrf}, "name": {"Family"}, "timezone": {"Europe/Amsterdam"}, "home": {"Gouda"}}, session)
	hhPath := headers.Get("Location")
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, base+hhPath+"/invite", strings.NewReader(url.Values{"_csrf": {csrf}}.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(session)
	res, err := own.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body := make([]byte, 256<<10)
	n, _ := res.Body.Read(body)
	_ = res.Body.Close()
	m := regexp.MustCompile(`/i/([A-Za-z0-9_-]+)`).FindStringSubmatch(string(body[:n]))
	if m == nil {
		t.Fatalf("no invite link on the page")
	}
	// the Go client signs with its own transport, accepts and syncs one event
	c, err := newTestClient(base, own)
	if err != nil {
		t.Fatal(err)
	}
	acc, err := c.Accept(ctx, m[1], "Jaro", "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Do(ctx, http.MethodPost, "/api/v1/devices/"+acc.CredentialID+"/apns", map[string]string{"token": "abc"}, nil); err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := c.Sync(ctx, map[string]any{"households": []map[string]any{{"id": acc.Household.ID, "since": 0, "events": []map[string]any{
		{"id": "e1", "hlc": "1730380000000:0:go", "kind": "home.created", "payload": map[string]any{"home_id": "H2", "name": "Hut"}},
	}}}}, &out); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond) // the pusher sees the change on the bus
	cancel()
	<-done
	if dials.Load() != 0 {
		t.Fatalf("%d outbound dials with push off\n%s", dials.Load(), errb.String())
	}
	if !strings.Contains(errb.String(), "push off") {
		t.Errorf("log does not say push is off: %s", errb.String())
	}
}
