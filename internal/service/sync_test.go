package service_test

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/bus"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

// phone is a device in a sync test: a person, a credential and a clock.
type phone struct {
	person, cred string
	clock        *domain.Clock
	since        int64
}

func (p *phone) event(kind string, payload map[string]any) json.RawMessage {
	raw, _ := json.Marshal(map[string]any{"id": domain.NewID(), "hlc": p.clock.Next().String(), "kind": kind, "payload": payload})
	return raw
}

func newSyncWorld(t *testing.T) (*service.Service, *domain.Household, *phone, *phone) {
	t.Helper()
	auth.FastParamsForTests()
	svc := service.New(dbtest.Open(t), service.Config{BaseURL: "https://doma.test", SnapshotsDir: t.TempDir(), ReplayLimit: 5000}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx := context.Background()
	h, err := svc.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	if err != nil {
		t.Fatal(err)
	}
	mk := func(name, dev string, role domain.Role) *phone {
		inv, _ := svc.CreateInvite(ctx, domain.Scope{HouseholdID: h.ID, Role: domain.RoleOwner}, role)
		acc, _ := accept(t, svc, inv.Token, name)
		c, _ := domain.NewClock(dev, nil)
		return &phone{person: acc.PersonID, cred: acc.CredentialID, clock: c}
	}
	return svc, h, mk("Jaro", "a", domain.RoleOwner), mk("Sam", "b", domain.RoleMember)
}

func sync1(t *testing.T, svc *service.Service, h *domain.Household, p *phone, evs ...json.RawMessage) *service.SyncHouseholdResult {
	t.Helper()
	resp, err := svc.Sync(context.Background(), p.person, p.cred, service.SyncRequest{Households: []service.SyncHousehold{{ID: h.ID, Since: p.since, Events: evs}}})
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	res := resp.Households[0]
	p.since = res.Next
	return &res
}

func TestSyncTwoPhonesConverge(t *testing.T) {
	svc, h, a, b := newSyncWorld(t)
	ctx := context.Background()
	changes := bus.New()
	ch := changes.Subscribe()
	svc.SetBus(changes)

	// the household's own two events come down first
	first := sync1(t, svc, h, a)
	if len(first.Events) != 2 || first.Events[0].Kind != "list.created" || first.Next != 2 {
		t.Fatalf("initial pull: %+v", first)
	}
	listID := payloadField(first.Events[0].Payload, "list_id")
	item := domain.NewID()
	res := sync1(t, svc, h, a,
		a.event("item.named", map[string]any{"item_id": item, "name": "melk"}),
		a.event("entry.added", map[string]any{"list_id": listID, "item_id": item, "qty": 2, "unit": "x"}),
	)
	if len(res.Accepted) != 2 || len(res.Rejected) != 0 || len(res.Events) != 2 || res.Next != 4 {
		t.Fatalf("push: %+v", res)
	}
	select {
	case c := <-ch:
		if c.HouseholdID != h.ID || c.Seq != 4 {
			t.Errorf("bus: %+v", c)
		}
	case <-time.After(time.Second):
		t.Error("no bus notification")
	}
	// b pulls and sees everything, then checks the entry
	pull := sync1(t, svc, h, b)
	if len(pull.Events) != 4 {
		t.Fatalf("b's pull: %d events", len(pull.Events))
	}
	b.clock.Observe(domain.MustHLC(pull.Events[3].HLC))
	sync1(t, svc, h, b, b.event("entry.checked", map[string]any{"list_id": listID, "item_id": item}))
	// a pulls b's check; the same event twice is accepted once
	dup := b.event("entry.unchecked", map[string]any{"list_id": listID, "item_id": item})
	res = sync1(t, svc, h, a, dup, dup)
	if len(res.Accepted) != 2 || len(res.Events) != 2 {
		t.Errorf("duplicate in one batch: %+v", res)
	}
	var checked *string
	_ = svc.DB().Reader.QueryRowContext(ctx, "SELECT checked_hlc FROM entries WHERE household_id = ? AND item_id = ?", h.ID, item).Scan(&checked)
	if checked != nil {
		t.Errorf("entry still checked after the uncheck: %v", *checked)
	}
	var n int
	_ = svc.DB().Reader.QueryRowContext(ctx, "SELECT COUNT(*) FROM events WHERE household_id = ?", h.ID).Scan(&n)
	if n != 6 {
		t.Errorf("events in the log: %d", n)
	}
}

func payloadField(raw json.RawMessage, key string) string {
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	s, _ := m[key].(string)
	return s
}

func TestSyncRejectsAndFilters(t *testing.T) {
	svc, h, a, b := newSyncWorld(t)
	first := sync1(t, svc, h, a)
	listID := payloadField(first.Events[0].Payload, "list_id")
	personal := domain.NewID()
	item := domain.NewID()
	res := sync1(t, svc, h, a,
		json.RawMessage(`{"id": "bad1", "hlc": "1:0:a", "kind": "entry.added", "payload": {"list_id": "x"}}`),
		json.RawMessage(`{"id": "bad2", "kind": "entry.added"}`),
		json.RawMessage(`not json`),
		a.event("member.removed", map[string]any{"person_id": b.person}),
		a.event("list.created", map[string]any{"list_id": personal, "name": "Mine", "owner_person_id": a.person}),
		a.event("item.named", map[string]any{"item_id": item, "name": "wine"}),
		a.event("entry.added", map[string]any{"list_id": personal, "item_id": item}),
		a.event("entry.added", map[string]any{"list_id": listID, "item_id": item}),
	)
	if len(res.Accepted) != 4 || len(res.Rejected) != 4 {
		t.Fatalf("accepted %v rejected %+v", res.Accepted, res.Rejected)
	}
	reasons := map[string]string{}
	for _, r := range res.Rejected {
		reasons[r.ID] = r.Reason
	}
	if !strings.Contains(reasons["bad1"], "item_id") || reasons["bad2"] == "" || reasons[""] != "not an event" {
		t.Errorf("reasons %v", reasons)
	}
	for _, r := range res.Rejected {
		if strings.Contains(r.Reason, "server-originated") {
			reasons["srv"] = r.Reason
		}
	}
	if reasons["srv"] == "" {
		t.Errorf("member.removed from a client was accepted: %v", reasons)
	}
	// b sees the shared entry and the item, not a's personal list or its entry
	pull := sync1(t, svc, h, b)
	var kinds []string
	for _, e := range pull.Events {
		kinds = append(kinds, e.Kind)
		if l := payloadField(e.Payload, "list_id"); l == personal {
			t.Errorf("b received a personal-list event: %s", e.Kind)
		}
	}
	if len(pull.Events) != 4 || pull.Next != 6 {
		t.Errorf("b's pull: %v next %d", kinds, pull.Next)
	}
	// b may not write to a's personal list
	res = sync1(t, svc, h, b, b.event("entry.added", map[string]any{"list_id": personal, "item_id": item}))
	if len(res.Rejected) != 1 || res.Rejected[0].Reason != "not your list" {
		t.Errorf("writing to another's list: %+v", res)
	}
	// a household the person is not in is a 404 for the whole request
	other, _ := svc.CreateHousehold(context.Background(), "Others", "Europe/Amsterdam", "X")
	_, err := svc.Sync(context.Background(), b.person, b.cred, service.SyncRequest{Households: []service.SyncHousehold{{ID: h.ID}, {ID: other.ID}}})
	if !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("foreign household: %v", err)
	}
	// too many events in one household
	many := make([]json.RawMessage, service.MaxEventsPerRequest+1)
	for i := range many {
		many[i] = a.event("item.named", map[string]any{"item_id": fmt.Sprintf("I%d", i), "name": fmt.Sprintf("thing %d", i)})
	}
	_, err = svc.Sync(context.Background(), a.person, a.cred, service.SyncRequest{Households: []service.SyncHousehold{{ID: h.ID, Events: many}}})
	if !errors.As(err, new(domain.ErrValidation)) {
		t.Errorf("too many events: %v", err)
	}
}

func TestSyncPagesAndSnapshots(t *testing.T) {
	svc, h, a, b := newSyncWorld(t)
	ctx := context.Background()
	first := sync1(t, svc, h, a)
	listID := payloadField(first.Events[0].Payload, "list_id")
	var evs []json.RawMessage
	for i := range 600 {
		id := fmt.Sprintf("I%03d", i)
		evs = append(evs, a.event("item.named", map[string]any{"item_id": id, "name": fmt.Sprintf("thing %d", i)}))
		if i%3 == 0 {
			evs = append(evs, a.event("entry.added", map[string]any{"list_id": listID, "item_id": id}))
		}
	}
	res := sync1(t, svc, h, a, evs...)
	if len(res.Accepted) != len(evs) || len(res.Events) != 500 {
		t.Fatalf("accepted %d returned %d", len(res.Accepted), len(res.Events))
	}
	// the client loops while next advances
	total := len(res.Events)
	for range 5 {
		more := sync1(t, svc, h, a)
		total += len(more.Events)
		if len(more.Events) == 0 {
			break
		}
	}
	if total != len(evs) {
		t.Errorf("paged %d of %d", total, len(evs))
	}
	// the snapshot job writes a file and records the seq; a far-behind device is sent to it
	if err := svc.RunSnapshots(ctx); err != nil {
		t.Fatal(err)
	}
	if svc.LastSnapshotRun().IsZero() {
		t.Error("LastSnapshotRun is zero")
	}
	svc2 := svc // a lower replay limit for this check
	_ = svc2
	svcLow := service.New(svc.DB(), service.Config{BaseURL: "https://doma.test", SnapshotsDir: t.TempDir(), ReplayLimit: 100}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	resp, err := svcLow.Sync(ctx, b.person, b.cred, service.SyncRequest{Households: []service.SyncHousehold{{ID: h.ID, Since: 0}}})
	if err != nil {
		t.Fatal(err)
	}
	snap := resp.Households[0]
	if snap.Snapshot == nil || !strings.HasPrefix(*snap.Snapshot, "https://doma.test/sync/v1/snapshot/"+h.ID+"/") || len(snap.Events) != 0 || snap.Next != 2+int64(len(evs)) {
		t.Fatalf("snapshot pointer: %+v", snap)
	}
	rc, err := svc.OpenSnapshot(ctx, domain.Scope{HouseholdID: h.ID, PersonID: b.person, Role: domain.RoleMember}, snap.Next)
	if err != nil {
		t.Fatal(err)
	}
	gz, err := gzip.NewReader(rc)
	if err != nil {
		t.Fatal(err)
	}
	var got service.Snapshot
	if err := json.NewDecoder(gz).Decode(&got); err != nil {
		t.Fatal(err)
	}
	_ = rc.Close()
	if got.Seq != snap.Next || len(got.Tables.Items) != 600 || len(got.Tables.Entries) != 200 || len(got.Tables.Lists) != 1 {
		t.Errorf("snapshot: seq %d items %d entries %d lists %d", got.Seq, len(got.Tables.Items), len(got.Tables.Entries), len(got.Tables.Lists))
	}
	if _, err := svc.OpenSnapshot(ctx, domain.Scope{HouseholdID: h.ID, PersonID: b.person, Role: domain.RoleMember}, 1); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("unknown snapshot: %v", err)
	}
	// a second run with no new events keeps the one snapshot
	if err := svc.RunSnapshots(ctx); err != nil {
		t.Fatal(err)
	}
	var n int
	_ = svc.DB().Reader.QueryRowContext(ctx, "SELECT COUNT(*) FROM snapshots WHERE household_id = ?", h.ID).Scan(&n)
	if n != 1 {
		t.Errorf("snapshots after an unchanged run: %d", n)
	}
	// retention: with the clock two years on, the events the snapshot covers go
	svc.SetClock(func() time.Time { return time.Now().Add(2 * 365 * 24 * time.Hour) })
	if err := svc.RunSnapshots(ctx); err != nil {
		t.Fatal(err)
	}
	_ = svc.DB().Reader.QueryRowContext(ctx, "SELECT COUNT(*) FROM events WHERE household_id = ?", h.ID).Scan(&n)
	if n != 0 {
		t.Errorf("events after retention: %d", n)
	}
	var entries int
	_ = svc.DB().Reader.QueryRowContext(ctx, "SELECT COUNT(*) FROM entries WHERE household_id = ?", h.ID).Scan(&entries)
	if entries != 200 {
		t.Errorf("materialised rows pruned: %d", entries)
	}
}

func TestExport(t *testing.T) {
	svc, h, a, b := newSyncWorld(t)
	ctx := context.Background()
	first := sync1(t, svc, h, a)
	listID := payloadField(first.Events[0].Payload, "list_id")
	homeID := payloadField(first.Events[1].Payload, "home_id")
	item, personal := domain.NewID(), domain.NewID()
	sync1(t, svc, h, a,
		a.event("item.named", map[string]any{"item_id": item, "name": "olijfolie"}),
		a.event("entry.added", map[string]any{"list_id": listID, "item_id": item, "qty": 1, "unit": "l", "for_home_id": homeID}),
		a.event("entry.checked", map[string]any{"list_id": listID, "item_id": item}),
		a.event("entry.cleared", map[string]any{"list_id": listID, "before_hlc": a.clock.Next().String()}),
		a.event("staple.added", map[string]any{"home_id": homeID, "item_id": item}),
		a.event("list.created", map[string]any{"list_id": personal, "name": "Secret", "owner_person_id": a.person}),
		a.event("entry.added", map[string]any{"list_id": personal, "item_id": item}),
	)
	var buf bytes.Buffer
	if err := svc.Export(ctx, domain.Scope{HouseholdID: h.ID, PersonID: b.person, Role: domain.RoleMember}, &buf); err != nil {
		t.Fatal(err)
	}
	zr, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]string{}
	for _, f := range zr.File {
		rc, _ := f.Open()
		raw, _ := io.ReadAll(rc)
		_ = rc.Close()
		files[f.Name] = string(raw)
	}
	if !strings.Contains(files["purchases.csv"], "olijfolie,1,l,,Gouda,Jaro,Jaro") {
		t.Errorf("purchases.csv:\n%s", files["purchases.csv"])
	}
	if strings.Count(files["events.ndjson"], "\n") != 7 || strings.Contains(files["events.ndjson"], "Secret") {
		t.Errorf("events.ndjson has %d lines, personal leaked %v", strings.Count(files["events.ndjson"], "\n"), strings.Contains(files["events.ndjson"], "Secret"))
	}
	if !strings.Contains(files["household.json"], `"Family"`) || strings.Contains(files["household.json"], "Secret") {
		t.Errorf("household.json: %s", files["household.json"])
	}
	if !strings.Contains(files["homes/gouda.md"], "olijfolie: have") {
		t.Errorf("homes/gouda.md:\n%s", files["homes/gouda.md"])
	}
	var listFiles int
	for name := range files {
		if strings.HasPrefix(name, "lists/") {
			listFiles++
			if strings.Contains(name, "secret") {
				t.Errorf("personal list exported to %s", name)
			}
		}
	}
	if listFiles != 1 {
		t.Errorf("list files: %d", listFiles)
	}
	// the owner's own export has the personal list
	buf.Reset()
	if err := svc.Export(ctx, domain.Scope{HouseholdID: h.ID, PersonID: a.person, Role: domain.RoleOwner}, &buf); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(buf.Bytes(), []byte("secret")) {
		t.Error("owner's export lacks their personal list")
	}
	if err := svc.Export(ctx, domain.Scope{HouseholdID: h.ID, PersonID: "g", Role: domain.RoleGuest}, io.Discard); !errors.Is(err, domain.ErrForbidden) {
		t.Errorf("guest export: %v", err)
	}
}
