package web_test

import (
	"context"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/http/web"
	"github.com/w4jnl/doma/internal/secrets"
	"github.com/w4jnl/doma/internal/service"
)

func adminSession(t *testing.T, mux http.Handler) (*http.Cookie, string) {
	t.Helper()
	rec := post(mux, "/setup", url.Values{"login": {"j"}, "password": {"long enough password"}, "confirm": {"long enough password"}})
	session := rec.Result().Cookies()[0]
	body := get(mux, "/admin", session).Body.String()
	csrf := regexp.MustCompile(`name="_csrf" value="([^"]+)"`).FindStringSubmatch(body)
	if csrf == nil {
		t.Fatal("no csrf token")
	}
	return session, csrf[1]
}

func TestServerPage(t *testing.T) {
	h, svc, mux := newWeb(t)
	k, _ := secrets.FromBytes([]byte("0123456789abcdef0123456789abcdef"))
	svc.SetKeyring(k)
	var sealed []byte
	h.SetServerFacts(web.ServerFacts{BaseURL: "https://doma.test", Version: "test", PushKeyFile: "/nowhere/apns.p8", ConfigTOML: "[server]\nlisten = ':8080'\n", LastPushError: func() string { return "" }, SealKey: func(p []byte) error { sealed = p; return nil }})
	session, csrf := adminSession(t, mux)
	rec := get(mux, "/admin/server", session)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "no APNs key yet") || !strings.Contains(rec.Body.String(), "listen = &#39;:8080&#39;") {
		t.Fatalf("server page: %d %s", rec.Code, rec.Body.String())
	}
	// log level
	if rec := post(mux, "/admin/server/log", url.Values{"_csrf": {csrf}, "level": {"debug"}}, session); rec.Code != http.StatusSeeOther {
		t.Errorf("log level: %d", rec.Code)
	}
	if body := get(mux, "/admin/server", session).Body.String(); !strings.Contains(body, `value="debug" selected`) {
		t.Error("log level not shown as debug")
	}
	// totp on, then sign-in asks for the code
	rec = post(mux, "/admin/server/totp/setup", url.Values{"_csrf": {csrf}}, session)
	secret := regexp.MustCompile(`name="secret" value="([^"]+)"`).FindStringSubmatch(rec.Body.String())
	if rec.Code != http.StatusOK || secret == nil || !strings.Contains(rec.Body.String(), "<svg") {
		t.Fatalf("totp setup: %d", rec.Code)
	}
	if rec := post(mux, "/admin/server/totp/confirm", url.Values{"_csrf": {csrf}, "secret": {secret[1]}, "code": {"000000"}}, session); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("bad code accepted: %d", rec.Code)
	}
	code, _ := auth.TOTPCode(secret[1], time.Now())
	if rec := post(mux, "/admin/server/totp/confirm", url.Values{"_csrf": {csrf}, "secret": {secret[1]}, "code": {code}}, session); rec.Code != http.StatusSeeOther {
		t.Fatalf("confirm: %d", rec.Code)
	}
	rec = post(mux, "/admin/login", url.Values{"login": {"j"}, "password": {"long enough password"}})
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(rec.Header().Get("Location"), "/admin/login/code") {
		t.Fatalf("login with totp: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	challenge := rec.Result().Cookies()[0]
	if rec := post(mux, "/admin/login/code", url.Values{"code": {"000000"}}, challenge); rec.Code != http.StatusUnauthorized {
		t.Errorf("wrong code: %d", rec.Code)
	}
	code, _ = auth.TOTPCode(secret[1], time.Now())
	rec = post(mux, "/admin/login/code", url.Values{"code": {code}}, challenge)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/admin" {
		t.Errorf("code: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	if rec := get(mux, "/admin/login/code"); rec.Code != http.StatusSeeOther {
		t.Errorf("code page without a challenge: %d", rec.Code)
	}
	// apns upload
	var buf strings.Builder
	boundary := "xxBOUNDARYxx"
	buf.WriteString("--" + boundary + "\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n" + csrf + "\r\n")
	buf.WriteString("--" + boundary + "\r\nContent-Disposition: form-data; name=\"key\"; filename=\"AuthKey.p8\"\r\nContent-Type: application/octet-stream\r\n\r\n-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n\r\n")
	buf.WriteString("--" + boundary + "--\r\n")
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, "/admin/server/apns", strings.NewReader(buf.String()))
	req.Header.Set("Content-Type", "multipart/form-data; boundary="+boundary)
	req.AddCookie(session)
	rec2 := newRecorder()
	mux.ServeHTTP(rec2, req)
	if rec2.Code != http.StatusSeeOther || !strings.Contains(string(sealed), "BEGIN PRIVATE KEY") {
		t.Errorf("apns upload: %d %q", rec2.Code, sealed)
	}
	// backup
	if rec := post(mux, "/admin/server/backup", url.Values{"_csrf": {csrf}}, session); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "doma-backup-") {
		t.Errorf("backup: %d", rec.Code)
	}
}

func TestHouseholdPageAndGuestView(t *testing.T) {
	_, svc, mux := newWeb(t)
	session, csrf := adminSession(t, mux)
	ctx := context.Background()
	hh, _ := svc.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	rec := get(mux, "/admin/h/"+hh.ID, session)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Quotas") || !strings.Contains(rec.Body.String(), "Delete") {
		t.Fatalf("household page: %d", rec.Code)
	}
	if rec := post(mux, "/admin/h/"+hh.ID+"/quotas", url.Values{"_csrf": {csrf}, "devices": {"x"}}, session); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("bad quota: %d", rec.Code)
	}
	if rec := post(mux, "/admin/h/"+hh.ID+"/quotas", url.Values{"_csrf": {csrf}, "devices": {"4"}, "photo_mb": {"100"}}, session); rec.Code != http.StatusSeeOther {
		t.Errorf("quota: %d", rec.Code)
	}
	if rec := get(mux, "/admin/h/"+hh.ID+"/export", session); rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/zip" {
		t.Errorf("export: %d", rec.Code)
	}
	// delete asks once, then deletes
	rec = post(mux, "/admin/h/"+hh.ID+"/delete", url.Values{"_csrf": {csrf}}, session)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Really delete?") {
		t.Fatalf("delete first step: %d", rec.Code)
	}
	// a guest, before the delete: link, page, add, check, clear, fragment with ETag
	homes, lists := detail(t, svc, hh.ID)
	g, err := svc.CreateGuestLink(ctx, domain.Scope{HouseholdID: hh.ID, Role: domain.RoleOwner}, homes, lists, "cleaner", 0)
	if err != nil {
		t.Fatal(err)
	}
	rec = get(mux, "/g/"+g.Token)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "<h1>Gouda</h1>") || !strings.Contains(rec.Body.String(), "htmx.min.js") || !strings.Contains(rec.Body.String(), `id="i-out"`) || len(rec.Result().Cookies()) == 0 {
		t.Fatalf("guest page: %d %s", rec.Code, rec.Body.String())
	}
	guestCookie := rec.Result().Cookies()[0]
	if rec := get(mux, "/g/me", guestCookie); rec.Code != http.StatusOK {
		t.Errorf("guest by cookie: %d", rec.Code)
	}
	rec = post(mux, "/g/"+g.Token+"/add", url.Values{"text": {"melk 2"}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("plain add: %d", rec.Code)
	}
	body := get(mux, "/g/"+g.Token).Body.String()
	entry := regexp.MustCompile(`/check/([A-Za-z0-9]+)"`).FindStringSubmatch(body)
	if entry == nil || !strings.Contains(body, "melk") {
		t.Fatalf("no entry on the page: %s", body)
	}
	hx := func(path string, form url.Values) *httptestRecorder {
		r := newRequest(http.MethodPost, path, form)
		r.Header.Set("HX-Request", "true")
		rec := newRecorder()
		mux.ServeHTTP(rec, r)
		return rec
	}
	rec3 := hx("/g/"+g.Token+"/check/"+entry[1], nil)
	if rec3.Code != http.StatusOK || !strings.Contains(rec3.Body.String(), "dm-done") || strings.Contains(rec3.Body.String(), "<html") {
		t.Errorf("htmx check: %d %s", rec3.Code, rec3.Body.String())
	}
	frag := get(mux, "/g/"+g.Token+"/list")
	etag := frag.Header().Get("ETag")
	if frag.Code != http.StatusOK || etag == "" {
		t.Fatalf("fragment: %d", frag.Code)
	}
	r := newRequest(http.MethodGet, "/g/"+g.Token+"/list", nil)
	r.Header.Set("If-None-Match", etag)
	rec4 := newRecorder()
	mux.ServeHTTP(rec4, r)
	if rec4.Code != http.StatusNotModified {
		t.Errorf("etag: %d", rec4.Code)
	}
	if rec := hx("/g/"+g.Token+"/clear", nil); rec.Code != http.StatusOK || strings.Contains(rec.Body.String(), "dm-done") {
		t.Errorf("clear: %d", rec.Code)
	}
	if rec := get(mux, "/g/nope-nope-nope-nope-nope-nope"); rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "no longer valid") {
		t.Errorf("bad link: %d", rec.Code)
	}
	// the admin page lists the guest link
	if body := get(mux, "/admin/h/"+hh.ID, session).Body.String(); !strings.Contains(body, "cleaner") {
		t.Error("guest link not on the household page")
	}
	_ = service.DefaultListName
}

func detail(t *testing.T, svc *service.Service, id string) (home, list string) {
	t.Helper()
	d, err := svc.HouseholdDetail(context.Background(), id)
	if err != nil || len(d.Homes) != 1 || len(d.Lists) != 1 {
		t.Fatalf("detail %+v %v", d, err)
	}
	return d.Homes[0].ID, d.Lists[0].ID
}
