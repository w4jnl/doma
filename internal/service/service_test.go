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

func TestDeviceInvite(t *testing.T) {
	s := newService(t)
	ctx := context.Background()
	h, err := s.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	if err != nil {
		t.Fatal(err)
	}
	adminScope := domain.Scope{HouseholdID: h.ID, Role: domain.RoleOwner}
	first, _ := s.CreateInvite(ctx, adminScope, domain.RoleOwner)
	owner, ownerKey := accept(t, s, first.Token, "Jaro")
	ownerScope := domain.Scope{HouseholdID: h.ID, PersonID: owner.PersonID, Role: domain.RoleOwner}
	second, _ := s.CreateInvite(ctx, ownerScope, domain.RoleMember)
	member, memberKey := accept(t, s, second.Token, "Sam")
	memberScope := domain.Scope{HouseholdID: h.ID, PersonID: member.PersonID, Role: domain.RoleMember}

	// any member makes one for themselves; it is not a household invite
	dev, err := s.CreateDeviceInvite(ctx, memberScope)
	if err != nil {
		t.Fatal(err)
	}
	if !dev.Invite.IsDevice() || *dev.Invite.ForPersonID != member.PersonID || dev.Invite.Role != domain.RoleMember {
		t.Errorf("device invite: %+v", dev.Invite)
	}
	if pending, _ := s.Invites(ctx, ownerScope); len(pending) != 0 {
		t.Errorf("a device invite is listed among the household's: %+v", pending)
	}
	if pv, err := s.InviteByToken(ctx, dev.Token); err != nil || pv.ForPerson != "Sam" {
		t.Errorf("preview: %+v %v", pv, err)
	}
	if _, err := s.CreateDeviceInvite(ctx, adminScope); !errors.Is(err, domain.ErrForbidden) {
		t.Errorf("the admin has no person to add a device to: %v", err)
	}

	// a key of someone else is refused, the invite stays
	if _, err := s.AcceptInvite(ctx, dev.Token, service.AcceptInvite{PublicKey: ownerKey.Public(), Platform: "macos", DisplayName: "Jaro"}); !errors.Is(err, domain.ErrConflict) {
		t.Errorf("another person's key: %v", err)
	}

	// a new key becomes Sam's second device, whatever name it typed
	mac, err := auth.NewEd25519Signer()
	if err != nil {
		t.Fatal(err)
	}
	acc, err := s.AcceptInvite(ctx, dev.Token, service.AcceptInvite{PublicKey: mac.Public(), Platform: "macos", Label: "Sam's Mac", DisplayName: "Samuel"})
	if err != nil {
		t.Fatalf("device accept: %v", err)
	}
	if acc.PersonID != member.PersonID || acc.CredentialID == member.CredentialID || acc.DisplayName != "Sam" || acc.Role != domain.RoleMember || !acc.Device {
		t.Errorf("device accepted: %+v", acc)
	}
	if _, err := s.AcceptInvite(ctx, dev.Token, service.AcceptInvite{PublicKey: memberKey.Public(), DisplayName: "Sam"}); !errors.Is(err, domain.ErrConflict) {
		t.Errorf("a device invite works once: %v", err)
	}
	me, err := s.Me(ctx, member.PersonID)
	if err != nil || len(me.Credentials) != 2 || me.Person.DisplayName != "Sam" {
		t.Errorf("me after a second device: %+v %v", me, err)
	}
	if members, _ := s.Members(ctx, ownerScope); len(members) != 2 {
		t.Errorf("a device is not a member: %d members", len(members))
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
	owner, ownerKey := accept(t, s, inv.Token, "Jaro")
	if owner.Role != domain.RoleOwner || owner.Household.ID != h.ID || owner.Server != "https://doma.test" {
		t.Errorf("accepted: %+v", owner)
	}
	if _, err := s.AcceptInvite(ctx, inv.Token, service.AcceptInvite{PublicKey: "ed25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", DisplayName: "Again"}); !errors.Is(err, domain.ErrConflict) {
		t.Errorf("second use: %v", err)
	}
	// the same key after a reinstall: the seat comes back, the invite stays
	again, err := s.CreateInvite(ctx, adminScope, domain.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	back, err := s.AcceptInvite(ctx, again.Token, service.AcceptInvite{PublicKey: ownerKey.Public(), Platform: "ios", DisplayName: "Jaro"})
	if err != nil {
		t.Fatalf("rejoin: %v", err)
	}
	if back.PersonID != owner.PersonID || back.CredentialID != owner.CredentialID || back.Role != domain.RoleOwner || !back.Rejoined {
		t.Errorf("rejoin: %+v", back)
	}
	if _, err := s.InviteByToken(ctx, again.Token); err != nil {
		t.Errorf("invite after a rejoin should be unused: %v", err)
	}
	if err := s.RevokeInvite(ctx, adminScope, again.Invite.ID); err != nil {
		t.Fatal(err)
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
	// deleting with members left: the household goes, a person with no other household goes
	// with their devices, a person who is elsewhere too stays
	other, _ := s.CreateHousehold(ctx, "Others", "Europe/Amsterdam", "Elsewhere")
	oinv, _ := s.CreateInvite(ctx, domain.Scope{HouseholdID: other.ID, Role: domain.RoleOwner}, domain.RoleOwner)
	if _, err := s.AcceptInvite(ctx, oinv.Token, service.AcceptInvite{PublicKey: ownerKey.Public(), DisplayName: "Jaro"}); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteHousehold(ctx, h.ID); err != nil {
		t.Fatalf("delete with members: %v", err)
	}
	if _, err := s.HouseholdByID(ctx, h.ID); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("household after delete: %v", err)
	}
	if _, err := s.CredentialForAuth(ctx, owner.CredentialID); err != nil {
		t.Errorf("the owner is still in Others, their device should stay: %v", err)
	}
	if _, err := s.CredentialForAuth(ctx, member.CredentialID); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("the member belonged nowhere else, their device should be gone: %v", err)
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

	if err := s.SetAPNSToken(ctx, member.PersonID, member.CredentialID, "tok", false); err != nil {
		t.Errorf("own apns: %v", err)
	}
	if err := s.SetAPNSToken(ctx, owner.PersonID, member.CredentialID, "tok", false); !errors.Is(err, domain.ErrNotFound) {
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
	// the write is once a minute per credential: a device syncing every five seconds is not
	// two writes per request on the one writer
	first := *me.Person.LastSeenAt
	s.SetClock(func() time.Time { return time.Now().Add(30 * time.Second) })
	s.Touch(ctx, stranger.CredentialID, stranger.PersonID)
	me, _ = s.Me(ctx, stranger.PersonID)
	if *me.Person.LastSeenAt != first {
		t.Error("Touch wrote again inside a minute")
	}
	s.SetClock(func() time.Time { return time.Now().Add(service.TouchEvery + time.Second) })
	s.Touch(ctx, stranger.CredentialID, stranger.PersonID)
	me, _ = s.Me(ctx, stranger.PersonID)
	if *me.Person.LastSeenAt == first {
		t.Error("Touch did not write again after a minute")
	}
	s.SetClock(func() time.Time { return time.Now().Add(8 * 24 * time.Hour) })
	inv4, _ := s.CreateInvite(ctx, domain.Scope{HouseholdID: other.ID, Role: domain.RoleOwner}, domain.RoleMember)
	s.SetClock(func() time.Time { return time.Now().Add(16 * 24 * time.Hour) })
	if _, err := s.InviteByToken(ctx, inv4.Token); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("expired invite: %v", err)
	}
}

// A household's device quota holds at acceptance: a new person, a second device, a person
// bringing two devices from another household; a rejoin and a revoked device do not count.
func TestDeviceQuotaAtAcceptance(t *testing.T) {
	s := newService(t)
	ctx := context.Background()
	h, _ := s.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	two := int64(2)
	if err := s.SetQuotas(ctx, h.ID, &two, nil); err != nil {
		t.Fatal(err)
	}
	adminScope := domain.Scope{HouseholdID: h.ID, Role: domain.RoleOwner}
	inv, _ := s.CreateInvite(ctx, adminScope, domain.RoleOwner)
	owner, ownerKey := accept(t, s, inv.Token, "Jaro")
	ownerScope := domain.Scope{HouseholdID: h.ID, PersonID: owner.PersonID, Role: domain.RoleOwner}
	inv2, _ := s.CreateInvite(ctx, ownerScope, domain.RoleMember)
	member, _ := accept(t, s, inv2.Token, "Sam")

	// the third device: a new person, or the owner's second device
	inv3, _ := s.CreateInvite(ctx, ownerScope, domain.RoleMember)
	third, _ := auth.NewEd25519Signer()
	if _, err := s.AcceptInvite(ctx, inv3.Token, service.AcceptInvite{PublicKey: third.Public(), DisplayName: "Alex"}); !errors.Is(err, domain.ErrQuota) {
		t.Fatalf("third device: %v", err)
	}
	if _, err := s.InviteByToken(ctx, inv3.Token); err != nil {
		t.Errorf("a refused invite stays unused: %v", err)
	}
	dev, err := s.CreateDeviceInvite(ctx, ownerScope)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AcceptInvite(ctx, dev.Token, service.AcceptInvite{PublicKey: third.Public()}); !errors.Is(err, domain.ErrQuota) {
		t.Errorf("owner's second device: %v", err)
	}
	// a rejoin adds no device
	if _, err := s.AcceptInvite(ctx, inv3.Token, service.AcceptInvite{PublicKey: ownerKey.Public(), DisplayName: "Jaro"}); err != nil {
		t.Errorf("rejoin under a full quota: %v", err)
	}
	// a revoked device frees its seat
	if err := s.RevokeCredential(ctx, owner.PersonID, member.CredentialID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AcceptInvite(ctx, inv3.Token, service.AcceptInvite{PublicKey: third.Public(), DisplayName: "Alex"}); err != nil {
		t.Errorf("after a revoke: %v", err)
	}
	// a person with two devices elsewhere brings both: one seat is not enough
	other, _ := s.CreateHousehold(ctx, "Others", "Europe/Amsterdam", "Elsewhere")
	oinv, _ := s.CreateInvite(ctx, domain.Scope{HouseholdID: other.ID, Role: domain.RoleOwner}, domain.RoleOwner)
	alex, alexKey := accept(t, s, oinv.Token, "Alex B")
	odev, _ := s.CreateDeviceInvite(ctx, domain.Scope{HouseholdID: other.ID, PersonID: alex.PersonID, Role: domain.RoleOwner})
	second, _ := auth.NewEd25519Signer()
	if _, err := s.AcceptInvite(ctx, odev.Token, service.AcceptInvite{PublicKey: second.Public()}); err != nil {
		t.Fatal(err)
	}
	three := int64(3)
	if err := s.SetQuotas(ctx, h.ID, &three, nil); err != nil {
		t.Fatal(err)
	}
	inv4, _ := s.CreateInvite(ctx, ownerScope, domain.RoleMember)
	if _, err := s.AcceptInvite(ctx, inv4.Token, service.AcceptInvite{PublicKey: alexKey.Public(), DisplayName: "Alex B"}); !errors.Is(err, domain.ErrQuota) {
		t.Errorf("two devices into one seat: %v", err)
	}
	var unlimited *int64
	if err := s.SetQuotas(ctx, h.ID, unlimited, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AcceptInvite(ctx, inv4.Token, service.AcceptInvite{PublicKey: alexKey.Public(), DisplayName: "Alex B"}); err != nil {
		t.Errorf("no quota: %v", err)
	}
}
