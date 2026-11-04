package http_test

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/w4jnl/doma/internal/config"
	"github.com/w4jnl/doma/internal/db/dbtest"
	dhttp "github.com/w4jnl/doma/internal/http"
	"github.com/w4jnl/doma/internal/service"
)

// docs/deploy/authelia puts a browser sign-in in front of the admin pages
// only. The router it leaves open must cover every path a phone, a guest,
// the apps or a probe reach, nothing on it may ask for doma's own session,
// and the admin pages must. This test reads that router's rule and holds
// both ends to it, so a new route and the example cannot drift apart.
func TestOpenPathsNeedNoBrowserSession(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := service.New(dbtest.Open(t), service.Config{BaseURL: "https://doma.test", SnapshotsDir: t.TempDir()}, log)
	h, err := dhttp.Handler(dhttp.Deps{Cfg: config.Default(), Log: log, Svc: svc})
	if err != nil {
		t.Fatal(err)
	}
	rules := openRouterRules(t)
	covered := make(map[pathRule]bool, len(rules))
	open := []struct{ method, path string }{
		{http.MethodGet, "/i/nope"},
		{http.MethodPost, "/i/nope"},
		{http.MethodGet, "/g/nope"},
		{http.MethodGet, "/g/nope/list"},
		{http.MethodGet, "/static/doma.css"},
		{http.MethodGet, "/api/v1/openapi.yaml"},
		{http.MethodGet, "/api/v1/me"},
		{http.MethodPost, "/sync/v1"},
		{http.MethodGet, "/sync/v1/snapshot/nope/1"},
		{http.MethodGet, "/healthz"},
		{http.MethodGet, "/readyz"},
		{http.MethodGet, "/metrics"},
	}
	for _, c := range open {
		matched := false
		for _, r := range rules {
			if r.matches(c.path) {
				matched, covered[r] = true, true
			}
		}
		if !matched {
			t.Errorf("%s is not on the open router in traefik.yaml", c.path)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(c.method, c.path, strings.NewReader("{}")))
		if loc := rec.Header().Get("Location"); rec.Code/100 == 3 || loc != "" {
			t.Errorf("%s %s: %d to %q; an open path must not send anyone to a sign-in", c.method, c.path, rec.Code, loc)
		}
		if rec.Code == http.StatusMethodNotAllowed {
			t.Errorf("%s %s: 405; the method is wrong, so the row proves nothing", c.method, c.path)
		}
	}
	for _, r := range rules {
		if !covered[r] {
			t.Errorf("traefik.yaml opens %s and no request here covers it", r)
		}
	}
	for _, p := range []string{"/admin", "/admin/server", "/admin/h/nope", "/admin/h/nope/export"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if loc := rec.Header().Get("Location"); rec.Code != http.StatusSeeOther || !strings.HasPrefix(loc, "/admin/login") {
			t.Errorf("GET %s without a session: %d to %q, want a redirect to /admin/login", p, rec.Code, loc)
		}
		for _, r := range rules {
			if r.matches(p) {
				t.Errorf("%s is on the open router but needs the admin's session", p)
			}
		}
	}
}

// pathRule is one PathPrefix or Path matcher of the open router.
type pathRule struct {
	prefix bool
	path   string
}

func (r pathRule) matches(p string) bool {
	if r.prefix {
		return strings.HasPrefix(p, r.path)
	}
	return p == r.path
}

func (r pathRule) String() string {
	if r.prefix {
		return "PathPrefix(" + r.path + ")"
	}
	return "Path(" + r.path + ")"
}

var pathRuleRE = regexp.MustCompile("(PathPrefix|Path)\\(`([^`]+)`\\)")

// openRouterRules reads the first rule with path matchers in the deploy
// example's traefik.yaml, which is the open router's.
func openRouterRules(t *testing.T) []pathRule {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "docs", "deploy", "authelia", "traefik.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.Contains(line, "PathPrefix(") {
			continue
		}
		var rules []pathRule
		for _, m := range pathRuleRE.FindAllStringSubmatch(line, -1) {
			rules = append(rules, pathRule{prefix: m[1] == "PathPrefix", path: m[2]})
		}
		return rules
	}
	t.Fatal("traefik.yaml has no router rule with path matchers")
	return nil
}
