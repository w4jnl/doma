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
	"strings"
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
	funcs := template.FuncMap{"mark": func() template.HTML { return mark }}
	for _, name := range names {
		if strings.HasSuffix(name, "layout.html") {
			continue
		}
		t, err := template.New("layout.html").Funcs(funcs).ParseFS(templateFS, "templates/layout.html", name)
		if err != nil {
			return nil, fmt.Errorf("template %s: %w", name, err)
		}
		pages[strings.TrimSuffix(strings.TrimPrefix(name, "templates/"), ".html")] = t
	}
	return &Web{svc: svc, log: log, sessions: auth.NewSessions(secure), logins: ratelimit.New(LoginsPerMinute, LoginsPerMinute), pages: pages, now: func() time.Time { return time.Now().UTC() }, InviteDays: 7}, nil
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
	mux.HandleFunc("POST /admin/logout", h.admin(h.logout))
	mux.HandleFunc("GET /admin", h.admin(h.households))
	mux.HandleFunc("POST /admin/households", h.admin(h.createHousehold))
	mux.HandleFunc("GET /admin/h/{id}", h.admin(h.household))
	mux.HandleFunc("POST /admin/h/{id}/invite", h.admin(h.ownerInvite))
	mux.HandleFunc("GET /i/{token}", h.invitePage)
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

func cacheStatic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=3600")
		next.ServeHTTP(w, r)
	})
}

// page is what every template gets.
type page struct {
	Title string
	// Bare pages (setup, login, invite) are one card on ground; the rest
	// have the admin top bar.
	Bare  bool
	Nav   string
	CSRF  string
	Error string
	Data  any
}

func (h *Web) render(w http.ResponseWriter, status int, name string, p page) {
	t, ok := h.pages[name]
	if !ok {
		h.log.Error("no template", "name", name)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, p); err != nil {
		h.log.Error("render", "name", name, "err", err)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = buf.WriteTo(w)
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
	if _, err := h.sessions.Start(w); err != nil {
		h.fail(w, r, err)
		return
	}
	h.log.Info("admin login", "ip", middleware.ClientIP(r))
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

// households

type householdRow struct {
	ID, Name, Timezone string
	Members, Devices   int
}

type householdsData struct {
	Households []householdRow
	Timezone   string
	Notice     string
}

func (h *Web) households(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	h.renderHouseholds(w, r, sess, http.StatusOK, "", r.URL.Query().Get("created"))
}

func (h *Web) renderHouseholds(w http.ResponseWriter, r *http.Request, sess *auth.Session, status int, errMsg, created string) {
	hs, err := h.svc.Households(r.Context())
	if err != nil {
		h.fail(w, r, err)
		return
	}
	data := householdsData{Timezone: "Europe/Amsterdam"}
	for _, hh := range hs {
		row := householdRow{ID: hh.ID, Name: hh.Name, Timezone: hh.Timezone}
		if ms, err := h.svc.Members(r.Context(), domain.Scope{HouseholdID: hh.ID, Role: domain.RoleOwner}); err == nil {
			row.Members = len(ms)
		}
		data.Households = append(data.Households, row)
		if hh.ID == created {
			data.Notice = hh.Name + " is created. Open it and make the first owner invite."
		}
	}
	h.render(w, status, "households", page{Title: "Households", Nav: "households", CSRF: sess.CSRF, Error: errMsg, Data: data})
}

func (h *Web) createHousehold(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	hh, err := h.svc.CreateHousehold(r.Context(), r.PostFormValue("name"), r.PostFormValue("timezone"), r.PostFormValue("home"))
	if err != nil {
		var ve domain.ErrValidation
		if errors.As(err, &ve) {
			h.renderHouseholds(w, r, sess, http.StatusUnprocessableEntity, ve.Msg, "")
			return
		}
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/admin/h/"+hh.ID, http.StatusSeeOther) //nolint:gosec // G710: the id is a ULID we just made
}

type inviteView struct {
	URL string
	QR  template.HTML
}

type householdData struct {
	Household  domain.Household
	Members    []domain.Member
	Invite     *inviteView
	InviteDays int
}

func (h *Web) household(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	h.renderHousehold(w, r, sess, r.PathValue("id"), nil)
}

func (h *Web) renderHousehold(w http.ResponseWriter, r *http.Request, sess *auth.Session, id string, inv *inviteView) {
	hh, err := h.svc.HouseholdByID(r.Context(), id)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	ms, err := h.svc.Members(r.Context(), domain.Scope{HouseholdID: id, Role: domain.RoleOwner})
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.render(w, http.StatusOK, "household", page{Title: hh.Name, Nav: "households", CSRF: sess.CSRF, Data: householdData{Household: *hh, Members: ms, Invite: inv, InviteDays: h.InviteDays}})
}

// ownerInvite makes the bootstrap invite for a household with no owner
// yet, and shows it once as a QR.
func (h *Web) ownerInvite(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	id := r.PathValue("id")
	inv, err := h.svc.CreateInvite(r.Context(), domain.Scope{HouseholdID: id, Role: domain.RoleOwner}, domain.RoleOwner)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	svg, err := qrSVG(inv.URL)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.renderHousehold(w, r, sess, id, &inviteView{URL: inv.URL, QR: template.HTML(svg)}) //nolint:gosec // G203: the SVG is built from a URL we made, with no user text
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
