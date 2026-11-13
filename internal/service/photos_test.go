package service_test

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/photo"
	"github.com/w4jnl/doma/internal/service"
)

// jpegBytes is a w by h JPEG of a gradient, so it compresses like a photo.
func jpegBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := range w {
		for y := range h {
			img.Set(x, y, color.RGBA{uint8(x * 7), uint8(y * 3), uint8(x ^ y), 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestPhotos(t *testing.T) {
	auth.FastParamsForTests()
	dir := t.TempDir()
	svc := service.New(dbtest.Open(t), service.Config{BaseURL: "https://doma.test", SnapshotsDir: t.TempDir(), PhotosDir: dir, PhotosPerSpot: 2, MaxUploadBytes: 1 << 20}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx := context.Background()
	h, err := svc.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	if err != nil {
		t.Fatal(err)
	}
	inv, _ := svc.CreateInvite(ctx, domain.Scope{HouseholdID: h.ID, Role: domain.RoleOwner}, domain.RoleOwner)
	acc, _ := accept(t, svc, inv.Token, "Jaro")
	clock, _ := domain.NewClock("a", nil)
	p := &phone{person: acc.PersonID, cred: acc.CredentialID, clock: clock}
	sc := domain.Scope{HouseholdID: h.ID, PersonID: acc.PersonID, Role: domain.RoleOwner}
	first := sync1(t, svc, h, p)
	home := payloadField(first.Events[1].Payload, "home_id")
	spot := domain.NewID()
	ids := []string{domain.NewID(), domain.NewID(), domain.NewID()}
	sync1(t, svc, h, p,
		p.event("spot.created", map[string]any{"spot_id": spot, "home_id": home, "name": "Pantry"}),
		p.event("photo.added", map[string]any{"photo_id": ids[0], "spot_id": spot}),
		p.event("photo.added", map[string]any{"photo_id": ids[1], "spot_id": spot}),
		p.event("photo.added", map[string]any{"photo_id": ids[2], "spot_id": spot}),
	)

	// an unknown id, a guest, a picture that is not a JPEG
	if _, err := svc.StorePhoto(ctx, sc, domain.NewID(), jpegBytes(t, 40, 30)); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("unknown photo: %v", err)
	}
	if _, err := svc.StorePhoto(ctx, domain.Scope{HouseholdID: h.ID, Role: domain.RoleGuest}, ids[0], nil); !errors.Is(err, domain.ErrForbidden) {
		t.Errorf("guest: %v", err)
	}
	if _, err := svc.StorePhoto(ctx, sc, ids[0], []byte("not a picture")); !errors.Is(err, photo.ErrNotJPEG) {
		t.Errorf("text: %v", err)
	}
	if _, err := svc.OpenPhoto(ctx, sc, ids[0], false); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("pending photo opened: %v", err)
	}

	// the first lands, with a thumbnail, and counts
	big := jpegBytes(t, 2000, 1500)
	stored, err := svc.StorePhoto(ctx, sc, ids[0], big)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Width != 1600 || stored.Height != 1200 || stored.SpotID != spot || stored.Bytes <= 0 {
		t.Errorf("stored %+v", stored)
	}
	for _, thumb := range []bool{false, true} {
		f, err := svc.OpenPhoto(ctx, sc, ids[0], thumb)
		if err != nil {
			t.Fatalf("open thumb=%v: %v", thumb, err)
		}
		if !strings.HasPrefix(f.Name(), filepath.Join(dir, h.ID)+"/") {
			t.Errorf("photo outside the household's folder: %s", f.Name())
		}
		_ = f.Close()
	}
	if n, _ := svc.PhotoBytes(ctx, h.ID); n != stored.Bytes {
		t.Errorf("bytes %d, want %d", n, stored.Bytes)
	}

	// the quota holds before and after the body
	tiny := int64(10)
	if err := svc.SetQuotas(ctx, h.ID, nil, &tiny); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.StorePhoto(ctx, sc, ids[1], jpegBytes(t, 40, 30)); !errors.Is(err, domain.ErrQuota) {
		t.Errorf("over quota before the body: %v", err)
	}
	// room for the upload's bytes but not for what is kept: a small, hard-to-compress picture
	// is larger kept than sent, since its thumbnail comes on top
	noisy := jpegBytes(t, 24, 24)
	room := stored.Bytes + int64(len(noisy)) + 1
	if err := svc.SetQuotas(ctx, h.ID, nil, &room); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.StorePhoto(ctx, sc, ids[1], noisy); !errors.Is(err, domain.ErrQuota) {
		t.Errorf("over quota after the body: %v", err)
	}
	if _, err := svc.OpenPhoto(ctx, sc, ids[1], false); !errors.Is(err, domain.ErrNotFound) {
		t.Error("a refused upload left a photo")
	}
	if err := svc.SetQuotas(ctx, h.ID, nil, nil); err != nil {
		t.Fatal(err)
	}

	// two per spot: the third upload prunes the oldest photo's files, its row stays pending
	for _, id := range ids[1:] {
		if _, err := svc.StorePhoto(ctx, sc, id, jpegBytes(t, 400, 300)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := svc.OpenPhoto(ctx, sc, ids[0], false); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("oldest photo kept past photos_per_spot: %v", err)
	}
	entries, _ := os.ReadDir(filepath.Join(dir, h.ID))
	if len(entries) != 4 {
		t.Errorf("%d files on disk, want 4", len(entries))
	}
	used, _ := svc.PhotoBytes(ctx, h.ID)

	// the nightly reconcile: a file gone makes the photo pending; an orphan file is removed
	p2, _ := svc.OpenPhoto(ctx, sc, ids[2], false)
	_ = p2.Close()
	_ = os.Remove(p2.Name())
	_ = os.WriteFile(filepath.Join(dir, h.ID, "orphan.jpg"), []byte("x"), 0o600)
	if err := svc.RunSnapshots(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.OpenPhoto(ctx, sc, ids[2], false); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("a photo whose file is gone still opens: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, h.ID, "orphan.jpg")); err == nil {
		t.Error("the orphan file stayed")
	}
	if after, _ := svc.PhotoBytes(ctx, h.ID); after >= used {
		t.Errorf("bytes after reconcile %d, before %d", after, used)
	}

	// the export carries the stored pictures
	var zipBuf bytes.Buffer
	if err := svc.Export(ctx, sc, &zipBuf); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(zipBuf.Bytes(), []byte("photos/"+ids[1]+".jpg")) || bytes.Contains(zipBuf.Bytes(), []byte("photos/"+ids[2]+".jpg")) {
		t.Error("the export does not carry exactly the stored photos")
	}

	// signed links: good, tampered, expired
	link := svc.SignLink("/photos/v1/" + h.ID + "/" + ids[1])
	u, err := url.Parse(link)
	if err != nil || !strings.HasPrefix(link, "https://doma.test/photos/v1/") {
		t.Fatalf("link %q: %v", link, err)
	}
	if !svc.CheckLink(u.Path, u.Query()) {
		t.Error("a fresh link does not open")
	}
	if svc.CheckLink("/photos/v1/"+h.ID+"/"+ids[2], u.Query()) {
		t.Error("a link opens another photo")
	}
	bad := u.Query()
	swap := "x"
	if strings.HasPrefix(bad.Get("sig"), swap) {
		swap = "y" // a signature that starts with x would be left as it was
	}
	bad.Set("sig", swap+bad.Get("sig")[1:])
	if svc.CheckLink(u.Path, bad) {
		t.Error("a tampered link opens")
	}
	svc.SetClock(func() time.Time { return time.Now().UTC().Add(service.LinkTTL + time.Minute) })
	if svc.CheckLink(u.Path, u.Query()) {
		t.Error("an old link still opens")
	}

	// deleting a household with nobody in it takes its photos
	empty, _ := svc.CreateHousehold(ctx, "Gone", "Europe/Amsterdam", "Nowhere")
	if err := os.MkdirAll(filepath.Join(dir, empty.ID), 0o750); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(dir, empty.ID, "x.jpg"), []byte("x"), 0o600)
	if err := svc.DeleteHousehold(ctx, empty.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, empty.ID)); err == nil {
		t.Error("the deleted household's photos stayed")
	}
}
