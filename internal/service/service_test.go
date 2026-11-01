package service_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

func newService(t *testing.T) *service.Service {
	t.Helper()
	auth.FastParamsForTests()
	d := dbtest.Open(t)
	return service.New(d, service.Config{BaseURL: "https://doma.test", InviteDays: 7}, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func TestSetupOnce(t *testing.T) {
	s := newService(t)
	ctx := context.Background()
	if ok, _ := s.AdminExists(ctx); ok {
		t.Fatal("admin before setup")
	}
	if err := s.Setup(ctx, "j", "short"); !errors.As(err, new(domain.ErrValidation)) {
		t.Errorf("short password: %v", err)
	}
	if err := s.Setup(ctx, "j", "long enough password"); err != nil {
		t.Fatal(err)
	}
	if err := s.Setup(ctx, "k", "long enough password"); !errors.Is(err, domain.ErrConflict) {
		t.Errorf("second setup: %v", err)
	}
	if err := s.VerifyAdmin(ctx, "j", "long enough password"); err != nil {
		t.Errorf("login: %v", err)
	}
	if err := s.VerifyAdmin(ctx, "j", "wrong"); !errors.Is(err, domain.ErrUnauthorized) {
		t.Errorf("wrong password: %v", err)
	}
	if err := s.VerifyAdmin(ctx, "nobody", "long enough password"); !errors.Is(err, domain.ErrUnauthorized) {
		t.Errorf("wrong login: %v", err)
	}
}

func TestCreateHouseholdMakesListAndHome(t *testing.T) {
	s := newService(t)
	ctx := context.Background()
	h, err := s.CreateHousehold(ctx, "De Vries", "Europe/Amsterdam", "Gouda")
	if err != nil {
		t.Fatal(err)
	}
	if h.Slug != "de-vries" {
		t.Errorf("slug %q", h.Slug)
	}
	h2, err := s.CreateHousehold(ctx, "De Vries", "Europe/Amsterdam", "Hut")
	if err != nil || h2.Slug != "de-vries-2" {
		t.Errorf("second slug %q %v", h2.Slug, err)
	}
	if _, err := s.CreateHousehold(ctx, "X", "Mars/Olympus", "Gouda"); !errors.As(err, new(domain.ErrValidation)) {
		t.Errorf("bad timezone: %v", err)
	}
	var lists, homes, events int
	d := s.DB()
	_ = d.Reader.QueryRowContext(ctx, "SELECT COUNT(*) FROM lists WHERE household_id = ? AND is_default = 1", h.ID).Scan(&lists)
	_ = d.Reader.QueryRowContext(ctx, "SELECT COUNT(*) FROM homes WHERE household_id = ? AND name = 'Gouda'", h.ID).Scan(&homes)
	_ = d.Reader.QueryRowContext(ctx, "SELECT COUNT(*) FROM events WHERE household_id = ?", h.ID).Scan(&events)
	if lists != 1 || homes != 1 || events != 2 {
		t.Errorf("lists %d homes %d events %d", lists, homes, events)
	}
	got, err := s.HouseholdByID(ctx, h.ID)
	if err != nil || got.Name != "De Vries" {
		t.Errorf("HouseholdByID: %+v %v", got, err)
	}
	if _, err := s.HouseholdByID(ctx, "nope"); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("missing household: %v", err)
	}
	if err := s.DeleteHousehold(ctx, h2.ID); err != nil {
		t.Errorf("delete empty household: %v", err)
	}
}

func accept(t *testing.T, s *service.Service, token, name string) (*service.Accepted, auth.Signer) {
	t.Helper()
	signer, err := auth.NewEd25519Signer()
	if err != nil {
		t.Fatal(err)
	}
	acc, err := s.AcceptInvite(context.Background(), token, service.AcceptInvite{PublicKey: signer.Public(), Platform: "ios", Label: name + "'s iPhone", DisplayName: name})
	if err != nil {
		t.Fatalf("accept for %s: %v", name, err)
	}
	return acc, signer
}

func TestInvitesAndMembers(t *testing.T) {
	s := newService(t)
	ctx := context.Background()
	h, err := s.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	if err != nil {
		t.Fatal(err)
	}
	adminScope := domain.Scope{HouseholdID: h.ID, Role: domain.RoleOwner}
	inv, err := s.CreateInvite(ctx, adminScope, domain.RoleOwner)
	if err != nil {
		t.Fatal(err)
	}
	if inv.URL != "https://doma.test/i/"+inv.Token {
		t.Errorf("url %q", inv.URL)
	}
	if _, err := s.InviteByToken(ctx, inv.Token); err != nil {
		t.Errorf("preview: %v", err)
	}
	owner, _ := accept(t, s, inv.Token, "Jaro")
	if owner.Role != domain.RoleOwner || owner.Household.ID != h.ID || owner.Server != "https://doma.test" {
		t.Errorf("accepted: %+v", owner)
	}
	if _, err := s.AcceptInvite(ctx, inv.Token, service.AcceptInvite{PublicKey: "ed25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", DisplayName: "Again"}); !errors.Is(err, domain.ErrConflict) {
		t.Errorf("second use: %v", err)
	}
	if _, err := s.InviteByToken(ctx, "nope-nope-nope-nope-nope"); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("unknown token: %v", err)
	}
	ownerScope := domain.Scope{HouseholdID: h.ID, PersonID: owner.PersonID, Role: domain.RoleOwner}
	inv2, err := s.CreateInvite(ctx, ownerScope, domain.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	pending, _ := s.Invites(ctx, ownerScope)
	if len(pending) != 1 || pending[0].ID != inv2.Invite.ID || *pending[0].CreatedBy != owner.PersonID {
		t.Errorf("pending %+v", pending)
	}
	member, _ := accept(t, s, inv2.Token, "Sam")
	memberScope := domain.Scope{HouseholdID: h.ID, PersonID: member.PersonID, Role: domain.RoleMember}
	if _, err := s.CreateInvite(ctx, memberScope, domain.RoleMember); !errors.Is(err, domain.ErrForbidden) {
		t.Errorf("member inviting: %v", err)
	}
	members, err := s.Members(ctx, memberScope)
	if err != nil || len(members) != 2 {
		t.Fatalf("members %v %v", members, err)
	}
	if err := s.SetRole(ctx, ownerScope, owner.PersonID, domain.RoleMember); !errors.Is(err, domain.ErrConflict) {
		t.Errorf("demoting the last owner: %v", err)
	}
	if err := s.RemoveMember(ctx, ownerScope, owner.PersonID); !errors.Is(err, domain.ErrConflict) {
		t.Errorf("removing the last owner: %v", err)
	}
	if err := s.SetRole(ctx, ownerScope, member.PersonID, domain.RoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := s.SetRole(ctx, ownerScope, owner.PersonID, domain.RoleMember); err != nil {
		t.Errorf("demoting with two owners: %v", err)
	}
	me, err := s.Me(ctx, member.PersonID)
	if err != nil || len(me.Memberships) != 1 || me.Memberships[0].Role != domain.RoleOwner || me.Memberships[0].HouseholdName != "Family" || len(me.Credentials) != 1 {
		t.Errorf("me %+v %v", me, err)
	}
	// the new owner removes the old one; a member.removed event lands in the log
	newOwnerScope := domain.Scope{HouseholdID: h.ID, PersonID: member.PersonID, Role: domain.RoleOwner}
	if err := s.RemoveMember(ctx, newOwnerScope, owner.PersonID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.MembershipFor(ctx, owner.PersonID, h.ID); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("removed member still has a membership: %v", err)
	}
	var kinds []string
	rows, _ := s.DB().Reader.QueryContext(ctx, "SELECT kind FROM events WHERE household_id = ? ORDER BY seq", h.ID)
	for rows.Next() {
		var k string
		_ = rows.Scan(&k)
		kinds = append(kinds, k)
	}
	_ = rows.Close()
	if len(kinds) != 3 || kinds[2] != "member.removed" {
		t.Errorf("events %v", kinds)
	}
	if err := s.DeleteHousehold(ctx, h.ID); !errors.Is(err, domain.ErrConflict) {
		t.Errorf("delete with members: %v", err)
	}
}

func TestDevices(t *testing.T) {
	s := newService(t)
	ctx := context.Background()
	h, _ := s.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	adminScope := domain.Scope{HouseholdID: h.ID, Role: domain.RoleOwner}
	inv, _ := s.CreateInvite(ctx, adminScope, domain.RoleOwner)
	owner, _ := accept(t, s, inv.Token, "Jaro")
	inv2, _ := s.CreateInvite(ctx, domain.Scope{HouseholdID: h.ID, PersonID: owner.PersonID, Role: domain.RoleOwner}, domain.RoleMember)
	member, _ := accept(t, s, inv2.Token, "Sam")
	other, _ := s.CreateHousehold(ctx, "Others", "Europe/Amsterdam", "Elsewhere")
	inv3, _ := s.CreateInvite(ctx, domain.Scope{HouseholdID: other.ID, Role: domain.RoleOwner}, domain.RoleOwner)
	stranger, _ := accept(t, s, inv3.Token, "Alex")

	if err := s.SetAPNSToken(ctx, member.PersonID, member.CredentialID, "tok"); err != nil {
		t.Errorf("own apns: %v", err)
	}
	if err := s.SetAPNSToken(ctx, owner.PersonID, member.CredentialID, "tok"); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("someone else's apns: %v", err)
	}
	if err := s.RevokeCredential(ctx, stranger.PersonID, member.CredentialID); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("stranger revoking: %v", err)
	}
	if err := s.RevokeCredential(ctx, member.PersonID, owner.CredentialID); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("member revoking the owner's device: %v", err)
	}
	if err := s.RevokeCredential(ctx, owner.PersonID, member.CredentialID); err != nil {
		t.Errorf("owner revoking a member's device: %v", err)
	}
	if _, err := s.CredentialForAuth(ctx, member.CredentialID); !errors.Is(err, domain.ErrUnauthorized) {
		t.Errorf("revoked device authenticates: %v", err)
	}
	if err := s.RevokeCredential(ctx, owner.PersonID, owner.CredentialID); err != nil {
		t.Errorf("own device: %v", err)
	}
	var n int
	_ = s.DB().Reader.QueryRowContext(ctx, "SELECT COUNT(*) FROM events WHERE household_id = ? AND kind = 'device.revoked'", h.ID).Scan(&n)
	if n != 2 {
		t.Errorf("device.revoked events: %d", n)
	}
	s.Touch(ctx, stranger.CredentialID, stranger.PersonID)
	me, _ := s.Me(ctx, stranger.PersonID)
	if me.Person.LastSeenAt == nil {
		t.Error("Touch did not set last_seen_at")
	}
	s.SetClock(func() time.Time { return time.Now().Add(8 * 24 * time.Hour) })
	inv4, _ := s.CreateInvite(ctx, domain.Scope{HouseholdID: other.ID, Role: domain.RoleOwner}, domain.RoleMember)
	s.SetClock(func() time.Time { return time.Now().Add(16 * 24 * time.Hour) })
	if _, err := s.InviteByToken(ctx, inv4.Token); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("expired invite: %v", err)
	}
}
