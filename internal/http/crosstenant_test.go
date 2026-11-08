package http_test

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/client"
	"github.com/w4jnl/doma/internal/config"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/domain"
	dhttp "github.com/w4jnl/doma/internal/http"
	"github.com/w4jnl/doma/internal/service"
)

// The cross-tenant and cross-person suites: two households with an owner
// and a member each, plus a guest, and 404 across every boundary for sync,
// the snapshot, REST, photos and export.

type tenant struct {
	id, home, list string
	owner, member  *client.Client
}

type suite struct {
	t          *testing.T
	svc        *service.Service
	srv        *httptest.Server
	a, b       tenant
	guestToken string
	// photos is the photo directory, where card logos live too
	photos string
}

func newSuite(t *testing.T) *suite {
	t.Helper()
	auth.FastParamsForTests()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	photos := t.TempDir()
	svc := service.New(dbtest.Open(t), service.Config{BaseURL: "http://doma.test", SnapshotsDir: t.TempDir(), PhotosDir: photos, MaxUploadBytes: 200 << 10}, log)
	h, err := dhttp.Handler(dhttp.Deps{Cfg: config.Default(), Log: log, Svc: svc})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	s := &suite{t: t, svc: svc, srv: srv, photos: photos}
	s.a = s.tenant("Family A")
	s.b = s.tenant("Family B")
	g, err := svc.CreateGuestLink(context.Background(), domain.Scope{HouseholdID: s.a.id, Role: domain.RoleOwner}, s.a.home, s.a.list, "cleaner", 0)
	if err != nil {
		t.Fatal(err)
	}
	s.guestToken = g.Token
	return s
}

func (s *suite) tenant(name string) tenant {
	s.t.Helper()
	ctx := context.Background()
	h, err := s.svc.CreateHousehold(ctx, name, "Europe/Amsterdam", "Home")
	if err != nil {
		s.t.Fatal(err)
	}
	d, err := s.svc.HouseholdDetail(ctx, h.ID)
	if err != nil {
		s.t.Fatal(err)
	}
	tn := tenant{id: h.ID, home: d.Homes[0].ID, list: d.Lists[0].ID}
	tn.owner = s.join(h.ID, domain.RoleOwner, name+" owner")
	tn.member = s.join(h.ID, domain.RoleMember, name+" member")
	return tn
}

func (s *suite) join(householdID string, role domain.Role, name string) *client.Client {
	s.t.Helper()
	inv, err := s.svc.CreateInvite(context.Background(), domain.Scope{HouseholdID: householdID, Role: domain.RoleOwner}, role)
	if err != nil {
		s.t.Fatal(err)
	}
	c, err := client.New(s.srv.URL, s.srv.Client())
	if err != nil {
		s.t.Fatal(err)
	}
	if _, err := c.Accept(context.Background(), inv.Token, name, "test"); err != nil {
		s.t.Fatal(err)
	}
	return c
}

func status(err error) int {
	if err == nil {
		return 200
	}
	if p, ok := err.(*client.Problem); ok { //nolint:errorlint // returned unwrapped
		return p.Status
	}
	return -1
}

func event(clock *domain.Clock, kind string, payload map[string]any) json.RawMessage {
	raw, _ := json.Marshal(map[string]any{"id": domain.NewID(), "hlc": clock.Next().String(), "kind": kind, "payload": payload})
	return raw
}

func TestCrossTenantIs404Everywhere(t *testing.T) {
	s := newSuite(t)
	ctx := context.Background()
	other := s.b.id
	calls := map[string]func() error{
		"sync": func() error {
			return s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: other}}}, nil)
		},
		"sync mixed": func() error {
			return s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id}, {ID: other}}}, nil)
		},
		"snapshot": func() error { _, _, err := s.a.owner.Download(ctx, "/sync/v1/snapshot/"+other+"/1"); return err },
		"members":  func() error { return s.a.owner.Get(ctx, "/api/v1/h/"+other+"/members", nil) },
		"invites":  func() error { return s.a.owner.Get(ctx, "/api/v1/h/"+other+"/invites", nil) },
		"create invite": func() error {
			return s.a.owner.Do(ctx, http.MethodPost, "/api/v1/h/"+other+"/invites", map[string]string{"role": "member"}, nil)
		},
		"guests": func() error { return s.a.owner.Get(ctx, "/api/v1/h/"+other+"/guests", nil) },
		"update": func() error {
			return s.a.owner.Do(ctx, http.MethodPut, "/api/v1/h/"+other, map[string]string{"name": "x", "timezone": "Europe/Amsterdam"}, nil)
		},
		"remove member": func() error {
			return s.a.owner.Do(ctx, http.MethodDelete, "/api/v1/h/"+other+"/members/"+s.b.member.PersonID, nil, nil)
		},
		"set role": func() error {
			return s.a.owner.Do(ctx, http.MethodPut, "/api/v1/h/"+other+"/members/"+s.b.member.PersonID+"/role", map[string]string{"role": "owner"}, nil)
		},
		"export": func() error { _, _, err := s.a.owner.Download(ctx, "/api/v1/h/"+other+"/export"); return err },
		"photo upload": func() error {
			return s.a.owner.Upload(ctx, "/photos/v1/"+other+"/"+domain.NewID(), jpegBytes(t, 8, 8), "image/jpeg", nil)
		},
		"photo get": func() error { _, _, err := s.a.owner.Download(ctx, "/photos/v1/"+other+"/"+domain.NewID()); return err },
		"card logo": func() error {
			_, _, err := s.a.owner.Download(ctx, "/cards/v1/"+other+"/"+domain.NewID()+"/logo/0123456789abcdef")
			return err
		},
		"photo thumb": func() error {
			_, _, err := s.a.owner.Download(ctx, "/photos/v1/"+other+"/"+domain.NewID()+"/thumb")
			return err
		},
		"revoke device": func() error {
			return s.a.owner.Do(ctx, http.MethodDelete, "/api/v1/credentials/"+s.b.member.CredentialID, nil, nil)
		},
		"apns on theirs": func() error {
			return s.a.owner.Do(ctx, http.MethodPost, "/api/v1/devices/"+s.b.member.CredentialID+"/apns", map[string]string{"token": "t"}, nil)
		},
		"unknown household": func() error { return s.a.owner.Get(ctx, "/api/v1/h/01JUNKJUNKJUNKJUNKJUNKJUNK/members", nil) },
	}
	for name, call := range calls {
		if got := status(call()); got != http.StatusNotFound {
			t.Errorf("%s across households: %d, want 404", name, got)
		}
	}
	if err := s.a.owner.Get(ctx, "/api/v1/h/"+s.a.id+"/members", nil); err != nil {
		t.Errorf("own household: %v", err)
	}
	// b's events never reach a
	clock, _ := domain.NewClock("b", nil)
	var resp service.SyncResponse
	if err := s.b.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.b.id, Events: []json.RawMessage{
		event(clock, "item.named", map[string]any{"item_id": domain.NewID(), "name": "secret of b"}),
	}}}}, &resp); err != nil {
		t.Fatal(err)
	}
	if err := s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id}}}, &resp); err != nil {
		t.Fatal(err)
	}
	for _, e := range resp.Households[0].Events {
		if strings.Contains(string(e.Payload), "secret of b") {
			t.Fatal("b's event reached a")
		}
	}
	// the guest reaches nothing but its page
	g, _ := client.New(s.srv.URL, s.srv.Client())
	gs, cred, err := s.svc.GuestScope(ctx, s.guestToken)
	if err != nil {
		t.Fatal(err)
	}
	g.CredentialID, g.PersonID = cred, gs.PersonID
	if got := status(g.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id}}}, nil)); got != http.StatusUnauthorized {
		t.Errorf("guest sync: %d", got)
	}
	if got := status(g.Get(ctx, "/api/v1/me", nil)); got != http.StatusUnauthorized {
		t.Errorf("guest REST: %d", got)
	}
	r, err := s.srv.Client().Get(s.srv.URL + "/g/" + s.guestToken)
	if err != nil {
		t.Fatal(err)
	}
	_ = r.Body.Close()
	if r.StatusCode != http.StatusOK {
		t.Errorf("guest page: %d", r.StatusCode)
	}
	r, err = s.srv.Client().Get(s.srv.URL + "/g/" + strings.Repeat("x", 43))
	if err != nil {
		t.Fatal(err)
	}
	_ = r.Body.Close()
	if r.StatusCode != http.StatusNotFound {
		t.Errorf("unknown guest link: %d", r.StatusCode)
	}
}

func TestCrossPersonPersonalLists(t *testing.T) {
	s := newSuite(t)
	ctx := context.Background()
	clock, _ := domain.NewClock("m", nil)
	personal, item := domain.NewID(), domain.NewID()
	var resp service.SyncResponse
	err := s.a.member.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id, Events: []json.RawMessage{
		event(clock, "list.created", map[string]any{"list_id": personal, "name": "Mine", "owner_person_id": s.a.member.PersonID}),
		event(clock, "item.named", map[string]any{"item_id": item, "name": "private thing"}),
		event(clock, "entry.added", map[string]any{"list_id": personal, "item_id": item}),
	}}}}, &resp)
	if err != nil || len(resp.Households[0].Accepted) != 3 {
		t.Fatalf("member's push: %v %+v", err, resp)
	}
	if err := s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id}}}, &resp); err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, e := range resp.Households[0].Events {
		kinds = append(kinds, e.Kind)
		if strings.Contains(string(e.Payload), personal) {
			t.Errorf("owner received a personal-list event: %s %s", e.Kind, e.Payload)
		}
	}
	if !strings.Contains(strings.Join(kinds, ","), "item.named") {
		t.Errorf("owner did not get the shared item: %v", kinds)
	}
	oc, _ := domain.NewClock("o", nil)
	if err := s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id, Events: []json.RawMessage{
		event(oc, "entry.added", map[string]any{"list_id": personal, "item_id": item}),
	}}}}, &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Households[0].Rejected) != 1 || resp.Households[0].Rejected[0].Reason != "not your list" {
		t.Errorf("owner writing to the member's list: %+v", resp.Households[0])
	}
	zipRaw, _, err := s.a.owner.Download(ctx, "/api/v1/h/"+s.a.id+"/export")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(zipRaw, []byte(personal)) {
		t.Error("the owner's export names the personal list")
	}
	if err := s.svc.RunSnapshots(ctx); err != nil {
		t.Fatal(err)
	}
	var seq int64
	_ = s.svc.DB().Reader.QueryRowContext(ctx, "SELECT MAX(seq) FROM snapshots WHERE household_id = ?", s.a.id).Scan(&seq)
	snapRaw, _, err := s.a.owner.Download(ctx, "/sync/v1/snapshot/"+s.a.id+"/"+itoa(seq))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(gunzipMaybe(snapRaw), []byte(personal)) {
		t.Error("the owner's snapshot holds the personal list")
	}
	memberZip, _, err := s.a.member.Download(ctx, "/api/v1/h/"+s.a.id+"/export")
	if err != nil || !bytes.Contains(memberZip, []byte("mine")) {
		t.Errorf("member's export lacks their list: %v", err)
	}
}

// TestCrossPersonPersonalCards: a card one person keeps for themselves is
// theirs alone through sync, export and the snapshot, while the household's
// card reaches everyone.
func TestCrossPersonPersonalCards(t *testing.T) {
	s := newSuite(t)
	ctx := context.Background()
	clock, _ := domain.NewClock("m", nil)
	mine, ours := domain.NewID(), domain.NewID()
	var resp service.SyncResponse
	err := s.a.member.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id, Events: []json.RawMessage{
		event(clock, "card.added", map[string]any{"card_id": mine, "owner_person_id": s.a.member.PersonID, "name": "Bieb", "format": "code128", "value": "LIB-42"}),
		event(clock, "card.added", map[string]any{"card_id": ours, "name": "AH", "format": "ean13", "value": "2620000000006"}),
	}}}}, &resp)
	if err != nil || len(resp.Households[0].Accepted) != 2 {
		t.Fatalf("member's cards: %v %+v", err, resp)
	}
	if err := s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id}}}, &resp); err != nil {
		t.Fatal(err)
	}
	var seenOurs bool
	for _, e := range resp.Households[0].Events {
		if strings.Contains(string(e.Payload), mine) {
			t.Errorf("owner received a personal card: %s %s", e.Kind, e.Payload)
		}
		if strings.Contains(string(e.Payload), ours) {
			seenOurs = true
		}
	}
	if !seenOurs {
		t.Error("owner did not get the household's card")
	}
	oc, _ := domain.NewClock("o", nil)
	if err := s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id, Events: []json.RawMessage{
		event(oc, "card.archived", map[string]any{"card_id": mine}),
	}}}}, &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Households[0].Rejected) != 1 || resp.Households[0].Rejected[0].Reason != "not your card" {
		t.Errorf("owner archiving the member's card: %+v", resp.Households[0])
	}
	zipRaw, _, err := s.a.owner.Download(ctx, "/api/v1/h/"+s.a.id+"/export")
	if err != nil {
		t.Fatal(err)
	}
	if csvOwner := zipEntry(t, zipRaw, "cards.csv"); strings.Contains(csvOwner, mine) || strings.Contains(csvOwner, "LIB-42") || !strings.Contains(csvOwner, ours) {
		t.Errorf("the owner's cards.csv:\n%s", csvOwner)
	}
	if err := s.svc.RunSnapshots(ctx); err != nil {
		t.Fatal(err)
	}
	var seq int64
	_ = s.svc.DB().Reader.QueryRowContext(ctx, "SELECT MAX(seq) FROM snapshots WHERE household_id = ?", s.a.id).Scan(&seq)
	snapRaw, _, err := s.a.owner.Download(ctx, "/sync/v1/snapshot/"+s.a.id+"/"+itoa(seq))
	if err != nil {
		t.Fatal(err)
	}
	if snap := gunzipMaybe(snapRaw); bytes.Contains(snap, []byte(mine)) || !bytes.Contains(snap, []byte(ours)) {
		t.Error("the owner's snapshot holds the personal card or lacks the household's")
	}
	memberZip, _, err := s.a.member.Download(ctx, "/api/v1/h/"+s.a.id+"/export")
	if err != nil {
		t.Fatal(err)
	}
	if csvMember := zipEntry(t, memberZip, "cards.csv"); !strings.Contains(csvMember, "LIB-42") || !strings.Contains(csvMember, ours) {
		t.Errorf("the member's cards.csv:\n%s", csvMember)
	}
}

// jpegBytes is a w by h JPEG.
func jpegBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := range w {
		for y := range h {
			img.Set(x, y, color.RGBA{uint8(x * 9), uint8(y * 5), uint8(x ^ y), 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// TestPhotosOverHTTP: an upload for an accepted photo.added, the picture
// and its thumbnail back for members and for a signed link, and the
// refusals: not a JPEG, over the cap, too many, a stranger.
func TestPhotosOverHTTP(t *testing.T) {
	s := newSuite(t)
	ctx := context.Background()
	clock, _ := domain.NewClock("a", nil)
	spot, photoID := domain.NewID(), domain.NewID()
	if err := s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id, Events: []json.RawMessage{
		event(clock, "spot.created", map[string]any{"spot_id": spot, "home_id": s.a.home, "name": "Pantry"}),
		event(clock, "photo.added", map[string]any{"photo_id": photoID, "spot_id": spot}),
	}}}}, nil); err != nil {
		t.Fatal(err)
	}
	path := "/photos/v1/" + s.a.id + "/" + photoID
	// pending: nothing to get yet
	if _, _, err := s.a.member.Download(ctx, path); status(err) != http.StatusNotFound {
		t.Errorf("pending photo: %v", err)
	}
	// not a JPEG, then over the cap by Content-Length, then the real thing
	if err := s.a.member.Upload(ctx, path, []byte("hello"), "image/jpeg", nil); status(err) != http.StatusBadRequest {
		t.Errorf("text upload: %v", err)
	}
	if err := s.a.member.Upload(ctx, path, make([]byte, 300<<10), "image/jpeg", nil); status(err) != http.StatusRequestEntityTooLarge {
		t.Errorf("huge upload: %v", err)
	}
	var stored map[string]any
	if err := s.a.member.Upload(ctx, path, jpegBytes(t, 640, 480), "image/jpeg", &stored); err != nil {
		t.Fatal(err)
	}
	if stored["spot_id"] != spot || stored["width"] != float64(640) {
		t.Errorf("stored %v", stored)
	}
	// members of the household get it, with a thumbnail; the other household does not
	for _, p := range []string{path, path + "/thumb"} {
		raw, ctype, err := s.a.owner.Download(ctx, p)
		if err != nil || ctype != "image/jpeg" || !bytes.HasPrefix(raw, []byte{0xFF, 0xD8}) {
			t.Errorf("%s: %v %q", p, err, ctype)
		}
		if _, _, err := s.b.owner.Download(ctx, p); status(err) != http.StatusNotFound {
			t.Errorf("%s from the other household: %v", p, err)
		}
	}
	// a signed link opens without a device; a bare URL and a tampered link do not
	get := func(u string) int {
		r, err := s.srv.Client().Get(u)
		if err != nil {
			t.Fatal(err)
		}
		_ = r.Body.Close()
		if r.StatusCode == http.StatusOK && r.Header.Get("Cache-Control") != "private, max-age=3600" {
			t.Errorf("cache control %q", r.Header.Get("Cache-Control"))
		}
		return r.StatusCode
	}
	if got := get(s.srv.URL + path); got != http.StatusUnauthorized {
		t.Errorf("bare url: %d", got)
	}
	link := strings.Replace(s.svc.SignLink(path+"/thumb"), "http://doma.test", s.srv.URL, 1)
	if got := get(link); got != http.StatusOK {
		t.Errorf("signed link: %d", got)
	}
	if got := get(link + "x"); got != http.StatusUnauthorized {
		t.Errorf("tampered link: %d", got)
	}
	if got := get(strings.Replace(link, photoID, domain.NewID(), 1)); got != http.StatusUnauthorized {
		t.Errorf("link moved to another photo: %d", got)
	}
	// ten uploads a minute per device; the bodies differ so no two requests
	// are the one-millisecond replay the signature check refuses
	limited := false
	for i := range 12 {
		err := s.a.member.Upload(ctx, path, jpegBytes(t, 8+i, 8), "image/jpeg", nil)
		if status(err) == http.StatusTooManyRequests {
			limited = true
		}
		if i >= 10 && err == nil {
			t.Errorf("upload %d passed the limit", i+1)
		}
	}
	if !limited {
		t.Error("no upload was rate limited")
	}
	// the export carries it
	raw, _, err := s.a.owner.Download(ctx, "/api/v1/h/"+s.a.id+"/export")
	if err != nil || !bytes.Contains(raw, []byte("photos/"+photoID+".jpg")) {
		t.Errorf("export without the photo: %v", err)
	}
}
