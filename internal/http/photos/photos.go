// Package photos serves the photo upload and download under /photos/v1 on
// the API's signed-caller plumbing.
package photos

import (
	"errors"
	"net/http"

	"github.com/w4jnl/doma/internal/http/api"
	"github.com/w4jnl/doma/internal/photo"
	"github.com/w4jnl/doma/internal/ratelimit"
	"github.com/w4jnl/doma/internal/service"
)

// UploadsPerMinute is the per-device limit on uploads.
const UploadsPerMinute = 10

// Handlers holds the photo routes.
type Handlers struct {
	svc     *service.Service
	limiter *ratelimit.Limiter
}

// New builds the handlers.
func New(svc *service.Service) *Handlers {
	return &Handlers{svc: svc, limiter: ratelimit.New(UploadsPerMinute, UploadsPerMinute)}
}

// Mount registers the routes through the API, which checks the signature.
// The upload takes photos.max_bytes_per_upload; a download opens for a
// member's signed request or a link the server signed.
func (h *Handlers) Mount(a *api.API, mux *http.ServeMux) {
	a.HandleUpload(mux, "POST /photos/v1/{household}/{photo_id}", api.ModeHousehold, h.svc.MaxUploadBytes(), h.upload)
	a.Handle(mux, "GET /photos/v1/{household}/{photo_id}", api.ModeHouseholdOrLink, h.serve(false))
	a.Handle(mux, "GET /photos/v1/{household}/{photo_id}/thumb", api.ModeHouseholdOrLink, h.serve(true))
}

func (h *Handlers) upload(w http.ResponseWriter, r *http.Request, c *api.Caller) error {
	if ok, wait := h.limiter.Allow(c.Credential.ID); !ok {
		return api.RateLimited(wait)
	}
	stored, err := h.svc.StorePhoto(r.Context(), c.Scope, r.PathValue("photo_id"), c.Body)
	if errors.Is(err, photo.ErrNotJPEG) {
		return api.BadRequest("%v", err)
	}
	if err != nil {
		return err
	}
	api.WriteJSON(w, http.StatusOK, stored)
	return nil
}

func (h *Handlers) serve(thumb bool) api.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request, c *api.Caller) error {
		f, err := h.svc.OpenPhoto(r.Context(), c.Scope, r.PathValue("photo_id"), thumb)
		if err != nil {
			return err
		}
		defer func() { _ = f.Close() }()
		st, err := f.Stat()
		if err != nil {
			return err
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "private, max-age=3600")
		http.ServeContent(w, r, "", st.ModTime(), f)
		return nil
	}
}
