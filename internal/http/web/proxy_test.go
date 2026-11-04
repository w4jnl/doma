package web_test

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/http/web"
	"github.com/w4jnl/doma/internal/service"
)

// newProxyWeb is newWeb with admin.auth = proxy: peers in 192.0.2.0/24
// (httptest's default) with the secret "s3" are believed.
func newProxyWeb(t *testing.T, logoutURL string) http.Handler {
	t.Helper()
	auth.FastParamsForTests()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := service.New(dbtest.Open(t), service.Config{BaseURL: "https://doma.test"}, log)
	h, err := web.New(svc, log, true)
	if err != nil {
		t.Fatal(err)
	}
	h.SetProxyAuth(auth.NewProxy([]string{"192.0.2.0/24"}, "s3", logoutURL))
	mux := http.NewServeMux()
	h.Mount(mux)
	if err := svc.Setup(context.Background(), "j", "long enough password"); err != nil {
		t.Fatal(err)
	}
	return mux
}

// vouched is a request as the proxy sends it: from a trusted peer, with the
// secret and the user.
func vouched(method, path, user string, cookies ...*http.Cookie) *http.Request {
	r := httptest.NewRequest(method, path, nil)
	r.Header.Set(auth.ProxySecretHeader, "s3")
	if user != "" {
		r.Header.Set(auth.ProxyUserHeader, user)
	}
	for _, c := range cookies {
		r.AddCookie(c)
	}
	return r
}

func serve(mux http.Handler, r *http.Request) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, r)
	return rec
}

func TestProxySignsTheAdminIn(t *testing.T) {
	mux := newProxyWeb(t, "")
	rec := serve(mux, vouched(http.MethodGet, "/admin", "jaro"))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Households") {
		t.Fatalf("vouched GET /admin: %d", rec.Code)
	}
	if len(rec.Result().Cookies()) == 0 || rec.Result().Cookies()[0].Name != auth.AdminCookie {
		t.Fatal("a vouched request starts no session")
	}
	if strings.Contains(rec.Body.String(), "Sign out") {
		t.Error("Sign out shown without a logout URL")
	}
	session := rec.Result().Cookies()[0]

	// the same user with the session: no new cookie
	rec = serve(mux, vouched(http.MethodGet, "/admin/server", "jaro", session))
	if rec.Code != http.StatusOK || len(rec.Result().Cookies()) != 0 {
		t.Errorf("second vouched request: %d, %d cookies", rec.Code, len(rec.Result().Cookies()))
	}
	if !strings.Contains(rec.Body.String(), "The proxy in front signs the admin in") || strings.Contains(rec.Body.String(), "Second step on sign-in") {
		t.Error("the Server page still offers the second step under proxy sign-in")
	}
	// another user behind the same browser: a session of their own
	rec = serve(mux, vouched(http.MethodGet, "/admin", "ana", session))
	if rec.Code != http.StatusOK || len(rec.Result().Cookies()) == 0 || rec.Result().Cookies()[0].Value == session.Value {
		t.Errorf("a new user on an old session: %d, cookies %v", rec.Code, rec.Result().Cookies())
	}
	// the login page sends a vouched browser on; the password form is gone
	rec = serve(mux, vouched(http.MethodGet, "/admin/login?next=/admin/server", "jaro"))
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/admin/server" {
		t.Errorf("vouched GET /admin/login: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	if rec := post(mux, "/admin/login", url.Values{"login": {"j"}, "password": {"long enough password"}}); rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /admin/login under proxy sign-in: %d, want 405", rec.Code)
	}
}

func TestProxyRefusesWhatItDoesNotVouchFor(t *testing.T) {
	mux := newProxyWeb(t, "")
	cases := []struct {
		name string
		req  *http.Request
	}{
		{"no secret", func() *http.Request {
			r := vouched(http.MethodGet, "/admin", "jaro")
			r.Header.Del(auth.ProxySecretHeader)
			return r
		}()},
		{"wrong secret", func() *http.Request {
			r := vouched(http.MethodGet, "/admin", "jaro")
			r.Header.Set(auth.ProxySecretHeader, "nope")
			return r
		}()},
		{"no user", vouched(http.MethodGet, "/admin", "")},
		{"untrusted peer", func() *http.Request {
			r := vouched(http.MethodGet, "/admin", "jaro")
			r.RemoteAddr = "198.51.100.9:4"
			return r
		}()},
		{"login page without identity", func() *http.Request { r := vouched(http.MethodGet, "/admin/login", ""); return r }()},
	}
	for _, c := range cases {
		rec := serve(mux, c.req)
		if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "Sign in first") || len(rec.Result().Cookies()) != 0 {
			t.Errorf("%s: %d, %d cookies, want 403 and no session", c.name, rec.Code, len(rec.Result().Cookies()))
		}
	}
	// a session cookie alone, without the proxy's word, is not enough either
	rec := serve(mux, vouched(http.MethodGet, "/admin", "jaro"))
	session := rec.Result().Cookies()[0]
	if rec := get(mux, "/admin", session); rec.Code != http.StatusForbidden {
		t.Errorf("session without the proxy's headers: %d, want 403", rec.Code)
	}
}

func TestProxySignOutGoesToTheProxy(t *testing.T) {
	mux := newProxyWeb(t, "https://auth.test/logout?rd=https://doma.test")
	rec := serve(mux, vouched(http.MethodGet, "/admin", "jaro"))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Sign out") {
		t.Fatalf("GET /admin: %d, Sign out shown: %v", rec.Code, strings.Contains(rec.Body.String(), "Sign out"))
	}
	session := rec.Result().Cookies()[0]
	m := regexp.MustCompile(`name="_csrf" value="([^"]+)"`).FindStringSubmatch(rec.Body.String())
	if m == nil {
		t.Fatal("no CSRF token on the page")
	}
	r := vouched(http.MethodPost, "/admin/logout", "jaro", session)
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.Body = io.NopCloser(strings.NewReader(url.Values{"_csrf": {m[1]}}.Encode()))
	rec = serve(mux, r)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "https://auth.test/logout?rd=https://doma.test" {
		t.Errorf("POST /admin/logout: %d %s", rec.Code, rec.Header().Get("Location"))
	}
}

func TestPasswordModeIgnoresProxyHeaders(t *testing.T) {
	_, svc, mux := newWeb(t)
	if err := svc.Setup(context.Background(), "j", "long enough password"); err != nil {
		t.Fatal(err)
	}
	rec := serve(mux, vouched(http.MethodGet, "/admin", "jaro"))
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(rec.Header().Get("Location"), "/admin/login") || len(rec.Result().Cookies()) != 0 {
		t.Errorf("headers under password sign-in: %d %s, %d cookies; want the login redirect and no session", rec.Code, rec.Header().Get("Location"), len(rec.Result().Cookies()))
	}
}
