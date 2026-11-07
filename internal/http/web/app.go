package web

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

// The web client under /app: a family member's browser. It signs in with a
// passkey, or the first time by showing a code the member's phone scans, and
// then reads and writes the household's lists through the same service the
// apps use. No offline support; the apps keep the sync path.

const (
	// householdCookie remembers the household a browser had in front.
	householdCookie = "doma_household"
	// ceremonyCookie binds a passkey ceremony's two halves to one browser.
	ceremonyCookie = "doma_ceremony"
	ceremonyTTL    = 5 * time.Minute
)

// ceremony is a passkey registration or sign-in between its begin and finish.
type ceremony struct {
	sd       webauthn.SessionData
	personID string
	exp      time.Time
}

func (h *Web) mountApp(mux *http.ServeMux) {
	mux.HandleFunc("GET /app", h.appRoot)
	mux.HandleFunc("GET /app/{$}", h.appRoot)
	mux.HandleFunc("GET /app/wait/{token}", h.appWait)
	mux.HandleFunc("GET /app/v/{token}", h.appVouchPage)
	mux.HandleFunc("POST /app/signout", h.member(h.appSignOut))
	mux.HandleFunc("GET /app/passkey/login/begin", h.passkeyLoginBegin)
	mux.HandleFunc("POST /app/passkey/login/finish", h.passkeyLoginFinish)
	mux.HandleFunc("GET /app/passkey/register/begin", h.member(h.passkeyRegisterBegin))
	mux.HandleFunc("POST /app/passkey/register/finish", h.member(h.passkeyRegisterFinish))
	mux.HandleFunc("GET /app/h/{household}/lists", h.inHousehold(h.appLists))
	mux.HandleFunc("POST /app/h/{household}/lists", h.inHousehold(h.appCreateList))
	mux.HandleFunc("GET /app/h/{household}/l/{list}", h.inHousehold(h.appList))
	mux.HandleFunc("GET /app/h/{household}/l/{list}/rows", h.inHousehold(h.appListRows))
	mux.HandleFunc("POST /app/h/{household}/l/{list}/add", h.inHousehold(h.appAdd))
	mux.HandleFunc("POST /app/h/{household}/l/{list}/check/{entry}", h.inHousehold(h.appCheck))
	mux.HandleFunc("POST /app/h/{household}/l/{list}/remove/{entry}", h.inHousehold(h.appRemove))
	mux.HandleFunc("POST /app/h/{household}/l/{list}/clear", h.inHousehold(h.appClear))
	h.mountApp2(mux)
}

// member requires a signed-in browser; a POST must carry the session's CSRF
// token. A browser without one is sent to the sign-in page.
func (h *Web) member(fn func(http.ResponseWriter, *http.Request, *auth.Session)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess := h.members.From(r)
		if sess == nil {
			if r.Method == http.MethodGet {
				http.Redirect(w, r, "/app", http.StatusSeeOther)
				return
			}
			http.Error(w, "sign in first", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet && !auth.CheckCSRF(r, sess) {
			http.Error(w, "refused", http.StatusForbidden)
			return
		}
		fn(w, r, sess)
	}
}

// inHousehold is member plus the household in the path, which the person
// must belong to; anything else is a 404.
func (h *Web) inHousehold(fn func(http.ResponseWriter, *http.Request, *auth.Session, domain.Scope)) http.HandlerFunc {
	return h.member(func(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
		sc, err := h.svc.MemberScope(r.Context(), sess.User, r.PathValue("household"))
		if err != nil {
			if errors.Is(err, domain.ErrNotFound) {
				http.NotFound(w, r)
				return
			}
			h.fail(w, r, err)
			return
		}
		http.SetCookie(w, &http.Cookie{ //nolint:gosec // G124: Secure follows server.base_url's scheme
			Name: householdCookie, Value: sc.HouseholdID, Path: "/app", HttpOnly: true, Secure: h.secure, SameSite: http.SameSiteLaxMode, Expires: h.now().Add(auth.MemberTTL),
		})
		fn(w, r, sess, sc)
	})
}

type signInData struct {
	QR   template.HTML
	Link string
	// Token is what the page polls with.
	Token string
}

// appRoot is /app: the household in front for a signed-in browser, the
// sign-in page for any other.
func (h *Web) appRoot(w http.ResponseWriter, r *http.Request) {
	if sess := h.members.From(r); sess != nil {
		hs, err := h.svc.WebHouseholds(r.Context(), sess.User)
		if err != nil {
			h.fail(w, r, err)
			return
		}
		if len(hs) == 0 {
			h.render(w, http.StatusOK, "app_none", page{Title: "doma", Bare: true})
			return
		}
		pick := hs[0].ID
		if c, err := r.Cookie(householdCookie); err == nil {
			for _, x := range hs {
				if x.ID == c.Value {
					pick = x.ID
				}
			}
		}
		http.Redirect(w, r, "/app/h/"+pick+"/lists", http.StatusSeeOther) //nolint:gosec // G710: a household id the person belongs to
		return
	}
	token, err := h.svc.NewVouch()
	if err != nil {
		h.fail(w, r, err)
		return
	}
	link := h.svc.BaseURL() + "/app/v/" + token
	svg, err := qrSVG(link)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.render(w, http.StatusOK, "app_signin", page{Title: "Sign in", Bare: true, Live: true, Passkeys: h.svc.PasskeysEnabled(), Data: signInData{QR: template.HTML(svg), Link: link, Token: token}}) //nolint:gosec // G203: our own QR
}

// appWait is what the sign-in page polls: nothing yet, the session once the
// phone vouched, or a refresh when the code is gone.
func (h *Web) appWait(w http.ResponseWriter, r *http.Request) {
	personID, credentialID, ok := h.svc.TakeVouch(r.PathValue("token"))
	switch {
	case !ok:
		if r.Header.Get("HX-Request") == "true" {
			w.Header().Set("HX-Refresh", "true")
			w.WriteHeader(http.StatusOK)
			return
		}
		http.Redirect(w, r, "/app", http.StatusSeeOther)
	case personID == "":
		w.WriteHeader(http.StatusNoContent)
	default:
		if _, err := h.members.StartMember(w, personID, credentialID); err != nil {
			h.fail(w, r, err)
			return
		}
		h.log.Info("member signed in by the phone", "person", personID)
		if r.Header.Get("HX-Request") == "true" {
			w.Header().Set("HX-Redirect", "/app")
			w.WriteHeader(http.StatusOK)
			return
		}
		http.Redirect(w, r, "/app", http.StatusSeeOther)
	}
}

// vouchData is the vouch page: the link as the code carries it and the app
// link that hands it to doma.
type vouchData struct {
	Link string
	// AppLink is doma://vouch/<host>#<code>; html/template would otherwise
	// refuse the scheme. The host is base_url's and the code is base64url and
	// ours; the code rides in the fragment, which never reaches a log.
	AppLink template.URL
}

// appVouchPage is where a phone's camera lands when it reads the code with
// something other than doma: a button that opens doma on it, and the words
// for scanning it there instead.
func (h *Web) appVouchPage(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	host := ""
	if u, err := url.Parse(h.svc.BaseURL()); err == nil {
		host = u.Host
	}
	h.render(w, http.StatusOK, "app_vouch", page{Title: "Sign in", Bare: true, Data: vouchData{
		Link:    h.svc.BaseURL() + "/app/v/" + token,
		AppLink: template.URL("doma://vouch/" + host + "#" + token), //nolint:gosec // G203: see vouchData
	}})
}

func (h *Web) appSignOut(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	h.members.End(w, r)
	http.Redirect(w, r, "/app", http.StatusSeeOther)
}

// passkeys

func (h *Web) putCeremony(w http.ResponseWriter, c ceremony) error {
	id, err := auth.NewToken()
	if err != nil {
		return err
	}
	c.exp = h.now().Add(ceremonyTTL)
	h.cerMu.Lock()
	for k, v := range h.ceremonies {
		if v.exp.Before(h.now()) {
			delete(h.ceremonies, k)
		}
	}
	h.ceremonies[id] = c
	h.cerMu.Unlock()
	http.SetCookie(w, &http.Cookie{ //nolint:gosec // G124: Secure follows server.base_url's scheme
		Name: ceremonyCookie, Value: id, Path: "/app/passkey", HttpOnly: true, Secure: h.secure, SameSite: http.SameSiteStrictMode, Expires: c.exp,
	})
	return nil
}

func (h *Web) takeCeremony(r *http.Request) (ceremony, bool) {
	c, err := r.Cookie(ceremonyCookie)
	if err != nil || c.Value == "" {
		return ceremony{}, false
	}
	h.cerMu.Lock()
	defer h.cerMu.Unlock()
	cer, ok := h.ceremonies[c.Value]
	delete(h.ceremonies, c.Value)
	if !ok || cer.exp.Before(h.now()) {
		return ceremony{}, false
	}
	return cer, true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (h *Web) passkeyLoginBegin(w http.ResponseWriter, r *http.Request) {
	opts, sd, err := h.svc.BeginPasskeyLogin()
	if err != nil {
		h.passkeyError(w, err)
		return
	}
	if err := h.putCeremony(w, ceremony{sd: *sd}); err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, opts)
}

func (h *Web) passkeyLoginFinish(w http.ResponseWriter, r *http.Request) {
	cer, ok := h.takeCeremony(r)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "The sign-in took too long. Try again."})
		return
	}
	personID, credentialID, err := h.svc.FinishPasskeyLogin(r.Context(), cer.sd, r)
	if err != nil {
		h.log.Info("passkey sign-in refused", "err", err)
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "That passkey is not known here."})
		return
	}
	if _, err := h.members.StartMember(w, personID, credentialID); err != nil {
		h.fail(w, r, err)
		return
	}
	h.log.Info("member signed in by a passkey", "person", personID)
	writeJSON(w, http.StatusOK, map[string]string{"to": "/app"})
}

func (h *Web) passkeyRegisterBegin(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	opts, sd, err := h.svc.BeginPasskeyRegistration(r.Context(), sess.User)
	if err != nil {
		h.passkeyError(w, err)
		return
	}
	if err := h.putCeremony(w, ceremony{sd: *sd, personID: sess.User}); err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, opts)
}

func (h *Web) passkeyRegisterFinish(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	cer, ok := h.takeCeremony(r)
	if !ok || cer.personID != sess.User {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "That took too long. Try again."})
		return
	}
	id, err := h.svc.FinishPasskeyRegistration(r.Context(), sess.User, browserLabel(r.UserAgent()), cer.sd, r)
	if err != nil {
		var ve domain.ErrValidation
		if errors.As(err, &ve) {
			h.log.Info("passkey refused", "err", err)
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "The browser's answer was not a passkey for this doma."})
			return
		}
		h.fail(w, r, err)
		return
	}
	// the browser's session is the passkey's from now on
	if _, err := h.members.StartMember(w, sess.User, id); err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"to": r.Referer()})
}

func (h *Web) passkeyError(w http.ResponseWriter, err error) {
	if errors.Is(err, service.ErrNoPasskeys) {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "Passkeys need the server's address set."})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal server error"})
}

// browserLabel names a passkey after its browser: "Safari on Mac".
func browserLabel(ua string) string {
	browser := "Browser"
	switch {
	case strings.Contains(ua, "Edg/"):
		browser = "Edge"
	case strings.Contains(ua, "Firefox/"):
		browser = "Firefox"
	case strings.Contains(ua, "Chrome/"), strings.Contains(ua, "CriOS/"):
		browser = "Chrome"
	case strings.Contains(ua, "Safari/"):
		browser = "Safari"
	}
	device := ""
	switch {
	case strings.Contains(ua, "iPhone"):
		device = "iPhone"
	case strings.Contains(ua, "iPad"):
		device = "iPad"
	case strings.Contains(ua, "Macintosh"):
		device = "Mac"
	case strings.Contains(ua, "Windows"):
		device = "Windows"
	case strings.Contains(ua, "Android"):
		device = "Android"
	case strings.Contains(ua, "Linux"):
		device = "Linux"
	}
	if device == "" {
		return browser
	}
	return browser + " on " + device
}

// lists

type listsData struct {
	Base  string
	Lists []service.WebList
	// OfferPasskey is set while the browser is signed in by the phone and
	// has no passkey of its own yet.
	OfferPasskey bool
	Error        string
}

func (h *Web) memberPage(r *http.Request, sess *auth.Session, sc domain.Scope, title, nav string) (page, error) {
	hs, err := h.svc.WebHouseholds(r.Context(), sess.User)
	if err != nil {
		return page{}, err
	}
	return page{Title: title, Member: true, Nav: nav, CSRF: sess.CSRF, Households: hs, Household: sc.HouseholdID, Live: true}, nil
}

func (h *Web) offerPasskey(r *http.Request, sess *auth.Session) bool {
	if !h.svc.PasskeysEnabled() {
		return false
	}
	me, err := h.svc.Me(r.Context(), sess.User)
	if err != nil {
		return false
	}
	for _, c := range me.Credentials {
		if c.ID == sess.Credential {
			return c.Kind != domain.KindPasskey
		}
	}
	return false
}

func (h *Web) appLists(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.renderLists(w, r, sess, sc, http.StatusOK, "")
}

func (h *Web) renderLists(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, status int, problem string) {
	lists, err := h.svc.WebLists(r.Context(), sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p, err := h.memberPage(r, sess, sc, "Lists", "lists")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Passkeys = h.svc.PasskeysEnabled()
	p.Data = listsData{Base: "/app/h/" + sc.HouseholdID, Lists: lists, OfferPasskey: h.offerPasskey(r, sess), Error: problem}
	h.render(w, status, "app_lists", p)
}

func (h *Web) appCreateList(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	name := strings.TrimSpace(r.PostFormValue("name"))
	personal := r.PostFormValue("who") == "me"
	tasks := r.PostFormValue("what") == "tasks"
	id, err := h.svc.WebCreateList(r.Context(), sc, sess.Credential, name, personal, tasks)
	if err != nil {
		var ve domain.ErrValidation
		if errors.As(err, &ve) {
			h.renderLists(w, r, sess, sc, http.StatusUnprocessableEntity, ve.Msg)
			return
		}
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/app/h/"+sc.HouseholdID+"/l/"+id, http.StatusSeeOther) //nolint:gosec // G710: the list just made, in the scope's household
}

// one list

type listData struct {
	// Base is the list's path, which its forms post under.
	Base string
	View *service.WebListView
}

func (h *Web) appList(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	view, err := h.svc.WebList(r.Context(), sc, r.PathValue("list"))
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	p, err := h.memberPage(r, sess, sc, view.List.Name, "lists")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Data = listData{Base: listBase(sc, r), View: view}
	h.render(w, http.StatusOK, "app_list", p)
}

func listBase(sc domain.Scope, r *http.Request) string {
	return "/app/h/" + sc.HouseholdID + "/l/" + r.PathValue("list")
}

// appListRows is the polled fragment, with an ETag so a quiet list costs a 304.
func (h *Web) appListRows(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.appFragment(w, r, sess, sc, "_app_rows")
}

func (h *Web) appFragment(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, name string) {
	view, err := h.svc.WebList(r.Context(), sc, r.PathValue("list"))
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	body, err := h.renderBytes(name, page{Member: true, CSRF: sess.CSRF, Data: listData{Base: listBase(sc, r), View: view}})
	if err != nil {
		h.fail(w, r, err)
		return
	}
	sum := sha256.Sum256(body)
	etag := `"` + hex.EncodeToString(sum[:8]) + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-cache")
	if r.Method == http.MethodGet && r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// appAfter answers a change: htmx gets the fragment, a plain form the page.
func (h *Web) appAfter(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, name string) {
	if r.Header.Get("HX-Request") == "true" {
		h.appFragment(w, r, sess, sc, name)
		return
	}
	http.Redirect(w, r, listBase(sc, r), http.StatusSeeOther) //nolint:gosec // G710: the path the request came from, in the scope's household
}

func (h *Web) appAdd(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	text := strings.TrimSpace(r.PostFormValue("text"))
	if err := h.svc.WebAdd(r.Context(), sc, sess.Credential, r.PathValue("list"), text); err != nil {
		var ve domain.ErrValidation
		if !errors.As(err, &ve) {
			h.appProblem(w, r, err)
			return
		}
	}
	h.appAfter(w, r, sess, sc, "_app_panel")
}

func (h *Web) appCheck(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if err := h.svc.WebToggle(r.Context(), sc, sess.Credential, r.PathValue("list"), r.PathValue("entry")); err != nil && !errors.Is(err, domain.ErrNotFound) {
		h.appProblem(w, r, err)
		return
	}
	h.appAfter(w, r, sess, sc, "_app_rows")
}

func (h *Web) appRemove(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if err := h.svc.WebRemove(r.Context(), sc, sess.Credential, r.PathValue("list"), r.PathValue("entry")); err != nil && !errors.Is(err, domain.ErrNotFound) {
		h.appProblem(w, r, err)
		return
	}
	h.appAfter(w, r, sess, sc, "_app_rows")
}

func (h *Web) appClear(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if err := h.svc.WebClear(r.Context(), sc, sess.Credential, r.PathValue("list")); err != nil {
		h.appProblem(w, r, err)
		return
	}
	h.appAfter(w, r, sess, sc, "_app_rows")
}

func (h *Web) appProblem(w http.ResponseWriter, r *http.Request, err error) {
	if errors.Is(err, domain.ErrNotFound) {
		http.NotFound(w, r)
		return
	}
	h.fail(w, r, err)
}

var _ = fmt.Sprint
