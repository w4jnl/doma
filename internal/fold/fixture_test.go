package fold_test

import (
	"math/rand/v2"
	"strings"
	"testing"

	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/fold/foldtest"
)

func fold1(t testing.TB, events []fold.Event) fold.Tables {
	t.Helper()
	m := fold.NewMemStore()
	for _, e := range events {
		if err := m.Append(e); err != nil {
			t.Fatalf("apply %s %s: %v", e.Kind, e.ID, err)
		}
	}
	return m.Tables()
}

// TestFixture folds every case in its own order and in every other order.
func TestFixture(t *testing.T) {
	f := foldtest.Load(t)
	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			want := foldtest.Expected(t, c.Expect)
			got := foldtest.Canonical(t, fold1(t, c.Events))
			if got != want {
				t.Fatalf("in the fixture's order:\n got %s\nwant %s", got, want)
			}
			rnd := rand.New(rand.NewPCG(1, 2))
			for _, order := range foldtest.Orders(len(c.Events), 40, rnd) {
				events := foldtest.Shuffle(c.Events, order)
				if got := foldtest.Canonical(t, fold1(t, events)); got != want {
					var ids []string
					for _, e := range events {
						ids = append(ids, e.ID)
					}
					t.Fatalf("order %s:\n got %s\nwant %s", strings.Join(ids, " "), got, want)
				}
			}
		})
	}
}

func TestEveryKindIsInTheFixture(t *testing.T) {
	f := foldtest.Load(t)
	seen := map[string]bool{}
	for _, c := range f.Cases {
		for _, e := range c.Events {
			seen[e.Kind] = true
		}
	}
	for _, k := range fold.Kinds {
		if k == "member.removed" || k == "device.revoked" {
			continue // server-originated, no fold rule
		}
		if !seen[k] {
			t.Errorf("fold.json has no case with %s", k)
		}
	}
}

func TestBadPayloadIsAnError(t *testing.T) {
	m := fold.NewMemStore()
	err := m.Append(fold.Event{ID: "x", PersonID: "pa", Kind: "entry.added", Payload: []byte(`{"list_id": "L1"}`)})
	if err == nil {
		t.Fatal("an entry without an item must be refused")
	}
	err = m.Append(fold.Event{ID: "y", PersonID: "pa", Kind: "flag.set", Payload: []byte(`{"home_id": "H1", "item_id": "I1", "state": "gone"}`)})
	if err == nil {
		t.Fatal("an unknown flag state must be refused")
	}
}
