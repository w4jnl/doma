// Package sync serves POST /sync/v1, the event exchange, and the snapshot
// download, on the API's signed-caller plumbing.
package sync

import (
	"io"
	"net/http"
	"strconv"

	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/http/api"
	"github.com/w4jnl/doma/internal/ratelimit"
	"github.com/w4jnl/doma/internal/service"
)

// RequestsPerMinute is the per-device limit on sync requests.
const RequestsPerMinute = 120

// Handlers holds the sync routes.
type Handlers struct {
	svc     *service.Service
	limiter *ratelimit.Limiter
}

// New builds the handlers.
func New(svc *service.Service) *Handlers {
	return &Handlers{svc: svc, limiter: ratelimit.New(RequestsPerMinute, RequestsPerMinute/4)}
}

// Mount registers the routes through the API, which checks the signature.
func (h *Handlers) Mount(a *api.API, mux *http.ServeMux) {
	a.Handle(mux, "POST /sync/v1", api.ModeDevice, h.sync)
	a.Handle(mux, "GET /sync/v1/snapshot/{household}/{seq}", api.ModeHousehold, h.snapshot)
}

func (h *Handlers) sync(w http.ResponseWriter, r *http.Request, c *api.Caller) error {
	if ok, wait := h.limiter.Allow(c.Credential.ID); !ok {
		return api.RateLimited(wait)
	}
	var req service.SyncRequest
	if err := api.DecodeJSON(c.Body, &req); err != nil {
		return err
	}
	resp, err := h.svc.Sync(r.Context(), c.Credential.PersonID, c.Credential.ID, req)
	if err != nil {
		return err
	}
	api.WriteJSON(w, http.StatusOK, resp)
	return nil
}

func (h *Handlers) snapshot(w http.ResponseWriter, r *http.Request, c *api.Caller) error {
	seq, err := strconv.ParseInt(r.PathValue("seq"), 10, 64)
	if err != nil {
		return domain.ErrNotFound
	}
	rc, err := h.svc.OpenSnapshot(r.Context(), c.Scope, seq)
	if err != nil {
		return err
	}
	defer func() { _ = rc.Close() }()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Encoding", "gzip")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	_, err = io.Copy(w, rc)
	return err
}
