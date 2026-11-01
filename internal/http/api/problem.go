// Package api serves the REST surface under /api/v1 and the invite accept
// at /i/{token}. Handlers are thin: resolve the caller, call one service
// method, render JSON. Errors are RFC 7807 problem documents.
package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/events"
	"github.com/w4jnl/doma/internal/http/middleware"
)

// Problem is an RFC 7807 document.
type Problem struct {
	Type     string `json:"type"`
	Title    string `json:"title"`
	Status   int    `json:"status"`
	Detail   string `json:"detail,omitempty"`
	Instance string `json:"instance,omitempty"`
	Field    string `json:"field,omitempty"`
}

type errBadRequest struct{ msg string }

func (e errBadRequest) Error() string { return e.msg }

func badRequest(format string, a ...any) error { return errBadRequest{msg: fmt.Sprintf(format, a...)} }

type errRateLimited struct{ wait time.Duration }

func (e errRateLimited) Error() string { return "rate limited" }

// RateLimited is the error a handler returns for a 429 with Retry-After.
func RateLimited(wait time.Duration) error { return errRateLimited{wait: wait} }

// WriteJSON and DecodeJSON are the JSON helpers other route packages use.
func WriteJSON(w http.ResponseWriter, status int, v any) { writeJSON(w, status, v) }

// DecodeJSON parses a body, refusing unknown fields.
func DecodeJSON(body []byte, v any) error { return decodeJSON(body, v) }

// writeError maps an error to a problem response. Anything outside the
// caller's households is a 404, never a 403, so households cannot be
// enumerated.
func writeError(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	p := Problem{Instance: r.URL.Path}
	var br errBadRequest
	var rl errRateLimited
	var ve domain.ErrValidation
	switch {
	case errors.As(err, &br):
		p.Type, p.Title, p.Status, p.Detail = "malformed", "Malformed request", http.StatusBadRequest, br.msg
	case errors.Is(err, domain.ErrUnauthorized), errors.Is(err, auth.ErrBadSignature):
		p.Type, p.Title, p.Status, p.Detail = "unauthorized", "Not signed in", http.StatusUnauthorized, detail(err)
		w.Header().Set("WWW-Authenticate", `Signature realm="doma"`)
	case errors.Is(err, domain.ErrForbidden):
		p.Type, p.Title, p.Status, p.Detail = "forbidden", "Not allowed", http.StatusForbidden, detail(err)
	case errors.Is(err, domain.ErrNotFound):
		p.Type, p.Title, p.Status, p.Detail = "not-found", "Not found", http.StatusNotFound, "nothing here"
	case errors.Is(err, domain.ErrConflict):
		p.Type, p.Title, p.Status, p.Detail = "conflict", "Conflict", http.StatusConflict, detail(err)
	case errors.Is(err, domain.ErrQuota):
		p.Type, p.Title, p.Status, p.Detail = "quota", "Over quota", http.StatusRequestEntityTooLarge, detail(err)
	case errors.As(err, &rl):
		p.Type, p.Title, p.Status, p.Detail = "rate-limit", "Too many requests", http.StatusTooManyRequests, "slow down"
		secs := int(rl.wait.Seconds()) + 1
		w.Header().Set("Retry-After", strconv.Itoa(secs))
	case errors.As(err, &ve):
		p.Type, p.Title, p.Status, p.Detail, p.Field = "validation", "Validation failed", http.StatusUnprocessableEntity, ve.Msg, ve.Field
	case errors.Is(err, events.ErrInvalid):
		p.Type, p.Title, p.Status, p.Detail = "validation", "Validation failed", http.StatusUnprocessableEntity, detail(err)
	default:
		p.Type, p.Title, p.Status = "internal", "Internal error", http.StatusInternalServerError
		p.Detail = "request " + middleware.GetRequestID(r.Context())
		log.Error("api error", "err", err, "path", r.URL.Path, "req_id", middleware.GetRequestID(r.Context()))
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(p.Status)
	_ = json.NewEncoder(w).Encode(p)
}

// detail is the error's text after the sentinel's word, which the title
// already says.
func detail(err error) string {
	msg := err.Error()
	for _, s := range []error{domain.ErrUnauthorized, domain.ErrForbidden, domain.ErrConflict, domain.ErrQuota, auth.ErrBadSignature, events.ErrInvalid} {
		if rest, ok := cutPrefix(msg, s.Error()+": "); ok {
			return rest
		}
	}
	return msg
}

func cutPrefix(s, prefix string) (string, bool) {
	if len(s) >= len(prefix) && s[:len(prefix)] == prefix {
		return s[len(prefix):], true
	}
	return s, false
}

// writeJSON renders v with status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

// maxBody caps request bodies: 2,000 events of a sync fit in it.
const maxBody = 4 << 20

// readBody reads the whole body once, so the signature check and the
// handler see the same bytes.
func readBody(r *http.Request) ([]byte, error) {
	if r.Body == nil {
		return nil, nil
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil {
		return nil, badRequest("reading body: %v", err)
	}
	if len(b) > maxBody {
		return nil, badRequest("body over %d bytes", maxBody)
	}
	return b, nil
}

// decodeJSON parses body into v, refusing unknown fields.
func decodeJSON(body []byte, v any) error {
	dec := json.NewDecoder(bytesReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return badRequest("invalid JSON body: %v", err)
	}
	if dec.More() {
		return badRequest("invalid JSON body: trailing data")
	}
	return nil
}
