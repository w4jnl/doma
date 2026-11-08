// Package cards serves what the server keeps for the family's loyalty
// cards: the shop logo it fetched, under /cards/v1, on the API's
// signed-caller plumbing. The cards themselves travel as events.
package cards

import (
	"net/http"

	"github.com/w4jnl/doma/internal/http/api"
	"github.com/w4jnl/doma/internal/service"
)

// Handlers holds the card routes.
type Handlers struct {
	svc *service.Service
}

// New builds the handlers.
func New(svc *service.Service) *Handlers { return &Handlers{svc: svc} }

// Mount registers the routes through the API, which checks the signature.
// A logo opens for a member's signed request or a link the server signed.
func (h *Handlers) Mount(a *api.API, mux *http.ServeMux) {
	a.Handle(mux, "GET /cards/v1/{household}/{card_id}/logo/{logo_id}", api.ModeHouseholdOrLink, h.logo)
}

func (h *Handlers) logo(w http.ResponseWriter, r *http.Request, c *api.Caller) error {
	f, err := h.svc.OpenCardLogo(r.Context(), c.Scope, r.PathValue("card_id"), r.PathValue("logo_id"))
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	http.ServeContent(w, r, "", st.ModTime(), f)
	return nil
}
