package api

import (
	"bytes"
	"context"
	_ "embed"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/http/middleware"
	"github.com/w4jnl/doma/internal/ratelimit"
	"github.com/w4jnl/doma/internal/service"
)

// Prefix is where the API lives.
const Prefix = "/api/v1"

// Limits from the design document.
const (
	// RequestsPerMinute is the per-device limit on the REST routes.
	RequestsPerMinute = 300
	// InviteLookupsPerMinute is the per-address limit on failed invite
	// lookups.
	InviteLookupsPerMinute = 10
)

// openAPI is the hand-maintained specification served at
// /api/v1/openapi.yaml; openapi_test.go checks its paths against the router.
//
//go:embed openapi.yaml
var openAPI []byte

func bytesReader(b []byte) io.Reader { return bytes.NewReader(b) }

// Caller is who a request is from, resolved once per request.
type Caller struct {
	Credential *domain.Credential
	// Scope is set on household routes.
	Scope domain.Scope
	// Body is the request body, read once for the signature.
	Body []byte
}

type ctxKey int

const keyCaller ctxKey = iota

// CallerFrom returns the request's caller.
func CallerFrom(ctx context.Context) *Caller {
	c, _ := ctx.Value(keyCaller).(*Caller)
	return c
}

// API holds the dependencies of every handler.
type API struct {
	svc    *service.Service
	log    *slog.Logger
	nonces *auth.Nonces
	perDev *ratelimit.Limiter
	perIP  *ratelimit.Limiter
	now    func() time.Time
	Routes []string
}

// New builds the API.
func New(svc *service.Service, log *slog.Logger) *API {
	return &API{
		svc: svc, log: log, nonces: auth.NewNonces(),
		perDev: ratelimit.New(RequestsPerMinute, RequestsPerMinute/5),
		perIP:  ratelimit.New(InviteLookupsPerMinute, InviteLookupsPerMinute),
		now:    func() time.Time { return time.Now().UTC() },
	}
}

// SetClock replaces the clock, for tests.
func (a *API) SetClock(now func() time.Time) { a.now = now }

// HandlerFunc is a handler that returns an error for the problem writer.
type HandlerFunc func(w http.ResponseWriter, r *http.Request, c *Caller) error

// Mode says how a route resolves its caller.
type Mode int

const (
	// ModePublic takes no signature.
	ModePublic Mode = iota
	// ModeDevice takes a signed request from any person.
	ModeDevice
	// ModeHousehold takes a signed request from a member of {household}.
	ModeHousehold
	// ModeHouseholdOrLink takes a signed request from a member of
	// {household}, or a link the server signed (exp and sig in the query)
	// that opens the path as a member for an hour.
	ModeHouseholdOrLink
)

const (
	modePublic    = ModePublic
	modeDevice    = ModeDevice
	modeHousehold = ModeHousehold
)

// Mount registers every route.
func (a *API) Mount(mux *http.ServeMux) {
	a.handle(mux, "POST /i/{token}", modePublic, a.acceptInvite)
	a.handle(mux, "GET "+Prefix+"/openapi.yaml", modePublic, func(w http.ResponseWriter, _ *http.Request, _ *Caller) error {
		w.Header().Set("Content-Type", "application/yaml")
		_, err := w.Write(openAPI)
		return err
	})
	a.handle(mux, "GET "+Prefix+"/me", modeDevice, a.me)
	a.handle(mux, "POST "+Prefix+"/vouch", modeDevice, a.vouch)
	a.handle(mux, "DELETE "+Prefix+"/credentials/{id}", modeDevice, a.revokeCredential)
	a.handle(mux, "POST "+Prefix+"/devices/{credential}/apns", modeDevice, a.registerAPNS)
	a.handle(mux, "PUT "+Prefix+"/devices/{credential}/notify", modeDevice, a.setNotify)
	a.handle(mux, "PUT "+Prefix+"/h/{household}", modeHousehold, a.updateHousehold)
	a.handle(mux, "GET "+Prefix+"/h/{household}/members", modeHousehold, a.members)
	a.handle(mux, "DELETE "+Prefix+"/h/{household}/members/{person}", modeHousehold, a.removeMember)
	a.handle(mux, "PUT "+Prefix+"/h/{household}/members/{person}/role", modeHousehold, a.setRole)
	a.handle(mux, "GET "+Prefix+"/h/{household}/invites", modeHousehold, a.invites)
	a.handle(mux, "POST "+Prefix+"/h/{household}/invites", modeHousehold, a.createInvite)
	a.handle(mux, "DELETE "+Prefix+"/h/{household}/invites/{id}", modeHousehold, a.revokeInvite)
	a.handle(mux, "GET "+Prefix+"/h/{household}/export", modeHousehold, a.export)
	a.handle(mux, "GET "+Prefix+"/h/{household}/guests", modeHousehold, a.guests)
	a.handle(mux, "POST "+Prefix+"/h/{household}/guests", modeHousehold, a.createGuest)
	a.handle(mux, "DELETE "+Prefix+"/h/{household}/guests/{id}", modeHousehold, a.revokeGuest)
}

// Handle registers a route from another package on the same plumbing.
func (a *API) Handle(mux *http.ServeMux, pattern string, m Mode, fn HandlerFunc) {
	a.handle(mux, pattern, m, fn)
}

// HandleUpload registers a route whose body may be maxBytes long; a longer
// one is refused as over quota before it is read.
func (a *API) HandleUpload(mux *http.ServeMux, pattern string, m Mode, maxBytes int64, fn HandlerFunc) {
	a.handleWith(mux, pattern, m, maxBytes, fn)
}

func (a *API) handle(mux *http.ServeMux, pattern string, m Mode, fn HandlerFunc) {
	a.handleWith(mux, pattern, m, 0, fn)
}

func (a *API) handleWith(mux *http.ServeMux, pattern string, m Mode, maxBytes int64, fn HandlerFunc) {
	a.Routes = append(a.Routes, pattern)
	mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		c, err := a.caller(r, m, maxBytes)
		if err != nil {
			writeError(w, r, a.log, err)
			return
		}
		r = r.WithContext(context.WithValue(r.Context(), keyCaller, c))
		if err := fn(w, r, c); err != nil {
			writeError(w, r, a.log, err)
		}
	})
}

// caller reads the body, checks the signature and, on household routes,
// the membership. The signature is checked before the rate limit is
// consulted, so a stranger cannot spend a device's budget.
func (a *API) caller(r *http.Request, m Mode, maxBytes int64) (*Caller, error) {
	body, err := readBody(r, maxBytes)
	if err != nil {
		return nil, err
	}
	c := &Caller{Body: body}
	if m == modePublic {
		return c, nil
	}
	if m == ModeHouseholdOrLink && r.Header.Get(auth.HeaderCredential) == "" {
		if !a.svc.CheckLink(r.URL.Path, r.URL.Query()) {
			return nil, auth.ErrBadSignature
		}
		hh := r.PathValue("household")
		c.Scope = domain.Scope{HouseholdID: hh, Role: domain.RoleMember}
		middleware.AddLogFields(r.Context(), slog.String("household", hh))
		return c, nil
	}
	signed, err := auth.ReadSignature(r)
	if err != nil {
		return nil, err
	}
	cred, err := a.svc.CredentialForAuth(r.Context(), signed.CredentialID)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			return nil, auth.ErrBadSignature
		}
		return nil, err
	}
	key, err := auth.ParsePublicKey(cred.PublicKey)
	if err != nil {
		return nil, err
	}
	if err := signed.Check(key, a.nonces, r.Method, r.URL.Path, body, a.now()); err != nil {
		return nil, err
	}
	if ok, wait := a.perDev.Allow(cred.ID); !ok {
		return nil, errRateLimited{wait: wait}
	}
	c.Credential = cred
	middleware.AddLogFields(r.Context(), slog.String("person", cred.PersonID))
	if m == modeHousehold || m == ModeHouseholdOrLink {
		hh := r.PathValue("household")
		ms, err := a.svc.MembershipFor(r.Context(), cred.PersonID, hh)
		if err != nil {
			return nil, err
		}
		c.Scope = domain.Scope{HouseholdID: hh, PersonID: cred.PersonID, Role: ms.Role}
		if ms.HomeID != nil {
			c.Scope.HomeID = *ms.HomeID
		}
		if ms.ListID != nil {
			c.Scope.ListID = *ms.ListID
		}
		middleware.AddLogFields(r.Context(), slog.String("household", hh))
	}
	a.svc.Touch(r.Context(), cred.ID, cred.PersonID)
	return c, nil
}
