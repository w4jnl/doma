package http_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"testing"

	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/foldsql"
	"github.com/w4jnl/doma/internal/service"
	"github.com/w4jnl/doma/internal/vision"
)

type cannedLooker struct{ seen []vision.Seen }

func (c cannedLooker) Look(context.Context, []byte, string, string, []string) ([]vision.Seen, error) {
	return c.seen, nil
}

// A photo lands, the model says the milk is low, and a proposal reaches the
// phones as a server event; the member declines it and it closes.
func TestVisionProposesFromAStoredPhoto(t *testing.T) {
	s := newSuite(t)
	ctx := context.Background()
	clock, _ := domain.NewClock("a", nil)
	melk, spot, photoID := domain.NewID(), domain.NewID(), domain.NewID()
	if err := s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id, Events: []json.RawMessage{
		event(clock, "item.named", map[string]any{"item_id": melk, "name": "melk"}),
		event(clock, "staple.added", map[string]any{"home_id": s.a.home, "item_id": melk}),
		event(clock, "flag.set", map[string]any{"home_id": s.a.home, "item_id": melk, "state": "have"}),
		event(clock, "spot.created", map[string]any{"spot_id": spot, "home_id": s.a.home, "name": "Fridge"}),
		event(clock, "photo.added", map[string]any{"photo_id": photoID, "spot_id": spot}),
	}}}}, nil); err != nil {
		t.Fatal(err)
	}
	// without a worker the upload is as before
	if err := s.a.owner.Upload(ctx, "/photos/v1/"+s.a.id+"/"+photoID, jpegBytes(t, 64, 64), "image/jpeg", nil); err != nil {
		t.Fatal(err)
	}
	w := vision.New(s.svc, cannedLooker{seen: []vision.Seen{{Name: "Melk", State: "low", Confidence: 0.9}}}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	photo, err := s.svc.PhotoForVision(ctx, s.a.id, photoID)
	if err != nil {
		t.Fatal(err)
	}
	if photo.Spot != "Fridge" || photo.HomeID != s.a.home || len(photo.Staples) != 1 || photo.Staples[0].State != "have" || len(photo.JPEG) == 0 {
		t.Fatalf("photo for vision: %+v", photo)
	}
	if err := w.Handle(ctx, s.a.id, photoID); err != nil {
		t.Fatal(err)
	}
	// the proposal is an event of the server's, which the phones pull
	var res service.SyncResponse
	if err := s.a.member.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id}}}, &res); err != nil {
		t.Fatal(err)
	}
	var proposalID string
	for _, e := range res.Households[0].Events {
		if e.Kind == "flag.proposed" {
			var p struct {
				HomeID  string `json:"home_id"`
				ItemID  string `json:"item_id"`
				State   string `json:"state"`
				PhotoID string `json:"photo_id"`
			}
			raw, _ := json.Marshal(e.Payload)
			_ = json.Unmarshal(raw, &p)
			if e.PersonID != domain.SystemPerson || p.State != "low" || p.PhotoID != photoID || p.ItemID != melk {
				t.Errorf("proposal event: %s %s", e.PersonID, string(raw))
			}
			proposalID = e.ID
		}
	}
	if proposalID == "" {
		t.Fatal("no flag.proposed among the events")
	}
	tables, err := foldsql.New(ctx, s.svc.DB().Read(), s.a.id).Tables()
	if err != nil {
		t.Fatal(err)
	}
	if len(tables.Proposals) != 1 || !tables.Proposals[0].Open() || tables.Proposals[0].State != "low" {
		t.Fatalf("proposals: %+v", tables.Proposals)
	}
	// the member declines; the row closes and the flag stands
	if err := s.a.member.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id, Events: []json.RawMessage{
		event(clock, "proposal.declined", map[string]any{"proposal_id": proposalID, "home_id": s.a.home, "item_id": melk}),
	}}}}, nil); err != nil {
		t.Fatal(err)
	}
	tables, _ = foldsql.New(ctx, s.svc.DB().Read(), s.a.id).Tables()
	if len(tables.Proposals) != 1 || tables.Proposals[0].Open() {
		t.Errorf("after the decline: %+v", tables.Proposals)
	}
	for _, f := range tables.Flags {
		if f.ItemID == melk && f.State != "have" {
			t.Errorf("the flag moved on a decline: %+v", f)
		}
	}
	// the other household sees none of it
	var other service.SyncResponse
	if err := s.b.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.b.id}}}, &other); err != nil {
		t.Fatal(err)
	}
	for _, e := range other.Households[0].Events {
		if e.Kind == "flag.proposed" {
			t.Errorf("household B got a proposal")
		}
	}
	_ = http.StatusOK
}
