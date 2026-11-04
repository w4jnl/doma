package service_test

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/bus"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/secrets"
	"github.com/w4jnl/doma/internal/service"
)

func TestGuestLinksAndView(t *testing.T) {
	svc, h, a, _ := newSyncWorld(t)
	changes := bus.New()
	pushes := changes.Subscribe()
	svc.SetBus(changes)
	ctx := context.Background()
	first := sync1(t, svc, h, a)
	listID := payloadField(first.Events[0].Payload, "list_id")
	homeID := payloadField(first.Events[1].Payload, "home_id")
	owner := domain.Scope{HouseholdID: h.ID, PersonID: a.person, Role: domain.RoleOwner}
	item := domain.NewID()
	sync1(t, svc, h, a,
		a.event("item.named", map[string]any{"item_id": item, "name": "olijfolie"}),
		a.event("staple.added", map[string]any{"home_id": homeID, "item_id": item}),
		a.event("flag.set", map[string]any{"home_id": homeID, "item_id": item, "state": "out"}),
	)
	if _, err := svc.CreateGuestLink(ctx, domain.Scope{HouseholdID: h.ID, PersonID: a.person, Role: domain.RoleMember}, homeID, listID, "cleaner", 0); !errors.Is(err, domain.ErrForbidden) {
		t.Errorf("member making a guest link: %v", err)
	}
	if _, err := svc.CreateGuestLink(ctx, owner, "nope", listID, "cleaner", 0); !errors.As(err, new(domain.ErrValidation)) {
		t.Errorf("unknown home: %v", err)
	}
	g, err := svc.CreateGuestLink(ctx, owner, homeID, listID, "cleaner", 0)
	if err != nil {
		t.Fatal(err)
	}
	if g.URL != "https://doma.test/g/"+g.Token {
		t.Errorf("url %s", g.URL)
	}
	sc, cred, err := svc.GuestScope(ctx, g.Token)
	if err != nil || !sc.IsGuest() || sc.HomeID != homeID || sc.ListID != listID || cred != g.Link.CredentialID {
		t.Fatalf("scope %+v %s %v", sc, cred, err)
	}
	// guests do not sync
	if _, err := svc.Sync(ctx, sc.PersonID, cred, service.SyncRequest{Households: []service.SyncHousehold{{ID: h.ID}}}); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("guest syncing: %v", err)
	}
	view, err := svc.GuestView(ctx, sc)
	if err != nil {
		t.Fatal(err)
	}
	if view.HomeName != "Gouda" || view.ListName != service.DefaultListName || !view.AnyOut || len(view.Missing) != 1 || view.Missing[0].State != "out" || view.Missing[0].ItemName != "olijfolie" {
		t.Errorf("view %+v", view)
	}
	// the out flag put olijfolie on the default list; the guest adds, strikes, clears
	if len(view.Entries) != 1 || view.Entries[0].ItemName != "olijfolie" {
		t.Fatalf("entries %+v", view.Entries)
	}
	// what the syncs above published is not what this is about
	select {
	case <-pushes:
	default:
	}
	if err := svc.GuestAdd(ctx, sc, cred, "2 l melk"); err != nil {
		t.Fatal(err)
	}
	// the guest's add reaches the push side like any other writer's
	select {
	case c := <-pushes:
		if c.HouseholdID != h.ID || c.Seq == 0 {
			t.Errorf("published %+v", c)
		}
	case <-time.After(time.Second):
		t.Error("the guest's add was not published")
	}
	if err := svc.GuestAdd(ctx, sc, cred, "Olijfolie"); err != nil {
		t.Fatal(err)
	}
	view, _ = svc.GuestView(ctx, sc)
	if len(view.Entries) != 2 || view.Entries[1].ItemName != "melk" || view.Entries[1].Unit != "l" || *view.Entries[1].Qty != 2 {
		t.Fatalf("after add %+v", view.Entries)
	}
	if err := svc.GuestToggle(ctx, sc, cred, view.Entries[1].ID); err != nil {
		t.Fatal(err)
	}
	view, _ = svc.GuestView(ctx, sc)
	if !view.Entries[1].Checked || view.Entries[1].CheckedBy != "cleaner" {
		t.Errorf("after check %+v", view.Entries)
	}
	if err := svc.GuestClear(ctx, sc, cred); err != nil {
		t.Fatal(err)
	}
	view, _ = svc.GuestView(ctx, sc)
	if len(view.Entries) != 1 {
		t.Errorf("after clear %+v", view.Entries)
	}
	// the owner sees the link, then ends it
	gs, _ := svc.Guests(ctx, owner)
	if len(gs) != 1 || gs[0].Label != "cleaner" || !gs[0].Active(time.Now().UnixMilli()) {
		t.Errorf("guests %+v", gs)
	}
	if err := svc.RevokeGuest(ctx, owner, g.Link.CredentialID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := svc.GuestScope(ctx, g.Token); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("revoked link: %v", err)
	}
	if _, _, err := svc.GuestScope(ctx, "nope"); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("unknown link: %v", err)
	}
}

func TestAdminPagesData(t *testing.T) {
	svc, h, a, _ := newSyncWorld(t)
	ctx := context.Background()
	sync1(t, svc, h, a)
	ov, err := svc.Overview(ctx)
	if err != nil || len(ov) != 1 || ov[0].Members != 2 || ov[0].Devices != 2 || ov[0].LastEventAt == 0 {
		t.Fatalf("overview %+v %v", ov, err)
	}
	d, err := svc.HouseholdDetail(ctx, h.ID)
	if err != nil || len(d.MembersList) != 2 || len(d.DevicesList) != 2 || len(d.Homes) != 1 || len(d.Lists) != 1 || d.StalenessDays != 60 {
		t.Fatalf("detail %+v %v", d, err)
	}
	five := int64(5)
	if err := svc.SetQuotas(ctx, h.ID, &five, nil); err != nil {
		t.Fatal(err)
	}
	d, _ = svc.HouseholdDetail(ctx, h.ID)
	if d.QuotaDevices == nil || *d.QuotaDevices != 5 || d.QuotaPhotoBytes != nil {
		t.Errorf("quotas %+v", d.Household)
	}
	k, _ := secrets.FromBytes([]byte("0123456789abcdef0123456789abcdef"))
	svc.SetKeyring(k)
	if err := svc.Setup(ctx, "j", "long enough password"); err != nil {
		t.Fatal(err)
	}
	if on, _ := svc.TOTPEnabled(ctx); on {
		t.Error("totp on before setup")
	}
	secret, _ := auth.NewTOTPSecret()
	if err := svc.SetTOTP(ctx, secret); err != nil {
		t.Fatal(err)
	}
	code, _ := auth.TOTPCode(secret, time.Now())
	if err := svc.VerifyTOTP(ctx, code); err != nil {
		t.Errorf("good code: %v", err)
	}
	if err := svc.VerifyTOTP(ctx, "000000"); !errors.Is(err, domain.ErrUnauthorized) {
		t.Errorf("bad code: %v", err)
	}
	if err := svc.SetTOTP(ctx, ""); err != nil {
		t.Fatal(err)
	}
	if on, _ := svc.TOTPEnabled(ctx); on {
		t.Error("totp still on")
	}
	keyFile := filepath.Join(t.TempDir(), "secret.key")
	_ = os.WriteFile(keyFile, make([]byte, 32), 0o600)
	path, err := svc.Backup(ctx, keyFile, filepath.Join(t.TempDir(), "none"))
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, f := range zr.File {
		names[f.Name] = true
	}
	if !names["doma.db"] || !names["secret.key"] {
		t.Errorf("backup files %v", names)
	}
}
