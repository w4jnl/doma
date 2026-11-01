package web_test

import (
	"context"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/http/web"
	"github.com/w4jnl/doma/internal/service"
)

func newWeb(t *testing.T) (*web.Web, *service.Service, *http.ServeMux) {
	t.Helper()
	auth.FastParamsForTests()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := service.New(dbtest.Open(t), service.Config{BaseURL: "https://doma.test"}, log)
	h, err := web.New(svc, log, true)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	h.Mount(mux)
	return h, svc, mux
}

func get(mux http.Handler, path string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodGet, path, nil)
	for _, c := range cookies {
		r.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, r)
	return rec
}

func post(mux http.Handler, path string, form url.Values, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range cookies {
		r.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, r)
	return rec
}

func TestSetupThenLogin(t *testing.T) {
	_, _, mux := newWeb(t)
	if rec := get(mux, "/"); rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/setup" {
		t.Fatalf("root before setup: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	if rec := get(mux, "/setup"); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Set up doma") {
		t.Fatalf("setup page: %d", rec.Code)
	}
	rec := post(mux, "/setup", url.Values{"login": {"j"}, "password": {"long enough password"}, "confirm": {"different password!"}})
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "differ") {
		t.Fatalf("mismatched passwords: %d", rec.Code)
	}
	rec = post(mux, "/setup", url.Values{"login": {"j"}, "password": {"long enough password"}, "confirm": {"long enough password"}})
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/admin" || len(rec.Result().Cookies()) == 0 {
		t.Fatalf("setup: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	session := rec.Result().Cookies()[0]
	if rec := get(mux, "/setup"); rec.Code != http.StatusNotFound {
		t.Errorf("setup page after setup: %d", rec.Code)
	}
	if rec := get(mux, "/"); rec.Header().Get("Location") != "/admin" {
		t.Errorf("root after setup: %s", rec.Header().Get("Location"))
	}
	if rec := get(mux, "/admin"); rec.Code != http.StatusSeeOther || !strings.HasPrefix(rec.Header().Get("Location"), "/admin/login") {
		t.Errorf("admin without session: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	if rec := get(mux, "/admin", session); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "No households yet") {
		t.Errorf("admin with session: %d", rec.Code)
	}
	if rec := post(mux, "/admin/login", url.Values{"login": {"j"}, "password": {"wrong"}}); rec.Code != http.StatusUnauthorized {
		t.Errorf("wrong password: %d", rec.Code)
	}
	rec = post(mux, "/admin/login", url.Values{"login": {"j"}, "password": {"long enough password"}, "next": {"https://evil.example"}})
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/admin" {
		t.Errorf("login: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	for range web.LoginsPerMinute + 1 {
		rec = post(mux, "/admin/login", url.Values{"login": {"j"}, "password": {"wrong"}})
	}
	if rec.Code != http.StatusTooManyRequests {
		t.Errorf("login limit: %d", rec.Code)
	}
}

func TestHouseholdAndInviteFlow(t *testing.T) {
	_, svc, mux := newWeb(t)
	rec := post(mux, "/setup", url.Values{"login": {"j"}, "password": {"long enough password"}, "confirm": {"long enough password"}})
	session := rec.Result().Cookies()[0]
	body := get(mux, "/admin", session).Body.String()
	csrf := regexp.MustCompile(`name="_csrf" value="([^"]+)"`).FindStringSubmatch(body)
	if csrf == nil {
		t.Fatal("no csrf token on the page")
	}
	if rec := post(mux, "/admin/households", url.Values{"name": {"Family"}, "timezone": {"Europe/Amsterdam"}, "home": {"Gouda"}}, session); rec.Code != http.StatusForbidden {
		t.Errorf("post without csrf: %d", rec.Code)
	}
	form := url.Values{"_csrf": {csrf[1]}, "name": {"Family"}, "timezone": {"Nowhere/Land"}, "home": {"Gouda"}}
	if rec := post(mux, "/admin/households", form, session); rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "time zone") {
		t.Errorf("bad timezone: %d", rec.Code)
	}
	form.Set("timezone", "Europe/Amsterdam")
	rec = post(mux, "/admin/households", form, session)
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(rec.Header().Get("Location"), "/admin/h/") {
		t.Fatalf("create: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	hhPath := rec.Header().Get("Location")
	if rec := get(mux, hhPath, session); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Make an owner invite") {
		t.Fatalf("household page: %d", rec.Code)
	}
	rec = post(mux, hhPath+"/invite", url.Values{"_csrf": {csrf[1]}}, session)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "<svg") || !strings.Contains(rec.Body.String(), "https://doma.test/i/") {
		t.Fatalf("owner invite: %d", rec.Code)
	}
	token := regexp.MustCompile(`https://doma.test/i/([A-Za-z0-9_-]+)`).FindStringSubmatch(rec.Body.String())[1]
	rec = get(mux, "/i/"+token)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Join Family") || !strings.Contains(rec.Body.String(), "doma://invite#"+token) {
		t.Fatalf("invite page: %d %s", rec.Code, rec.Body.String())
	}
	signer, _ := auth.NewEd25519Signer()
	if _, err := svc.AcceptInvite(context.Background(), token, service.AcceptInvite{PublicKey: signer.Public(), DisplayName: "Jaro"}); err != nil {
		t.Fatal(err)
	}
	rec = get(mux, "/i/"+token)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "used already") {
		t.Errorf("used invite page: %d", rec.Code)
	}
	if rec := get(mux, "/i/nope"); rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "no longer valid") {
		t.Errorf("unknown invite page: %d", rec.Code)
	}
	if rec := get(mux, "/admin/h/nope", session); rec.Code != http.StatusNotFound {
		t.Errorf("unknown household: %d", rec.Code)
	}
	if rec := post(mux, "/admin/logout", url.Values{"_csrf": {csrf[1]}}, session); rec.Code != http.StatusSeeOther {
		t.Errorf("logout: %d", rec.Code)
	}
	if rec := get(mux, "/admin", session); rec.Code != http.StatusSeeOther {
		t.Errorf("admin after logout: %d", rec.Code)
	}
	_ = domain.RoleOwner
}

func TestStaticAndVendoredCopies(t *testing.T) {
	_, _, mux := newWeb(t)
	for _, p := range []string{"/static/tokens.css", "/static/doma.css", "/static/favicon.svg", "/static/fonts/JetBrainsMono-400.woff2"} {
		if rec := get(mux, p); rec.Code != http.StatusOK || rec.Header().Get("Cache-Control") == "" {
			t.Errorf("%s: %d", p, rec.Code)
		}
	}
	pairs := map[string]string{
		"static/tokens.css":        "../../../docs/design-system/tokens.css",
		"static/favicon.svg":       "../../../assets/brand/favicon.svg",
		"static/favicon-alert.svg": "../../../assets/brand/favicon-alert.svg",
		"static/doma-mark.svg":     "../../../assets/brand/doma-mark.svg",
		"static/fonts/OFL.txt":     "../../../docs/design-system/fonts/OFL.txt",
	}
	for _, f := range []string{"JetBrainsMono-400.woff2", "JetBrainsMono-700.woff2", "JetBrainsMono-800.woff2"} {
		pairs["static/fonts/"+f] = "../../../docs/design-system/fonts/" + f
	}
	for local, source := range pairs {
		a, err := os.ReadFile(local)
		if err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(source)
		if err != nil {
			t.Fatal(err)
		}
		if string(a) != string(b) {
			t.Errorf("%s differs from %s: run make generate", local, source)
		}
	}
}

// TestFamilyFacingVocabulary greps the pages a family member sees for the
// words that never appear there.
func TestFamilyFacingVocabulary(t *testing.T) {
	forbidden := regexp.MustCompile(`(?i)\b(tenant|token|event|sync|server|credential|instance|device key)s?\b`)
	family := map[string]bool{"invite.html": true, "gone.html": true, "guest.html": true, "_guest_list.html": true}
	entries, _ := os.ReadDir("templates")
	for _, e := range entries {
		if !family[e.Name()] {
			continue
		}
		raw, _ := os.ReadFile(filepath.Join("templates", e.Name()))
		if m := forbidden.FindString(string(raw)); m != "" {
			t.Errorf("%s says %q", e.Name(), m)
		}
	}
	_ = fs.ErrNotExist
}

func TestNoInlineStyles(t *testing.T) {
	entries, _ := os.ReadDir("templates")
	for _, e := range entries {
		raw, _ := os.ReadFile(filepath.Join("templates", e.Name()))
		if strings.Contains(string(raw), "style=") || strings.Contains(string(raw), "<style") || strings.Contains(string(raw), "http://") || strings.Contains(string(raw), "https://") {
			t.Errorf("%s has an inline style or an external URL", e.Name())
		}
	}
}
