package api

import (
	"errors"
	"net/http"

	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/http/middleware"
	"github.com/w4jnl/doma/internal/service"
)

// Wire shapes. Times are Unix milliseconds UTC.

type personDTO struct {
	ID          string `json:"id"`
	DisplayName string `json:"display_name"`
	LastSeenAt  *int64 `json:"last_seen_at,omitempty"`
}

type credentialDTO struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	Label      string `json:"label"`
	Platform   string `json:"platform"`
	CreatedAt  int64  `json:"created_at"`
	LastUsedAt *int64 `json:"last_used_at,omitempty"`
	HasPush    bool   `json:"has_push"`
}

type membershipDTO struct {
	HouseholdID   string `json:"household_id"`
	HouseholdName string `json:"household_name"`
	Role          string `json:"role"`
}

type householdDTO struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Timezone      string `json:"timezone"`
	StalenessDays int    `json:"staleness_days"`
}

type memberDTO struct {
	PersonID    string `json:"person_id"`
	DisplayName string `json:"display_name"`
	Role        string `json:"role"`
	JoinedAt    int64  `json:"joined_at"`
	LastSeenAt  *int64 `json:"last_seen_at,omitempty"`
}

type inviteDTO struct {
	ID        string  `json:"id"`
	Role      string  `json:"role"`
	ExpiresAt int64   `json:"expires_at"`
	CreatedBy *string `json:"created_by,omitempty"`
	// URL and QR are present on the one response that creates the invite.
	URL string `json:"url,omitempty"`
}

func (a *API) householdDTO(h *domain.Household) householdDTO {
	return householdDTO{ID: h.ID, Name: h.Name, Timezone: h.Timezone, StalenessDays: a.svc.StalenessDays(h)}
}

// acceptInvite: POST /i/{token}. Failed lookups are rate limited per address.
func (a *API) acceptInvite(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		PublicKey   string `json:"public_key"`
		Platform    string `json:"platform"`
		Label       string `json:"label"`
		DisplayName string `json:"display_name"`
	}
	if err := decodeJSON(c.Body, &req); err != nil {
		return err
	}
	ip := middleware.ClientIP(r)
	if ok, wait := a.perIP.Allow(ip); !ok {
		return errRateLimited{wait: wait}
	}
	acc, err := a.svc.AcceptInvite(r.Context(), r.PathValue("token"), service.AcceptInvite(req))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"server": acc.Server, "person_id": acc.PersonID, "credential_id": acc.CredentialID,
		"household": a.householdDTO(&acc.Household), "role": acc.Role,
	})
	return nil
}

// me: GET /api/v1/me.
func (a *API) me(w http.ResponseWriter, r *http.Request, c *Caller) error {
	me, err := a.svc.Me(r.Context(), c.Credential.PersonID)
	if err != nil {
		return err
	}
	out := struct {
		Person      personDTO       `json:"person"`
		Credentials []credentialDTO `json:"credentials"`
		Memberships []membershipDTO `json:"memberships"`
	}{Person: personDTO{ID: me.Person.ID, DisplayName: me.Person.DisplayName, LastSeenAt: me.Person.LastSeenAt}, Credentials: []credentialDTO{}, Memberships: []membershipDTO{}}
	for _, cr := range me.Credentials {
		out.Credentials = append(out.Credentials, credentialDTO{ID: cr.ID, Kind: cr.Kind, Label: cr.Label, Platform: cr.Platform, CreatedAt: cr.CreatedAt, LastUsedAt: cr.LastUsedAt, HasPush: cr.APNSToken != nil})
	}
	for _, m := range me.Memberships {
		out.Memberships = append(out.Memberships, membershipDTO{HouseholdID: m.HouseholdID, HouseholdName: m.HouseholdName, Role: string(m.Role)})
	}
	writeJSON(w, http.StatusOK, out)
	return nil
}

// revokeCredential: DELETE /api/v1/credentials/{id}.
func (a *API) revokeCredential(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if err := a.svc.RevokeCredential(r.Context(), c.Credential.PersonID, r.PathValue("id")); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// registerAPNS: POST /api/v1/devices/{credential}/apns.
func (a *API) registerAPNS(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Token string `json:"token"`
	}
	if err := decodeJSON(c.Body, &req); err != nil {
		return err
	}
	if err := a.svc.SetAPNSToken(r.Context(), c.Credential.PersonID, r.PathValue("credential"), req.Token); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// updateHousehold: PUT /api/v1/h/{household}.
func (a *API) updateHousehold(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Name          string `json:"name"`
		Timezone      string `json:"timezone"`
		StalenessDays *int64 `json:"staleness_days"`
	}
	if err := decodeJSON(c.Body, &req); err != nil {
		return err
	}
	h, err := a.svc.UpdateHousehold(r.Context(), c.Scope, service.HouseholdUpdate{Name: req.Name, Timezone: req.Timezone, StalenessDays: req.StalenessDays})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, a.householdDTO(h))
	return nil
}

// members: GET /api/v1/h/{household}/members.
func (a *API) members(w http.ResponseWriter, r *http.Request, c *Caller) error {
	ms, err := a.svc.Members(r.Context(), c.Scope)
	if err != nil {
		return err
	}
	out := make([]memberDTO, 0, len(ms))
	for _, m := range ms {
		out = append(out, memberDTO{PersonID: m.PersonID, DisplayName: m.DisplayName, Role: string(m.Role), JoinedAt: m.CreatedAt, LastSeenAt: m.LastSeenAt})
	}
	writeJSON(w, http.StatusOK, map[string]any{"members": out})
	return nil
}

// removeMember: DELETE /api/v1/h/{household}/members/{person}.
func (a *API) removeMember(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if err := a.svc.RemoveMember(r.Context(), c.Scope, r.PathValue("person")); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// setRole: PUT /api/v1/h/{household}/members/{person}/role.
func (a *API) setRole(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Role string `json:"role"`
	}
	if err := decodeJSON(c.Body, &req); err != nil {
		return err
	}
	if err := a.svc.SetRole(r.Context(), c.Scope, r.PathValue("person"), domain.Role(req.Role)); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// invites: GET /api/v1/h/{household}/invites.
func (a *API) invites(w http.ResponseWriter, r *http.Request, c *Caller) error {
	invs, err := a.svc.Invites(r.Context(), c.Scope)
	if err != nil {
		return err
	}
	out := make([]inviteDTO, 0, len(invs))
	for _, i := range invs {
		out = append(out, inviteDTO{ID: i.ID, Role: string(i.Role), ExpiresAt: i.ExpiresAt, CreatedBy: i.CreatedBy})
	}
	writeJSON(w, http.StatusOK, map[string]any{"invites": out})
	return nil
}

// createInvite: POST /api/v1/h/{household}/invites.
func (a *API) createInvite(w http.ResponseWriter, r *http.Request, c *Caller) error {
	var req struct {
		Role string `json:"role"`
	}
	if err := decodeJSON(c.Body, &req); err != nil {
		return err
	}
	inv, err := a.svc.CreateInvite(r.Context(), c.Scope, domain.Role(req.Role))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, inviteDTO{ID: inv.Invite.ID, Role: string(inv.Invite.Role), ExpiresAt: inv.Invite.ExpiresAt, CreatedBy: inv.Invite.CreatedBy, URL: inv.URL})
	return nil
}

// export: GET /api/v1/h/{household}/export, a zip.
func (a *API) export(w http.ResponseWriter, r *http.Request, c *Caller) error {
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="doma-export.zip"`)
	w.Header().Set("Cache-Control", "no-store")
	return a.svc.Export(r.Context(), c.Scope, w)
}

// revokeInvite: DELETE /api/v1/h/{household}/invites/{id}.
func (a *API) revokeInvite(w http.ResponseWriter, r *http.Request, c *Caller) error {
	if err := a.svc.RevokeInvite(r.Context(), c.Scope, r.PathValue("id")); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

var _ = errors.New
