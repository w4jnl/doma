// Package foldtest holds what the fold's tests share with the SQL store's:
// the fixture, the canonical rendering of an expectation, and a generator
// of plausible household timelines.
package foldtest

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"testing"

	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
)

// Fixture is docs/fixtures/fold.json.
type Fixture struct {
	Cases []Case `json:"cases"`
}

// Case is one named sequence and the tables it folds to.
type Case struct {
	Name   string          `json:"name"`
	Events []fold.Event    `json:"events"`
	Expect json.RawMessage `json:"expect"`
}

// Tables are the materialised tables a snapshot holds, in fixture order.
var Tables = []string{"items", "item_aliases", "lists", "entries", "flags", "staples", "homes", "spots", "photos", "trips"}

// Path is the fixture's path, found from this file.
func Path() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "docs", "fixtures", "fold.json")
}

// Load reads the fixture.
func Load(t testing.TB) Fixture {
	t.Helper()
	raw, err := os.ReadFile(Path())
	if err != nil {
		t.Fatal(err)
	}
	var f Fixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("fold.json: %v", err)
	}
	if len(f.Cases) == 0 {
		t.Fatal("fold.json has no cases")
	}
	return f
}

var shortHLC = regexp.MustCompile(`^\d+:\d+:[^:]+$`)

// Expected renders a case's expectation the way Tables.Canonical renders a
// store: short stamps padded, missing tables empty, zero fields dropped.
func Expected(t testing.TB, raw json.RawMessage) string {
	t.Helper()
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	full, ok := padHLC(v).(map[string]any)
	if !ok {
		t.Fatal("expect is not an object")
	}
	for _, table := range Tables {
		if _, ok := full[table]; !ok {
			full[table] = []any{}
		}
	}
	filled, err := json.Marshal(full)
	if err != nil {
		t.Fatal(err)
	}
	out, err := fold.CanonicalJSON(filled)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func padHLC(v any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, val := range x {
			x[k] = padHLC(val)
		}
		return x
	case []any:
		for i, val := range x {
			x[i] = padHLC(val)
		}
		return x
	case string:
		if shortHLC.MatchString(x) {
			if h, err := domain.ParseHLC(x); err == nil {
				return h.String()
			}
		}
	}
	return v
}

// Canonical renders tables for comparison.
func Canonical(t testing.TB, tables fold.Tables) string {
	t.Helper()
	out, err := tables.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

// Shuffle returns events in the order perm gives.
func Shuffle(events []fold.Event, perm []int) []fold.Event {
	out := make([]fold.Event, len(perm))
	for i, j := range perm {
		out[i] = events[j]
	}
	return out
}

// Orders yields every permutation of n up to seven, and otherwise the
// identity, the reverse and shuffles random orders.
func Orders(n, shuffles int, rnd *rand.Rand) [][]int {
	identity := make([]int, n)
	for i := range identity {
		identity[i] = i
	}
	if n <= 7 {
		var out [][]int
		var permute func(k int)
		permute = func(k int) {
			if k == n {
				out = append(out, append([]int(nil), identity...))
				return
			}
			for i := k; i < n; i++ {
				identity[k], identity[i] = identity[i], identity[k]
				permute(k + 1)
				identity[k], identity[i] = identity[i], identity[k]
			}
		}
		permute(0)
		return out
	}
	out := [][]int{append([]int(nil), identity...)}
	rev := make([]int, n)
	for i := range rev {
		rev[i] = n - 1 - i
	}
	out = append(out, rev)
	for range shuffles {
		out = append(out, rnd.Perm(n))
	}
	return out
}

var (
	names   = []string{"melk", "Melk", "brood", "olijfolie", "olive oil", "koffie", "eieren"}
	itemIDs = []string{"I1", "I2", "I3", "I4"}
	listIDs = []string{"L1", "L2"}
	homeIDs = []string{"H1", "H2"}
	persons = []string{"pa", "pb"}
)

// Generate builds n events in a timeline where each device's stamps
// increase, with the kinds a family produces, including the awkward ones:
// namesakes, renames into existing names, merges, re-adds after clears,
// out flags and trips.
func Generate(rnd *rand.Rand, n int) []fold.Event {
	wall := int64(1000)
	stamp := func(dev int) domain.HLC {
		wall += int64(rnd.IntN(50) + 1)
		return domain.HLC{Wall: wall, Device: string(rune('a' + dev))}
	}
	var out []fold.Event
	created := map[string]bool{}
	add := func(dev int, kind string, payload map[string]any) {
		if kind == "list.created" {
			id, _ := payload["list_id"].(string)
			if created[id] {
				return
			}
			created[id] = true
		}
		raw, _ := json.Marshal(payload)
		out = append(out, fold.Event{ID: fmt.Sprintf("e%03d", len(out)), PersonID: persons[dev], HLC: stamp(dev), Kind: kind, Payload: raw})
	}
	pick := func(xs []string) string { return xs[rnd.IntN(len(xs))] }
	if rnd.IntN(4) > 0 {
		add(0, "home.created", map[string]any{"home_id": "H1", "name": "Gouda"})
		add(0, "home.created", map[string]any{"home_id": "H2", "name": "Hut"})
		add(0, "list.created", map[string]any{"list_id": "L1", "name": "Boodschappen", "default": true})
	}
	for len(out) < n {
		dev := rnd.IntN(2)
		switch rnd.IntN(21) {
		case 0, 1, 2:
			add(dev, "item.named", map[string]any{"item_id": pick(itemIDs), "name": pick(names)})
		case 3:
			add(dev, "item.renamed", map[string]any{"item_id": pick(itemIDs), "name": pick(names)})
		case 4:
			add(dev, "item.merged", map[string]any{"keep_id": pick(itemIDs), "drop_id": pick(itemIDs)})
		case 5:
			id := pick(listIDs)
			add(dev, "list.created", map[string]any{"list_id": id, "name": pick([]string{"Weekend", "Hut"}), "default": id == "L1"})
		case 6, 7, 8:
			p := map[string]any{"list_id": pick(listIDs), "item_id": pick(itemIDs)}
			if rnd.IntN(2) == 0 {
				p["qty"] = rnd.IntN(5) + 1
				p["unit"] = pick([]string{"x", "g", "l"})
			}
			if rnd.IntN(3) == 0 {
				p["for_home_id"] = pick(homeIDs)
			}
			add(dev, "entry.added", p)
		case 9, 10:
			add(dev, "entry.checked", map[string]any{"list_id": pick(listIDs), "item_id": pick(itemIDs)})
		case 11:
			add(dev, "entry.unchecked", map[string]any{"list_id": pick(listIDs), "item_id": pick(itemIDs)})
		case 12, 13:
			before := domain.HLC{Wall: wall - int64(rnd.IntN(80)), Device: string(rune('a' + dev))}
			add(dev, "entry.cleared", map[string]any{"list_id": pick(listIDs), "before_hlc": before.String()})
		case 14:
			add(dev, "entry.edited", map[string]any{"list_id": pick(listIDs), "item_id": pick(itemIDs), "qty": rnd.IntN(9) + 1, "unit": "x", "note": "edited"})
		case 15:
			add(dev, "entry.moved", map[string]any{"list_id": pick(listIDs), "item_id": pick(itemIDs), "sort": rnd.IntN(10)})
		case 16:
			add(dev, "flag.set", map[string]any{"home_id": pick(homeIDs), "item_id": pick(itemIDs), "state": pick([]string{"have", "low", "out", "out"})})
		case 17:
			add(dev, pick([]string{"staple.added", "staple.removed"}), map[string]any{"home_id": pick(homeIDs), "item_id": pick(itemIDs)})
		case 18:
			add(dev, "list.renamed", map[string]any{"list_id": pick(listIDs), "name": pick([]string{"Weekend", "Hut", "Cabin"}), "colour": "teal"})
		case 19:
			add(dev, "trip.arrived", map[string]any{"trip_id": fmt.Sprintf("T%d", len(out)), "from_home_id": "H1", "to_home_id": "H2", "moved": []string{pick(itemIDs), pick(itemIDs)}})
		case 20:
			// plans, cancels and arrivals of a few shared trip ids, in any order
			trip := pick([]string{"TA", "TB", "TC"})
			switch pick([]string{"plan", "plan", "cancel", "arrive"}) {
			case "plan":
				add(dev, "trip.planned", map[string]any{"trip_id": trip, "from_home_id": pick(homeIDs), "to_home_id": pick(homeIDs), "date": int64(1_700_000_000_000 + rnd.IntN(30)*86_400_000), "list_id": pick(listIDs)})
			case "cancel":
				add(dev, "trip.cancelled", map[string]any{"trip_id": trip})
			default:
				add(dev, "trip.arrived", map[string]any{"trip_id": trip, "from_home_id": "H1", "to_home_id": "H2", "moved": []string{pick(itemIDs)}})
			}
		}
	}
	return out
}
