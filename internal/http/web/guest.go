package web

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

// GuestCookie keeps a guest signed in for a day after the first open, so a
// link forwarded once still works from the browser it was opened in.
const (
	GuestCookie = "doma_guest"
	guestTTL    = 24 * time.Hour
)

type guestData struct {
	// Link is the token in the path, which the page's own forms post to.
	Link       string
	View       *service.GuestView
	AnyChecked bool
}

// guest resolves the link in the path, or the cookie when the path's token
// is "me", and runs fn with the scope.
func (h *Web) guest(fn func(http.ResponseWriter, *http.Request, domain.Scope, string, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.PathValue("token")
		if token == "me" {
			if c, err := r.Cookie(GuestCookie); err == nil {
				token = c.Value
			}
		}
		sc, credentialID, err := h.svc.GuestScope(r.Context(), token)
		if err != nil {
			if errors.Is(err, domain.ErrNotFound) {
				h.render(w, http.StatusNotFound, "gone", page{Title: "Link", Bare: true, Data: map[string]string{"Reason": "Ask the family for a new link."}})
				return
			}
			h.fail(w, r, err)
			return
		}
		http.SetCookie(w, &http.Cookie{ //nolint:gosec // G124: Secure follows server.base_url's scheme
			Name: GuestCookie, Value: token, Path: "/g/", HttpOnly: true, Secure: h.secure, SameSite: http.SameSiteLaxMode, Expires: h.now().Add(guestTTL),
		})
		fn(w, r, sc, credentialID, token)
	}
}

func (h *Web) guestPage(w http.ResponseWriter, r *http.Request, sc domain.Scope, _, token string) {
	view, err := h.svc.GuestView(r.Context(), sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.render(w, http.StatusOK, "guest", page{Title: view.HomeName, Guest: true, Live: true, Alert: view.AnyOut, Data: guestData{Link: token, View: view, AnyChecked: anyChecked(view)}})
}

// guestList is the polled fragment, with an ETag so a quiet list costs a 304.
func (h *Web) guestList(w http.ResponseWriter, r *http.Request, sc domain.Scope, _, token string) {
	h.renderList(w, r, sc, token, http.StatusOK)
}

func (h *Web) renderList(w http.ResponseWriter, r *http.Request, sc domain.Scope, token string, status int) {
	view, err := h.svc.GuestView(r.Context(), sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	data := guestData{Link: token, View: view, AnyChecked: anyChecked(view)}
	body, err := h.renderBytes("_guest_fragment", page{Guest: true, Data: data})
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
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func anyChecked(v *service.GuestView) bool {
	for _, e := range v.Entries {
		if e.Checked {
			return true
		}
	}
	return false
}

// after a change: htmx gets the fragment, a plain form the whole page again
func (h *Web) afterChange(w http.ResponseWriter, r *http.Request, sc domain.Scope, token string) {
	if r.Header.Get("HX-Request") == "true" {
		h.renderList(w, r, sc, token, http.StatusOK)
		return
	}
	http.Redirect(w, r, "/g/"+token, http.StatusSeeOther) //nolint:gosec // G710: the token we just resolved
}

func (h *Web) guestAdd(w http.ResponseWriter, r *http.Request, sc domain.Scope, credentialID, token string) {
	text := strings.TrimSpace(r.PostFormValue("text"))
	if err := h.svc.GuestAdd(r.Context(), sc, credentialID, text); err != nil {
		var ve domain.ErrValidation
		if !errors.As(err, &ve) {
			h.fail(w, r, err)
			return
		}
	}
	h.afterChange(w, r, sc, token)
}

func (h *Web) guestCheck(w http.ResponseWriter, r *http.Request, sc domain.Scope, credentialID, token string) {
	if err := h.svc.GuestToggle(r.Context(), sc, credentialID, r.PathValue("entry")); err != nil && !errors.Is(err, domain.ErrNotFound) {
		h.fail(w, r, err)
		return
	}
	h.afterChange(w, r, sc, token)
}

func (h *Web) guestClear(w http.ResponseWriter, r *http.Request, sc domain.Scope, credentialID, token string) {
	if err := h.svc.GuestClear(r.Context(), sc, credentialID); err != nil {
		h.fail(w, r, err)
		return
	}
	h.afterChange(w, r, sc, token)
}
