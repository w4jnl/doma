package sync_test

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/client"
	"github.com/w4jnl/doma/internal/config"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/domain"
	dhttp "github.com/w4jnl/doma/internal/http"
	"github.com/w4jnl/doma/internal/service"
)

// TestSyncOverHTTP runs the whole surface in an httptest server and drives
// it with the Go client, as the e2e smoke will.
func TestSyncOverHTTP(t *testing.T) {
	auth.FastParamsForTests()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cfg := config.Default()
	svc := service.New(dbtest.Open(t), service.Config{BaseURL: "http://doma.test", SnapshotsDir: t.TempDir(), ReplayLimit: 3}, log)
	h, err := dhttp.Handler(dhttp.Deps{Cfg: cfg, Log: log, Svc: svc})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()
	ctx := context.Background()
	hh, _ := svc.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	inv, _ := svc.CreateInvite(ctx, domain.Scope{HouseholdID: hh.ID, Role: domain.RoleOwner}, domain.RoleOwner)

	c, err := client.New(srv.URL, srv.Client())
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Sync(ctx, map[string]any{"households": []any{}}, nil); err == nil {
		t.Fatal("sync without a credential must fail")
	}
	acc, err := c.Accept(ctx, inv.Token, "Jaro", "test")
	if err != nil {
		t.Fatal(err)
	}
	if acc.Household.ID != hh.ID {
		t.Errorf("accepted %+v", acc)
	}
	var resp service.SyncResponse
	if err := c.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: hh.ID}}}, &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Households) != 1 || len(resp.Households[0].Events) != 2 {
		t.Fatalf("first sync: %+v", resp)
	}
	listID := ""
	_ = json.Unmarshal(resp.Households[0].Events[0].Payload, &struct {
		ListID *string `json:"list_id"`
	}{ListID: &listID})
	clock, _ := domain.NewClock("go", nil)
	ev := func(kind string, payload map[string]any) json.RawMessage {
		raw, _ := json.Marshal(map[string]any{"id": domain.NewID(), "hlc": clock.Next().String(), "kind": kind, "payload": payload})
		return raw
	}
	item := domain.NewID()
	req := service.SyncRequest{Households: []service.SyncHousehold{{ID: hh.ID, Since: 2, Events: []json.RawMessage{
		ev("item.named", map[string]any{"item_id": item, "name": "melk"}),
		ev("entry.added", map[string]any{"list_id": listID, "item_id": item}),
		ev("entry.added", map[string]any{"list_id": listID, "item_id": item, "note": "again"}),
		ev("flag.set", map[string]any{"home_id": "H", "item_id": item, "state": "out"}),
	}}}}
	if err := c.Sync(ctx, req, &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Households[0].Accepted) != 4 || resp.Households[0].Next != 6 {
		t.Fatalf("push: %+v", resp.Households[0])
	}
	// a foreign household in the body is a 404 problem
	var p *client.Problem
	err = c.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: "nope"}}}, &resp)
	if !asProblem(err, &p) || p.Status != http.StatusNotFound {
		t.Errorf("foreign household: %v", err)
	}
	// snapshot: run the job, then a cursor at 0 is sent to the snapshot, which downloads as gzip JSON
	if err := svc.RunSnapshots(ctx); err != nil {
		t.Fatal(err)
	}
	if err := c.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: hh.ID, Since: 0}}}, &resp); err != nil {
		t.Fatal(err)
	}
	snapURL := resp.Households[0].Snapshot
	if snapURL == nil {
		t.Fatalf("no snapshot pointer: %+v", resp.Households[0])
	}
	path := (*snapURL)[len("http://doma.test"):]
	raw, ctype, err := c.Download(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if ctype != "application/json" {
		t.Errorf("content type %q", ctype)
	}
	var snap service.Snapshot
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err == nil {
		err = json.NewDecoder(gz).Decode(&snap)
	}
	if err != nil {
		// Go's transport may have decoded the gzip already
		if err2 := json.Unmarshal(raw, &snap); err2 != nil {
			t.Fatalf("snapshot body: %v / %v", err, err2)
		}
	}
	if snap.Seq != 6 || len(snap.Tables.Items) != 1 || len(snap.Tables.Entries) != 1 || len(snap.Tables.Flags) != 1 {
		t.Errorf("snapshot %+v", snap)
	}
	// export downloads as a zip; a member of nothing gets 404
	zipRaw, ctype, err := c.Download(ctx, "/api/v1/h/"+hh.ID+"/export")
	if err != nil || ctype != "application/zip" || !bytes.HasPrefix(zipRaw, []byte("PK")) {
		t.Errorf("export: %v %q", err, ctype)
	}
	_, _, err = c.Download(ctx, "/api/v1/h/nope/export")
	if !asProblem(err, &p) || p.Status != http.StatusNotFound {
		t.Errorf("foreign export: %v", err)
	}
	// readyz is fine right after start
	resp2, err := srv.Client().Get(srv.URL + "/readyz")
	if err != nil || resp2.StatusCode != http.StatusOK {
		t.Errorf("readyz: %v %v", err, resp2)
	}
	if resp2 != nil {
		_ = resp2.Body.Close()
	}
}

func asProblem(err error, p **client.Problem) bool {
	var cp *client.Problem
	if err == nil {
		return false
	}
	if pp, ok := err.(*client.Problem); ok { //nolint:errorlint // the client returns it unwrapped
		cp = pp
	}
	*p = cp
	return cp != nil
}
