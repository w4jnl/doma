package foldsql_test

import (
	"context"
	"math/rand/v2"
	"strings"
	"testing"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/fold/foldtest"
	"github.com/w4jnl/doma/internal/foldsql"
)

const household = "H0USEHOLD"

func open(t *testing.T) *db.DB {
	t.Helper()
	d := dbtest.Open(t)
	_, err := d.Writer.ExecContext(context.Background(), `INSERT INTO households (id, slug, name, timezone, created_at) VALUES (?, 'fam', 'Family', 'Europe/Amsterdam', 0)`, household)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// appendAll appends events one transaction each, as the sync path does.
func appendAll(t *testing.T, d *db.DB, events []fold.Event) {
	t.Helper()
	ctx := context.Background()
	for _, e := range events {
		err := d.Tx(ctx, func(q *db.Queries) error {
			_, _, err := foldsql.New(ctx, q, household).Append(e, "cred", 1)
			return err
		})
		if err != nil {
			t.Fatalf("append %s %s: %v", e.Kind, e.ID, err)
		}
	}
}

func tables(t *testing.T, d *db.DB) string {
	t.Helper()
	tb, err := foldsql.New(context.Background(), d.Read(), household).Tables()
	if err != nil {
		t.Fatal(err)
	}
	return foldtest.Canonical(t, tb)
}

func TestFixtureThroughSQL(t *testing.T) {
	f := foldtest.Load(t)
	rnd := rand.New(rand.NewPCG(3, 4))
	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			want := foldtest.Expected(t, c.Expect)
			orders := [][]int{identity(len(c.Events))}
			for range 4 {
				orders = append(orders, rnd.Perm(len(c.Events)))
			}
			for _, order := range orders {
				d := open(t)
				events := foldtest.Shuffle(c.Events, order)
				appendAll(t, d, events)
				if got := tables(t, d); got != want {
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

func identity(n int) []int {
	out := make([]int, n)
	for i := range out {
		out[i] = i
	}
	return out
}

func TestDuplicateIDIsNotApplied(t *testing.T) {
	d := open(t)
	ctx := context.Background()
	e := fold.Event{ID: "e1", PersonID: "pa", Kind: "home.created", Payload: []byte(`{"home_id": "H1", "name": "Gouda"}`)}
	for i, wantApplied := range []bool{true, false} {
		err := d.Tx(ctx, func(q *db.Queries) error {
			seq, applied, err := foldsql.New(ctx, q, household).Append(e, "cred", 1)
			if applied != wantApplied || (applied && seq != 1) {
				t.Errorf("append %d: seq %d applied %v", i, seq, applied)
			}
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

// TestSQLMatchesMemoryAndRebuilds folds a generated timeline through SQLite
// and through the in-memory store, compares, then wipes the materialised
// tables and folds the log again in seq order: the cache must come back.
func TestSQLMatchesMemoryAndRebuilds(t *testing.T) {
	seeds := 6
	if testing.Short() {
		seeds = 2
	}
	for seed := range seeds {
		rnd := rand.New(rand.NewPCG(uint64(seed), 7))
		events := foldtest.Generate(rnd, 50)
		mem := fold.NewMemStore()
		for _, e := range events {
			if err := mem.Append(e); err != nil {
				t.Fatal(err)
			}
		}
		want := foldtest.Canonical(t, mem.Tables())
		d := open(t)
		appendAll(t, d, events)
		if got := tables(t, d); got != want {
			t.Fatalf("seed %d: SQL and memory differ\n got %s\nwant %s", seed, got, want)
		}
		ctx := context.Background()
		for _, table := range []string{"entries", "flags", "staples", "proposals", "item_aliases", "items", "lists", "homes", "spots", "photos", "trips"} {
			if _, err := d.Writer.ExecContext(ctx, "DELETE FROM "+table+" WHERE household_id = ?", household); err != nil {
				t.Fatal(err)
			}
		}
		if got := tables(t, d); strings.Contains(got, `"id"`) {
			t.Fatalf("tables not empty after wipe: %s", got)
		}
		err := d.Tx(ctx, func(q *db.Queries) error {
			rows, err := q.EventsSince(ctx, db.EventsSinceParams{HouseholdID: household, Seq: 0, Limit: 10000})
			if err != nil {
				return err
			}
			st := foldsql.New(ctx, q, household)
			for _, r := range rows {
				e, err := foldsql.Event(r)
				if err != nil {
					return err
				}
				if err := fold.Apply(st, e); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		if got := tables(t, d); got != want {
			t.Fatalf("seed %d: rebuild from the log differs\n got %s\nwant %s", seed, got, want)
		}
	}
}
