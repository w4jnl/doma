package service

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
)

func person(r db.Person) domain.Person {
	return domain.Person{ID: r.ID, DisplayName: r.DisplayName, CreatedAt: r.CreatedAt, LastSeenAt: r.LastSeenAt}
}

func credential(r db.Credential) domain.Credential {
	c := domain.Credential{ID: r.ID, PersonID: r.PersonID, Kind: r.Kind, Label: r.Label, Platform: r.Platform, APNSToken: r.ApnsToken, CreatedAt: r.CreatedAt, LastUsedAt: r.LastUsedAt, RevokedAt: r.RevokedAt, MutedLists: mutedLists(r.MutedLists), NotifyClears: r.NotifyClears != 0}
	if r.PublicKey != nil {
		c.PublicKey = *r.PublicKey
	}
	return c
}

func membership(r db.Membership) domain.Membership {
	return domain.Membership{PersonID: r.PersonID, HouseholdID: r.HouseholdID, Role: domain.Role(r.Role), HomeID: r.HomeID, ListID: r.ListID, ExpiresAt: r.ExpiresAt, CreatedAt: r.CreatedAt}
}

// MembershipInfo is a membership with the household's name, for /me.
type MembershipInfo struct {
	domain.Membership
	HouseholdName string
}

// Me is what a device learns about its person.
type Me struct {
	Person      domain.Person
	Credentials []domain.Credential
	Memberships []MembershipInfo
}

// Me returns the person, their devices and their households with roles.
func (s *Service) Me(ctx context.Context, personID string) (*Me, error) {
	q := s.db.Read()
	p, err := q.GetPerson(ctx, personID)
	if err != nil {
		return nil, notFound(err)
	}
	creds, err := q.CredentialsForPerson(ctx, personID)
	if err != nil {
		return nil, err
	}
	ms, err := q.MembershipsForPerson(ctx, personID)
	if err != nil {
		return nil, err
	}
	me := &Me{Person: person(p)}
	for _, c := range creds {
		if c.RevokedAt == nil {
			me.Credentials = append(me.Credentials, credential(c))
		}
	}
	for _, m := range ms {
		if m.Role == string(domain.RoleGuest) {
			continue
		}
		h, err := q.GetHousehold(ctx, m.HouseholdID)
		if err != nil {
			return nil, err
		}
		me.Memberships = append(me.Memberships, MembershipInfo{Membership: membership(m), HouseholdName: h.Name})
	}
	return me, nil
}

// CredentialForAuth loads a device key for the signature check: unknown is
// ErrNotFound, revoked is ErrUnauthorized.
func (s *Service) CredentialForAuth(ctx context.Context, credentialID string) (*domain.Credential, error) {
	r, err := s.db.Read().GetCredential(ctx, credentialID)
	if err != nil {
		return nil, notFound(err)
	}
	c := credential(r)
	if c.Revoked() || c.Kind != domain.KindDeviceKey {
		return nil, fmt.Errorf("%w: this device was removed", domain.ErrUnauthorized)
	}
	return &c, nil
}

// MembershipFor returns the person's membership in a household, or
// ErrNotFound: a household the person is not in does not exist for them.
func (s *Service) MembershipFor(ctx context.Context, personID, householdID string) (*domain.Membership, error) {
	r, err := s.db.Read().GetMembership(ctx, db.GetMembershipParams{HouseholdID: householdID, PersonID: personID})
	if err != nil {
		return nil, notFound(err)
	}
	m := membership(r)
	if m.ExpiresAt != nil && *m.ExpiresAt < s.nowMs() {
		return nil, domain.ErrNotFound
	}
	return &m, nil
}

// Touch records that a device was just seen. Errors are logged, not
// returned: nothing a caller can do about them.
func (s *Service) Touch(ctx context.Context, credentialID, personID string) {
	now := s.nowMs()
	q := s.db.Write()
	if err := q.TouchCredential(ctx, db.TouchCredentialParams{LastUsedAt: &now, ID: credentialID}); err != nil {
		s.log.Warn("touch credential", "err", err)
	}
	if err := q.TouchPerson(ctx, db.TouchPersonParams{LastSeenAt: &now, ID: personID}); err != nil {
		s.log.Warn("touch person", "err", err)
	}
}

// Members lists the household's members and owners with their names.
func (s *Service) Members(ctx context.Context, sc domain.Scope) ([]domain.Member, error) {
	if err := requireMember(sc); err != nil {
		return nil, err
	}
	rows, err := s.db.Read().MembersOfHousehold(ctx, sc.HouseholdID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.Member, 0, len(rows))
	for _, r := range rows {
		m := domain.Member{Membership: domain.Membership{PersonID: r.PersonID, HouseholdID: r.HouseholdID, Role: domain.Role(r.Role), HomeID: r.HomeID, ListID: r.ListID, ExpiresAt: r.ExpiresAt, CreatedAt: r.CreatedAt}, DisplayName: r.DisplayName, LastSeenAt: r.LastSeenAt}
		out = append(out, m)
	}
	return out, nil
}

// SetRole makes a member an owner or an owner a member; owners only, and
// the last owner cannot be demoted.
func (s *Service) SetRole(ctx context.Context, sc domain.Scope, personID string, role domain.Role) error {
	if err := requireOwner(sc); err != nil {
		return err
	}
	if role != domain.RoleOwner && role != domain.RoleMember {
		return domain.Invalid("role", "use owner or member")
	}
	return s.db.Tx(ctx, func(q *db.Queries) error {
		m, err := q.GetMembership(ctx, db.GetMembershipParams{HouseholdID: sc.HouseholdID, PersonID: personID})
		if err != nil {
			return notFound(err)
		}
		if m.Role == string(domain.RoleGuest) {
			return domain.ErrNotFound
		}
		if m.Role == string(domain.RoleOwner) && role != domain.RoleOwner {
			if err := s.notLastOwner(ctx, q, sc.HouseholdID); err != nil {
				return err
			}
		}
		_, err = q.UpdateMembershipRole(ctx, db.UpdateMembershipRoleParams{Role: string(role), HouseholdID: sc.HouseholdID, PersonID: personID})
		return err
	})
}

func (s *Service) notLastOwner(ctx context.Context, q *db.Queries, householdID string) error {
	n, err := q.CountOwners(ctx, householdID)
	if err != nil {
		return err
	}
	if n <= 1 {
		return fmt.Errorf("%w: the household needs one owner; make someone else an owner first", domain.ErrConflict)
	}
	return nil
}

// RemoveMember takes a person out of the household; owners only, the last
// owner cannot leave. The server appends member.removed so the person's
// devices drop the household.
func (s *Service) RemoveMember(ctx context.Context, sc domain.Scope, personID string) error {
	if err := requireOwner(sc); err != nil {
		return err
	}
	var last int64
	err := s.db.Tx(ctx, func(q *db.Queries) error {
		m, err := q.GetMembership(ctx, db.GetMembershipParams{HouseholdID: sc.HouseholdID, PersonID: personID})
		if err != nil {
			return notFound(err)
		}
		if m.Role == string(domain.RoleOwner) {
			if err := s.notLastOwner(ctx, q, sc.HouseholdID); err != nil {
				return err
			}
		}
		if _, err := q.DeleteMembership(ctx, db.DeleteMembershipParams{HouseholdID: sc.HouseholdID, PersonID: personID}); err != nil {
			return err
		}
		ev := s.systemEvent("member.removed", map[string]any{"person_id": personID})
		seq, err := s.appendEvents(ctx, q, sc.HouseholdID, domain.SystemPerson, []fold.Event{ev})
		last = seq
		return err
	})
	if err != nil {
		return err
	}
	s.changed(sc.HouseholdID, last)
	return nil
}

// RevokeCredential removes a device: a person's own, or any device of a
// person who shares a household the caller owns. The server appends
// device.revoked to every shared household. Anything else is ErrNotFound.
func (s *Service) RevokeCredential(ctx context.Context, callerPersonID, credentialID string) error {
	grown := map[string]int64{}
	err := s.db.Tx(ctx, func(q *db.Queries) error {
		c, err := q.GetCredential(ctx, credentialID)
		if err != nil {
			return notFound(err)
		}
		allowed := c.PersonID == callerPersonID
		theirs, err := q.MembershipsForPerson(ctx, c.PersonID)
		if err != nil {
			return err
		}
		var households []string
		if !allowed {
			mine, err := q.MembershipsForPerson(ctx, callerPersonID)
			if err != nil {
				return err
			}
			owned := map[string]bool{}
			for _, m := range mine {
				if m.Role == string(domain.RoleOwner) {
					owned[m.HouseholdID] = true
				}
			}
			for _, m := range theirs {
				if owned[m.HouseholdID] {
					allowed = true
				}
			}
		}
		if !allowed {
			return domain.ErrNotFound
		}
		if c.RevokedAt != nil {
			return nil
		}
		now := s.nowMs()
		if _, err := q.RevokeCredential(ctx, db.RevokeCredentialParams{RevokedAt: &now, ID: credentialID}); err != nil {
			return err
		}
		for _, m := range theirs {
			households = append(households, m.HouseholdID)
		}
		for _, h := range households {
			ev := s.systemEvent("device.revoked", map[string]any{"credential_id": credentialID})
			seq, err := s.appendEvents(ctx, q, h, domain.SystemPerson, []fold.Event{ev})
			if err != nil {
				return err
			}
			grown[h] = seq
		}
		return nil
	})
	if err != nil {
		return err
	}
	for h, seq := range grown {
		s.changed(h, seq)
	}
	return nil
}

// SetAPNSToken registers or refreshes a device's push token and which of
// Apple's gateways it belongs to (a build from Xcode says sandbox); the
// device's own person only.
func (s *Service) SetAPNSToken(ctx context.Context, personID, credentialID, token string, sandbox bool) error {
	if len(token) == 0 || len(token) > 200 {
		return domain.Invalid("token", "give the device's push token")
	}
	return s.db.Tx(ctx, func(q *db.Queries) error {
		c, err := q.GetCredential(ctx, credentialID)
		if err != nil || c.PersonID != personID {
			return domain.ErrNotFound
		}
		var box int64
		if sandbox {
			box = 1
		}
		return q.SetAPNSToken(ctx, db.SetAPNSTokenParams{ApnsToken: &token, ApnsSandbox: box, ID: credentialID})
	})
}

// mutedLists reads the JSON array a device keeps; anything unreadable mutes nothing.
func mutedLists(raw string) []string {
	var out []string
	if err := json.Unmarshal([]byte(raw), &out); err != nil || out == nil {
		return []string{}
	}
	return out
}

// SetNotifyPrefs keeps what a device wants to hear: the lists it mutes and
// whether a cleared list is worth a word; the device's own person only.
func (s *Service) SetNotifyPrefs(ctx context.Context, personID, credentialID string, muted []string, clears bool) error {
	if len(muted) > 200 {
		return domain.Invalid("muted_lists", "too many lists")
	}
	if muted == nil {
		muted = []string{}
	}
	raw, _ := json.Marshal(muted)
	return s.db.Tx(ctx, func(q *db.Queries) error {
		c, err := q.GetCredential(ctx, credentialID)
		if err != nil || c.PersonID != personID {
			return domain.ErrNotFound
		}
		var yes int64
		if clears {
			yes = 1
		}
		return q.SetNotifyPrefs(ctx, db.SetNotifyPrefsParams{MutedLists: string(raw), NotifyClears: yes, ID: credentialID})
	})
}
