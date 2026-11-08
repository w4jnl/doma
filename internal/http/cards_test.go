package http_test

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

// A card's logo: stored once per picture, announced with a card.logo the
// sync filter keeps with the card's person, served to members by its id,
// and kept by the nightly sweep while a stray file goes.

func pngBytes(t *testing.T, shade uint8) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for x := range 8 {
		for y := range 8 {
			img.Set(x, y, color.RGBA{shade, uint8(x * 30), uint8(y * 30), 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestCardLogos(t *testing.T) {
	s := newSuite(t)
	ctx := context.Background()
	clock, _ := domain.NewClock("m", nil)
	mine, ours := domain.NewID(), domain.NewID()
	var resp service.SyncResponse
	err := s.a.member.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id, Events: []json.RawMessage{
		event(clock, "card.added", map[string]any{"card_id": mine, "owner_person_id": s.a.member.PersonID, "name": "Bieb", "format": "code128", "value": "LIB-42"}),
		event(clock, "card.added", map[string]any{"card_id": ours, "name": "AH", "format": "ean13", "value": "2620000000006", "domain": "ah.nl"}),
	}}}}, &resp)
	if err != nil || len(resp.Households[0].Accepted) != 2 {
		t.Fatalf("cards: %v %+v", err, resp)
	}
	card, err := s.svc.CardForLogo(ctx, s.a.id, ours)
	if err != nil || card.Domain != "ah.nl" || card.Name != "AH" || card.LogoID != "" {
		t.Fatalf("card for logo: %+v %v", card, err)
	}
	oursLogo, err := s.svc.StoreLogo(ctx, s.a.id, ours, pngBytes(t, 10))
	if err != nil {
		t.Fatal(err)
	}
	mineLogo, err := s.svc.StoreLogo(ctx, s.a.id, mine, pngBytes(t, 20))
	if err != nil {
		t.Fatal(err)
	}
	again, err := s.svc.StoreLogo(ctx, s.a.id, ours, pngBytes(t, 10))
	if err != nil || again != oursLogo {
		t.Errorf("the same picture again: %q %v, want %q", again, err, oursLogo)
	}
	// the owner learns of the household card's logo and never of the member's
	if err := s.a.owner.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: s.a.id}}}, &resp); err != nil {
		t.Fatal(err)
	}
	var logos []string
	for _, e := range resp.Households[0].Events {
		if e.Kind == "card.logo" {
			logos = append(logos, string(e.Payload))
		}
	}
	if len(logos) != 1 || !strings.Contains(logos[0], oursLogo) || strings.Contains(strings.Join(logos, ""), mine) {
		t.Errorf("the owner's card.logo events: %v", logos)
	}
	// the picture by its id, for a member; another person's card, an old id and a stranger are 404
	body, ctype, err := s.a.owner.Download(ctx, "/cards/v1/"+s.a.id+"/"+ours+"/logo/"+oursLogo)
	if err != nil || ctype != "image/png" || !bytes.Equal(body, pngBytes(t, 10)) {
		t.Errorf("the household card's logo: %v %q %d bytes", err, ctype, len(body))
	}
	if _, _, err := s.a.member.Download(ctx, "/cards/v1/"+s.a.id+"/"+mine+"/logo/"+mineLogo); err != nil {
		t.Errorf("the member's own logo: %v", err)
	}
	for name, path := range map[string]string{
		"another person's card": "/cards/v1/" + s.a.id + "/" + mine + "/logo/" + mineLogo,
		"an old id":             "/cards/v1/" + s.a.id + "/" + ours + "/logo/0123456789abcdef",
		"a bad id":              "/cards/v1/" + s.a.id + "/" + ours + "/logo/../../x",
		"another household":     "/cards/v1/" + s.b.id + "/" + ours + "/logo/" + oursLogo,
	} {
		if _, _, err := s.a.owner.Download(ctx, path); err == nil || !strings.Contains(err.Error(), "404") {
			t.Errorf("%s: %v, want 404", name, err)
		}
	}
	// a new picture replaces the old file and its id
	fresh, err := s.svc.StoreLogo(ctx, s.a.id, ours, pngBytes(t, 30))
	if err != nil || fresh == oursLogo {
		t.Fatalf("a new picture: %q %v", fresh, err)
	}
	dir := filepath.Join(s.photos, s.a.id, "cards")
	if _, err := os.Stat(filepath.Join(dir, ours+"-"+oursLogo+".png")); !os.IsNotExist(err) {
		t.Error("the old logo file stayed")
	}
	// the nightly sweep keeps what the cards table names and takes the rest
	stray := filepath.Join(dir, "stray.png")
	if err := os.WriteFile(stray, pngBytes(t, 1), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.svc.RunSnapshots(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, ours+"-"+fresh+".png")); err != nil {
		t.Errorf("the sweep took the current logo: %v", err)
	}
	if _, err := os.Stat(stray); !os.IsNotExist(err) {
		t.Error("the sweep left a file no card names")
	}
}
