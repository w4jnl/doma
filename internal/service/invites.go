package service

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
)

func invite(r db.Invite) domain.Invite {
	return domain.Invite{ID: r.ID, HouseholdID: r.HouseholdID, Role: domain.Role(r.Role), CreatedBy: r.CreatedBy, ExpiresAt: r.ExpiresAt, UsedBy: r.UsedBy, UsedAt: r.UsedAt, RevokedAt: r.RevokedAt}
}

// NewInvite is a fresh invite with the one-time token and the link.
type NewInvite struct {
	Invite domain.Invite
	Token  string
	URL    string
}

// InviteURL is the link the QR encodes.
func (s *Service) InviteURL(token string) string { return s.cfg.BaseURL + "/i/" + token }

// CreateInvite makes a one-use invite for a member or an owner, valid
// invites.default_days. Owners from the app; the admin's bootstrap invite
// carries an owner scope with no person.
func (s *Service) CreateInvite(ctx context.Context, sc domain.Scope, role domain.Role) (*NewInvite, error) {
	if err := requireOwner(sc); err != nil {
		return nil, err
	}
	if role != domain.RoleOwner && role != domain.RoleMember {
		return nil, domain.Invalid("role", "use owner or member")
	}
	token, err := auth.NewToken()
	if err != nil {
		return nil, err
	}
	inv := domain.Invite{ID: domain.NewID(), HouseholdID: sc.HouseholdID, Role: role, ExpiresAt: domain.Millis(s.now().Add(time.Duration(s.cfg.InviteDays) * 24 * time.Hour))}
	if sc.PersonID != "" {
		inv.CreatedBy = &sc.PersonID
	}
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		if _, err := q.GetHousehold(ctx, sc.HouseholdID); err != nil {
			return notFound(err)
		}
		return q.InsertInvite(ctx, db.InsertInviteParams{ID: inv.ID, HouseholdID: inv.HouseholdID, Role: string(inv.Role), TokenHash: auth.HashToken(token), CreatedBy: inv.CreatedBy, ExpiresAt: inv.ExpiresAt})
	})
	if err != nil {
		return nil, err
	}
	return &NewInvite{Invite: inv, Token: token, URL: s.InviteURL(token)}, nil
}

// Invites lists the household's pending invites; owners only.
func (s *Service) Invites(ctx context.Context, sc domain.Scope) ([]domain.Invite, error) {
	if err := requireOwner(sc); err != nil {
		return nil, err
	}
	rows, err := s.db.Read().InvitesForHousehold(ctx, db.InvitesForHouseholdParams{HouseholdID: sc.HouseholdID, ExpiresAt: s.nowMs()})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Invite, 0, len(rows))
	for _, r := range rows {
		out = append(out, invite(r))
	}
	return out, nil
}

// RevokeInvite cancels a pending invite; owners only.
func (s *Service) RevokeInvite(ctx context.Context, sc domain.Scope, id string) error {
	if err := requireOwner(sc); err != nil {
		return err
	}
	now := s.nowMs()
	n, err := s.db.Write().RevokeInvite(ctx, db.RevokeInviteParams{RevokedAt: &now, HouseholdID: sc.HouseholdID, ID: id})
	if err != nil {
		return err
	}
	if n == 0 {
		return domain.ErrNotFound
	}
	return nil
}

// InvitePreview is what the invite page shows before the app opens.
type InvitePreview struct {
	Household domain.Household
	Role      domain.Role
	ExpiresAt int64
}

// inviteByToken loads a usable invite: unknown, expired or revoked is
// ErrNotFound, used is ErrConflict.
func (s *Service) inviteByToken(ctx context.Context, q *db.Queries, token string) (*db.Invite, error) {
	if len(token) < 20 || len(token) > 64 {
		return nil, domain.ErrNotFound
	}
	r, err := q.GetInviteByHash(ctx, auth.HashToken(token))
	if err != nil {
		return nil, notFound(err)
	}
	switch {
	case r.UsedAt != nil:
		return nil, fmt.Errorf("%w: that invite was used already", domain.ErrConflict)
	case r.RevokedAt != nil, r.ExpiresAt <= s.nowMs():
		return nil, domain.ErrNotFound
	}
	return &r, nil
}

// InviteByToken previews an invite.
func (s *Service) InviteByToken(ctx context.Context, token string) (*InvitePreview, error) {
	q := s.db.Read()
	r, err := s.inviteByToken(ctx, q, token)
	if err != nil {
		return nil, err
	}
	h, err := q.GetHousehold(ctx, r.HouseholdID)
	if err != nil {
		return nil, notFound(err)
	}
	return &InvitePreview{Household: household(h), Role: domain.Role(r.Role), ExpiresAt: r.ExpiresAt}, nil
}

// AcceptInvite is what the app sends after scanning.
type AcceptInvite struct {
	PublicKey   string
	Platform    string
	Label       string
	DisplayName string
}

// Accepted is what the app keeps.
type Accepted struct {
	Server       string
	PersonID     string
	CredentialID string
	Household    domain.Household
	Role         domain.Role
	// Rejoined is set when the key already belonged to the household and no
	// invite was used; it is logged, not returned.
	Rejoined bool
}

// AcceptInvite registers the device, creates the person when the key is
// new to this server, and adds the membership. The invite is spent.
func (s *Service) AcceptInvite(ctx context.Context, token string, req AcceptInvite) (*Accepted, error) {
	key, err := auth.ParsePublicKey(req.PublicKey)
	if err != nil {
		return nil, domain.Invalid("public_key", "%v", err)
	}
	name := strings.TrimSpace(req.DisplayName)
	if name == "" || len(name) > 64 {
		return nil, domain.Invalid("display_name", "give a name of up to 64 characters")
	}
	label := strings.TrimSpace(req.Label)
	if len(label) > 64 {
		return nil, domain.Invalid("label", "use at most 64 characters")
	}
	platform := strings.TrimSpace(req.Platform)
	if len(platform) > 32 {
		return nil, domain.Invalid("platform", "use at most 32 characters")
	}
	var out *Accepted
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		inv, err := s.inviteByToken(ctx, q, token)
		if err != nil {
			return err
		}
		h, err := q.GetHousehold(ctx, inv.HouseholdID)
		if err != nil {
			return notFound(err)
		}
		now := s.nowMs()
		var personID, credentialID string
		if existing, err := q.GetCredentialByPublicKey(ctx, ptr(key.String())); err == nil {
			personID, credentialID = existing.PersonID, existing.ID
			if err := q.UpdatePersonName(ctx, db.UpdatePersonNameParams{DisplayName: name, ID: personID}); err != nil {
				return err
			}
		} else {
			personID, credentialID = domain.NewID(), domain.NewID()
			if err := q.InsertPerson(ctx, db.InsertPersonParams{ID: personID, DisplayName: name, CreatedAt: now}); err != nil {
				return err
			}
			if err := q.InsertCredential(ctx, db.InsertCredentialParams{ID: credentialID, PersonID: personID, Kind: domain.KindDeviceKey, PublicKey: ptr(key.String()), Label: label, Platform: platform, CreatedAt: now}); err != nil {
				return err
			}
		}
		if m, err := q.GetMembership(ctx, db.GetMembershipParams{HouseholdID: inv.HouseholdID, PersonID: personID}); err == nil {
			// a device that already belongs here (the app was reinstalled and
			// the key outlived the store) gets its membership back and the
			// invite stays unused; its role is the one it has, not the invite's
			out = &Accepted{Server: s.cfg.BaseURL, PersonID: personID, CredentialID: credentialID, Household: household(h), Role: domain.Role(m.Role), Rejoined: true}
			return nil
		}
		if err := q.InsertMembership(ctx, db.InsertMembershipParams{PersonID: personID, HouseholdID: inv.HouseholdID, Role: inv.Role, CreatedAt: now}); err != nil {
			return err
		}
		n, err := q.UseInvite(ctx, db.UseInviteParams{UsedBy: &personID, UsedAt: &now, HouseholdID: inv.HouseholdID, ID: inv.ID})
		if err != nil {
			return err
		}
		if n == 0 {
			return fmt.Errorf("%w: that invite was used already", domain.ErrConflict)
		}
		out = &Accepted{Server: s.cfg.BaseURL, PersonID: personID, CredentialID: credentialID, Household: household(h), Role: domain.Role(inv.Role)}
		return nil
	})
	if err != nil {
		return nil, err
	}
	s.log.Info("invite accepted", "household", out.Household.ID, "person", out.PersonID, "role", out.Role, "rejoined", out.Rejoined)
	return out, nil
}

func ptr[T any](v T) *T { return &v }
