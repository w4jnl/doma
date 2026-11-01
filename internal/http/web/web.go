// Package web serves the pages a browser sees: the setup page that shows
// once, the admin pages, the invite page a phone opens, and, later, the
// guest view. html/template over tokens.css and one hand-written sheet; no
// inline styles, no script yet.
package web

import (
	"bytes"
	"embed"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/http/middleware"
	"github.com/w4jnl/doma/internal/ratelimit"
	"github.com/w4jnl/doma/internal/service"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

// LoginsPerMinute is the per-address limit on admin sign-in attempts.
const LoginsPerMinute = 5

// Web serves the pages.
type Web struct {
	svc      *service.Service
	log      *slog.Logger
	sessions *auth.Sessions
	logins   *ratelimit.Limiter
	pages    map[string]*template.Template
	now      func() time.Time
	secure   bool
	facts    *ServerFacts
	// challenges are admin sign-ins that passed the password and wait for
	// the code, keyed by a one-time cookie.
	challenges map[string]time.Time
	chMu       sync.Mutex
	// InviteDays is shown on the invite panel.
	InviteDays int
}

// New parses the templates. secure marks the admin cookie Secure.
func New(svc *service.Service, log *slog.Logger, secure bool) (*Web, error) {
	pages := map[string]*template.Template{}
	names, err := fs.Glob(templateFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	mark, err := inlineMark()
	if err != nil {
		return nil, err
	}
	sprite, err := inlineSprite()
	if err != nil {
		return nil, err
	}
	w := &Web{}
	funcs := template.FuncMap{
		"mark":   func() template.HTML { return mark },
		"sprite": func() template.HTML { return sprite },
		"ago":    func(ms int64) string { return ago(ms, w.now()) },
		"date":   func(ms int64) string { return domain.FromMillis(ms).Format("2 Jan 2006") },
		"qty": func(q *float64) string {
			if q == nil {
				return ""
			}
			return strconv.FormatFloat(*q, 'f', -1, 64)
		},
	}
	for _, name := range names {
		base := strings.TrimPrefix(name, "templates/")
		if base == "layout.html" || strings.HasPrefix(base, "_") {
			continue
		}
		files := []string{"templates/layout.html", name}
		if strings.HasPrefix(base, "guest") || base == "_guest_fragment.html" {
			files = append(files, "templates/_guest_list.html")
		}
		t, err := template.New("layout.html").Funcs(funcs).ParseFS(templateFS, files...)
		if err != nil {
			return nil, fmt.Errorf("template %s: %w", name, err)
		}
		pages[strings.TrimSuffix(base, ".html")] = t
	}
	// the polled fragment: the list alone, no layout
	frag, err := template.New("_guest_fragment.html").Funcs(funcs).ParseFS(templateFS, "templates/_guest_fragment.html", "templates/_guest_list.html")
	if err != nil {
		return nil, fmt.Errorf("guest fragment: %w", err)
	}
	pages["_guest_fragment"] = frag
	*w = Web{svc: svc, log: log, sessions: auth.NewSessions(secure), logins: ratelimit.New(LoginsPerMinute, LoginsPerMinute), pages: pages, now: func() time.Time { return time.Now().UTC() }, secure: secure, challenges: map[string]time.Time{}, InviteDays: 7}
	return w, nil
}

// SetClock replaces the clock, for tests.
func (h *Web) SetClock(now func() time.Time) {
	h.now = now
	h.sessions.Now = now
}

// Mount registers every page.
func (h *Web) Mount(mux *http.ServeMux) {
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", cacheStatic(http.FileServer(http.FS(static)))))
	mux.HandleFunc("GET /{$}", h.root)
	mux.HandleFunc("GET /setup", h.setupForm)
	mux.HandleFunc("POST /setup", h.setup)
	mux.HandleFunc("GET /admin/login", h.loginForm)
	mux.HandleFunc("POST /admin/login", h.login)
	mux.HandleFunc("GET /admin/login/code", h.codeForm)
	mux.HandleFunc("POST /admin/login/code", h.code)
	mux.HandleFunc("POST /admin/logout", h.admin(h.logout))
	mux.HandleFunc("GET /admin", h.admin(h.households))
	mux.HandleFunc("POST /admin/households", h.admin(h.createHousehold))
	mux.HandleFunc("GET /admin/h/{id}", h.admin(h.household))
	mux.HandleFunc("POST /admin/h/{id}/invite", h.admin(h.ownerInvite))
	mux.HandleFunc("POST /admin/h/{id}/quotas", h.admin(h.setQuotas))
	mux.HandleFunc("POST /admin/h/{id}/delete", h.admin(h.deleteHousehold))
	mux.HandleFunc("GET /admin/h/{id}/export", h.admin(h.exportHousehold))
	mux.HandleFunc("GET /admin/server", h.admin(h.serverPage))
	mux.HandleFunc("POST /admin/server/apns", h.admin(h.uploadAPNSKey))
	mux.HandleFunc("POST /admin/server/backup", h.admin(h.backupNow))
	mux.HandleFunc("POST /admin/server/snapshot", h.admin(h.runSnapshots))
	mux.HandleFunc("POST /admin/server/log", h.admin(h.setLogLevel))
	mux.HandleFunc("POST /admin/server/totp/setup", h.admin(h.totpSetupPage))
	mux.HandleFunc("POST /admin/server/totp/confirm", h.admin(h.totpConfirm))
	mux.HandleFunc("POST /admin/server/totp/off", h.admin(h.totpOff))
	mux.HandleFunc("GET /i/{token}", h.invitePage)
	mux.HandleFunc("GET /g/{token}", h.guest(h.guestPage))
	mux.HandleFunc("GET /g/{token}/list", h.guest(h.guestList))
	mux.HandleFunc("POST /g/{token}/add", h.guest(h.guestAdd))
	mux.HandleFunc("POST /g/{token}/check/{entry}", h.guest(h.guestCheck))
	mux.HandleFunc("POST /g/{token}/clear", h.guest(h.guestClear))
}

// inlineMark is the brand mark from assets/brand, inlined so it takes the
// page's colour; the file is ours and has no user text.
func inlineMark() (template.HTML, error) {
	raw, err := staticFS.ReadFile("static/doma-mark.svg")
	if err != nil {
		return "", err
	}
	svg := string(raw)
	svg = strings.Replace(svg, "<svg ", `<svg class="dm-mark" aria-hidden="true" `, 1)
	if i := strings.Index(svg, "<title>"); i >= 0 {
		if j := strings.Index(svg, "</title>"); j > i {
			svg = svg[:i] + svg[j+len("</title>"):]
		}
	}
	return template.HTML(svg), nil //nolint:gosec // G203: our own asset
}

// inlineSprite is the pictogram sprite from assets/icons, inlined once so
// <use href="#i-name"> works on every page.
func inlineSprite() (template.HTML, error) {
	raw, err := staticFS.ReadFile("static/doma-icons.svg")
	if err != nil {
		return "", err
	}
	svg := string(raw)
	if i := strings.Index(svg, "<svg"); i > 0 {
		svg = svg[i:]
	}
	svg = strings.Replace(svg, "<svg ", `<svg class="dm-sprite" aria-hidden="true" width="0" height="0" `, 1)
	return template.HTML(svg), nil //nolint:gosec // G203: our own asset
}

func cacheStatic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=3600")
		next.ServeHTTP(w, r)
	})
}

// page is what every template gets.
type page struct {
	Title string
	// Bare pages (setup, login, invite) are one card on ground; Guest pages
	// have the mark and nothing else; the rest have the admin top bar.
	Bare  bool
	Guest bool
	// Live pages load htmx; Alert pages carry the alert favicon.
	Live  bool
	Alert bool
	Nav   string
	CSRF  string
	Error string
	Data  any
}

func (h *Web) renderBytes(name string, p page) ([]byte, error) {
	t, ok := h.pages[name]
	if !ok {
		return nil, fmt.Errorf("no template %s", name)
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, p); err != nil {
		return nil, fmt.Errorf("render %s: %w", name, err)
	}
	return buf.Bytes(), nil
}

func (h *Web) render(w http.ResponseWriter, status int, name string, p page) {
	body, err := h.renderBytes(name, p)
	if err != nil {
		h.log.Error("render", "err", err)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// root sends a browser to setup, to the admin pages or to the login.
func (h *Web) root(w http.ResponseWriter, r *http.Request) {
	ok, err := h.svc.AdminExists(r.Context())
	if err != nil {
		h.fail(w, r, err)
		return
	}
	if !ok {
		http.Redirect(w, r, "/setup", http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/admin", http.StatusSeeOther)
}

func (h *Web) fail(w http.ResponseWriter, r *http.Request, err error) {
	h.log.Error("web error", "err", err, "path", r.URL.Path, "req_id", middleware.GetRequestID(r.Context()))
	http.Error(w, "internal server error", http.StatusInternalServerError)
}

// setup

type setupData struct{ Login string }

func (h *Web) setupForm(w http.ResponseWriter, r *http.Request) {
	ok, err := h.svc.AdminExists(r.Context())
	if err != nil {
		h.fail(w, r, err)
		return
	}
	if ok {
		http.NotFound(w, r)
		return
	}
	h.render(w, http.StatusOK, "setup", page{Title: "Set up", Bare: true, Data: setupData{}})
}

func (h *Web) setup(w http.ResponseWriter, r *http.Request) {
	ok, err := h.svc.AdminExists(r.Context())
	if err != nil {
		h.fail(w, r, err)
		return
	}
	if ok {
		http.NotFound(w, r)
		return
	}
	login := r.PostFormValue("login")
	password := r.PostFormValue("password")
	if password != r.PostFormValue("confirm") {
		h.render(w, http.StatusUnprocessableEntity, "setup", page{Title: "Set up", Bare: true, Error: "The two passwords differ. Type them again.", Data: setupData{Login: login}})
		return
	}
	if err := h.svc.Setup(r.Context(), login, password); err != nil {
		var ve domain.ErrValidation
		if errors.As(err, &ve) {
			h.render(w, http.StatusUnprocessableEntity, "setup", page{Title: "Set up", Bare: true, Error: ve.Msg, Data: setupData{Login: login}})
			return
		}
		if errors.Is(err, domain.ErrConflict) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	if _, err := h.sessions.Start(w); err != nil {
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/admin", http.StatusSeeOther)
}

// login

type loginData struct{ Login, Next string }

func safeNext(next string) string {
	if strings.HasPrefix(next, "/admin") && !strings.HasPrefix(next, "//") {
		return next
	}
	return "/admin"
}

func (h *Web) loginForm(w http.ResponseWriter, r *http.Request) {
	if h.sessions.From(r) != nil {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	h.render(w, http.StatusOK, "login", page{Title: "Sign in", Bare: true, Data: loginData{Next: safeNext(r.URL.Query().Get("next"))}})
}

func (h *Web) login(w http.ResponseWriter, r *http.Request) {
	login := r.PostFormValue("login")
	next := safeNext(r.PostFormValue("next"))
	if ok, _ := h.logins.Allow(middleware.ClientIP(r)); !ok {
		h.render(w, http.StatusTooManyRequests, "login", page{Title: "Sign in", Bare: true, Error: "Too many tries. Wait a minute.", Data: loginData{Login: login, Next: next}})
		return
	}
	if err := h.svc.VerifyAdmin(r.Context(), login, r.PostFormValue("password")); err != nil {
		if errors.Is(err, domain.ErrUnauthorized) {
			h.log.Info("admin login failed", "ip", middleware.ClientIP(r))
			h.render(w, http.StatusUnauthorized, "login", page{Title: "Sign in", Bare: true, Error: "That name and password do not match.", Data: loginData{Login: login, Next: next}})
			return
		}
		h.fail(w, r, err)
		return
	}
	if on, err := h.svc.TOTPEnabled(r.Context()); err == nil && on {
		id, err := auth.NewToken()
		if err != nil {
			h.fail(w, r, err)
			return
		}
		h.chMu.Lock()
		h.challenges[id] = h.now().Add(5 * time.Minute)
		h.chMu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: challengeCookie, Value: id, Path: "/admin/login", HttpOnly: true, Secure: h.secure, SameSite: http.SameSiteLaxMode, MaxAge: 300}) //nolint:gosec // G124: as the session cookie
		http.Redirect(w, r, "/admin/login/code?next="+next, http.StatusSeeOther)                                                                                               //nolint:gosec // G710: next is checked by safeNext
		return
	}
	if _, err := h.sessions.Start(w); err != nil {
		h.fail(w, r, err)
		return
	}
	h.log.Info("admin login", "ip", middleware.ClientIP(r))
	http.Redirect(w, r, next, http.StatusSeeOther) //nolint:gosec // G710: safeNext allows /admin paths only
}

const challengeCookie = "doma_admin_code"

// challenge returns whether the browser passed the password in the last
// five minutes.
func (h *Web) challenge(r *http.Request) (string, bool) {
	c, err := r.Cookie(challengeCookie)
	if err != nil || c.Value == "" {
		return "", false
	}
	h.chMu.Lock()
	defer h.chMu.Unlock()
	exp, ok := h.challenges[c.Value]
	if !ok || exp.Before(h.now()) {
		delete(h.challenges, c.Value)
		return "", false
	}
	return c.Value, true
}

func (h *Web) codeForm(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.challenge(r); !ok {
		http.Redirect(w, r, "/admin/login", http.StatusSeeOther)
		return
	}
	h.render(w, http.StatusOK, "login_code", page{Title: "Sign in", Bare: true, Data: loginData{Next: safeNext(r.URL.Query().Get("next"))}})
}

func (h *Web) code(w http.ResponseWriter, r *http.Request) {
	id, ok := h.challenge(r)
	if !ok {
		http.Redirect(w, r, "/admin/login", http.StatusSeeOther)
		return
	}
	next := safeNext(r.PostFormValue("next"))
	if ok, _ := h.logins.Allow(middleware.ClientIP(r)); !ok {
		h.render(w, http.StatusTooManyRequests, "login_code", page{Title: "Sign in", Bare: true, Error: "Too many tries. Wait a minute.", Data: loginData{Next: next}})
		return
	}
	if err := h.svc.VerifyTOTP(r.Context(), r.PostFormValue("code")); err != nil {
		if errors.Is(err, domain.ErrUnauthorized) {
			h.render(w, http.StatusUnauthorized, "login_code", page{Title: "Sign in", Bare: true, Error: "That code does not match.", Data: loginData{Next: next}})
			return
		}
		h.fail(w, r, err)
		return
	}
	h.chMu.Lock()
	delete(h.challenges, id)
	h.chMu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: challengeCookie, Value: "", Path: "/admin/login", MaxAge: -1, HttpOnly: true, Secure: h.secure, SameSite: http.SameSiteLaxMode}) //nolint:gosec // G124: Secure follows server.base_url's scheme
	if _, err := h.sessions.Start(w); err != nil {
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, next, http.StatusSeeOther) //nolint:gosec // G710: safeNext allows /admin paths only
}

func (h *Web) logout(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	h.sessions.End(w, r)
	http.Redirect(w, r, "/admin/login", http.StatusSeeOther)
}

// admin wraps a page that needs the admin's session; a POST also needs the
// CSRF token.
func (h *Web) admin(fn func(http.ResponseWriter, *http.Request, *auth.Session)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess := h.sessions.From(r)
		if sess == nil {
			if r.Method == http.MethodGet {
				http.Redirect(w, r, "/admin/login?next="+r.URL.Path, http.StatusSeeOther) //nolint:gosec // G710: our own login page; next is checked by safeNext on the way back
				return
			}
			http.Error(w, "sign in first", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet && !auth.CheckCSRF(r, sess) {
			http.Error(w, "the form is stale; reload the page", http.StatusForbidden)
			return
		}
		fn(w, r, sess)
	}
}

// invitePage is what a phone shows when the link opens in a browser.

type inviteData struct {
	Household, Role, Until string
	// AppLink is doma://invite#<token>; html/template would otherwise refuse
	// the scheme. The token is base64url and ours.
	AppLink template.URL
}

func (h *Web) invitePage(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	inv, err := h.svc.InviteByToken(r.Context(), token)
	if err != nil {
		reason := "Ask the family for a new invite."
		if errors.Is(err, domain.ErrConflict) {
			reason = "That invite was used already. Ask for a new one."
		} else if !errors.Is(err, domain.ErrNotFound) {
			h.fail(w, r, err)
			return
		}
		h.render(w, http.StatusNotFound, "gone", page{Title: "Invite", Bare: true, Data: map[string]string{"Reason": reason}})
		return
	}
	// the token travels in the fragment, which never reaches a log
	h.render(w, http.StatusOK, "invite", page{Title: "Invite", Bare: true, Data: inviteData{
		Household: inv.Household.Name, Role: string(inv.Role), AppLink: template.URL("doma://invite#" + token), //nolint:gosec // G203: see inviteData
		Until: domain.FromMillis(inv.ExpiresAt).Format("2 January"),
	}})
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
