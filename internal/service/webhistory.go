package service

import (
	"context"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
)

// History in a browser, as on the phone: a month's purchases per item, per
// home and per shopper, read from the cleared entries, and All items, where
// the family tidies its catalog. A purchase is a cleared entry of a shopping
// list the person may see; a done task is none.

// WebPurchase is one item's purchases in a month.
type WebPurchase struct {
	ItemID string
	Name   string
	Times  int
	// Totals is the quantities by unit as the family reads them: "3x, 1.5 l".
	Totals string
	LastAt int64
}

// WebCount is a home or a person with how many purchases were theirs.
type WebCount struct {
	Name  string
	Times int
}

// WebHistory is one month. Prev is always there; Next is empty in the month
// that is now.
type WebHistory struct {
	Month  string
	Title  string
	Prev   string
	Next   string
	Total  int
	Items  []WebPurchase
	Homes  []WebCount
	People []WebCount
}

// WebItem is one item of the household's catalog, for All items.
type WebItem struct {
	ID     string
	Name   string
	Times  int
	LastAt int64
}

const monthLayout = "2006-01"

// purchase is a cleared entry the person may count, with its item resolved
// through a merge; ok is false for a task, another person's list or a retired item.
func purchase(e fold.Entry, lists map[string]fold.List, items map[string]fold.Item, personID string) (fold.Item, bool) {
	if e.ClearedHLC == nil {
		return fold.Item{}, false
	}
	l, found := lists[e.ListID]
	if !found || l.Kind == "tasks" || (l.OwnerPersonID != nil && *l.OwnerPersonID != personID) {
		return fold.Item{}, false
	}
	it, found := items[e.ItemID]
	if found && it.MergedInto != nil {
		it, found = items[*it.MergedInto]
	}
	if !found || it.ArchivedAt != nil {
		return fold.Item{}, false
	}
	return it, true
}

func indexed(tables fold.Tables) (map[string]fold.List, map[string]fold.Item) {
	lists := map[string]fold.List{}
	for _, l := range tables.Lists {
		lists[l.ID] = l
	}
	items := map[string]fold.Item{}
	for _, it := range tables.Items {
		items[it.ID] = it
	}
	return lists, items
}

// WebHistory is the month's purchases; an empty month is the latest with a
// purchase, or this one. Months are the household's time zone's.
func (s *Service) WebHistory(ctx context.Context, sc domain.Scope, month string) (*WebHistory, error) {
	if sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	var v WebHistory
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		hh, err := q.GetHousehold(ctx, sc.HouseholdID)
		if err != nil {
			return notFound(err)
		}
		loc, err := time.LoadLocation(hh.Timezone)
		if err != nil {
			loc = time.UTC
		}
		tables, err := foldsql.New(ctx, q, sc.HouseholdID).Tables()
		if err != nil {
			return err
		}
		lists, items := indexed(tables)
		monthOf := func(ms int64) string { return time.UnixMilli(ms).In(loc).Format(monthLayout) }
		now := monthOf(s.nowMs())
		at, err := time.ParseInLocation(monthLayout, month, loc)
		if err != nil {
			// no month asked for, or not a month: the latest with a purchase
			month = now
			latest := ""
			for _, e := range tables.Entries {
				if _, ok := purchase(e, lists, items, sc.PersonID); ok {
					if m := monthOf(e.ClearedHLC.Wall); m > latest {
						latest = m
					}
				}
			}
			if latest != "" {
				month = latest
			}
			at, _ = time.ParseInLocation(monthLayout, month, loc)
		}
		v.Month, v.Title = month, at.Format("January 2006")
		v.Prev = at.AddDate(0, -1, 0).Format(monthLayout)
		if month < now {
			v.Next = at.AddDate(0, 1, 0).Format(monthLayout)
		}
		type sums struct {
			p     WebPurchase
			units []string
			qty   map[string]float64
		}
		byItem := map[string]*sums{}
		homes := map[string]int{}
		people := map[string]int{}
		for _, e := range tables.Entries {
			it, ok := purchase(e, lists, items, sc.PersonID)
			if !ok || monthOf(e.ClearedHLC.Wall) != month {
				continue
			}
			v.Total++
			x := byItem[it.ID]
			if x == nil {
				x = &sums{p: WebPurchase{ItemID: it.ID, Name: it.Name}, qty: map[string]float64{}}
				byItem[it.ID] = x
			}
			x.p.Times++
			if e.ClearedHLC.Wall > x.p.LastAt {
				x.p.LastAt = e.ClearedHLC.Wall
			}
			unit, qty := "x", 1.0
			if e.Unit != nil && *e.Unit != "" {
				unit = *e.Unit
			}
			if e.Qty != nil {
				qty = *e.Qty
			}
			if _, seen := x.qty[unit]; !seen {
				x.units = append(x.units, unit)
			}
			x.qty[unit] += qty
			if e.ForHomeID != nil {
				homes[*e.ForHomeID]++
			}
			if e.CheckedBy != nil {
				people[*e.CheckedBy]++
			}
		}
		for _, x := range byItem {
			sort.Strings(x.units)
			var parts []string
			for _, u := range x.units {
				n := strconv.FormatFloat(x.qty[u], 'f', -1, 64)
				if u == "x" {
					parts = append(parts, n+"x")
				} else {
					parts = append(parts, n+" "+u)
				}
			}
			x.p.Totals = strings.Join(parts, ", ")
			v.Items = append(v.Items, x.p)
		}
		sort.Slice(v.Items, func(i, j int) bool {
			if v.Items[i].Times != v.Items[j].Times {
				return v.Items[i].Times > v.Items[j].Times
			}
			return strings.ToLower(v.Items[i].Name) < strings.ToLower(v.Items[j].Name)
		})
		for _, h := range tables.Homes {
			if n := homes[h.ID]; n > 0 {
				v.Homes = append(v.Homes, WebCount{Name: h.Name, Times: n})
			}
		}
		for id, n := range people {
			name := "You"
			if id != sc.PersonID {
				name = "Someone"
				if p, err := q.GetPerson(ctx, id); err == nil {
					name = p.DisplayName
				}
			}
			v.People = append(v.People, WebCount{Name: name, Times: n})
		}
		byTimes := func(c []WebCount) {
			sort.Slice(c, func(i, j int) bool {
				if c[i].Times != c[j].Times {
					return c[i].Times > c[j].Times
				}
				return c[i].Name < c[j].Name
			})
		}
		byTimes(v.Homes)
		byTimes(v.People)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &v, nil
}

// WebItems is every item the family has that is not retired or merged away,
// by name, the never bought ones too; search narrows it to the names that
// hold the text.
func (s *Service) WebItems(ctx context.Context, sc domain.Scope, search string) ([]WebItem, error) {
	if sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	want := domain.NormName(search)
	var out []WebItem
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		tables, err := foldsql.New(ctx, q, sc.HouseholdID).Tables()
		if err != nil {
			return err
		}
		lists, items := indexed(tables)
		times := map[string]int{}
		last := map[string]int64{}
		for _, e := range tables.Entries {
			if it, ok := purchase(e, lists, items, sc.PersonID); ok {
				times[it.ID]++
				if e.ClearedHLC.Wall > last[it.ID] {
					last[it.ID] = e.ClearedHLC.Wall
				}
			}
		}
		for _, it := range tables.Items {
			if it.ArchivedAt != nil || it.MergedInto != nil {
				continue
			}
			if want != "" && (it.NormName == nil || !strings.Contains(*it.NormName, want)) {
				continue
			}
			out = append(out, WebItem{ID: it.ID, Name: it.Name, Times: times[it.ID], LastAt: last[it.ID]})
		}
		sort.Slice(out, func(i, j int) bool {
			a, b := strings.ToLower(out[i].Name), strings.ToLower(out[j].Name)
			if a != b {
				return a < b
			}
			return out[i].ID < out[j].ID
		})
		return nil
	})
	return out, err
}

// liveItem is an item of the household that is neither retired nor merged away.
func liveItem(ctx context.Context, q *db.Queries, sc domain.Scope, itemID string) (db.Item, error) {
	it, err := q.GetItem(ctx, db.GetItemParams{HouseholdID: sc.HouseholdID, ID: itemID})
	if err != nil {
		return db.Item{}, notFound(err)
	}
	if it.ArchivedAt != nil || it.MergedInto != nil {
		return db.Item{}, domain.ErrNotFound
	}
	return it, nil
}

// WebRenameItem fixes an item's name everywhere it shows.
func (s *Service) WebRenameItem(ctx context.Context, sc domain.Scope, credentialID, itemID, name string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 200 {
		return domain.Invalid("name", "give the item a name")
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		it, err := liveItem(ctx, q, sc, itemID)
		if err != nil {
			return nil, err
		}
		if it.Name == name {
			return nil, nil
		}
		return []fold.Event{s.guestEvent(sc, "item.renamed", map[string]any{"item_id": itemID, "name": name})}, nil
	})
}

// WebMergeItem folds an item into the one of the given name, which must be
// another item of the household; a merge is one way.
func (s *Service) WebMergeItem(ctx context.Context, sc domain.Scope, credentialID, dropID, into string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	norm := domain.NormName(into)
	if norm == "" {
		return domain.Invalid("into", "type the name of the item to keep")
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		if _, err := liveItem(ctx, q, sc, dropID); err != nil {
			return nil, err
		}
		items, err := q.ListItems(ctx, sc.HouseholdID)
		if err != nil {
			return nil, err
		}
		for _, it := range items {
			if it.ID != dropID && it.MergedInto == nil && it.ArchivedAt == nil && it.NormName != nil && *it.NormName == norm {
				return []fold.Event{s.guestEvent(sc, "item.merged", map[string]any{"keep_id": it.ID, "drop_id": dropID})}, nil
			}
		}
		return nil, domain.Invalid("into", "no other item is called that")
	})
}

// WebRetireItem stops an item coming up; its purchases stay, and typing its
// name again in full brings it back.
func (s *Service) WebRetireItem(ctx context.Context, sc domain.Scope, credentialID, itemID string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		if _, err := liveItem(ctx, q, sc, itemID); err != nil {
			return nil, err
		}
		return []fold.Event{s.guestEvent(sc, "item.archived", map[string]any{"item_id": itemID})}, nil
	})
}
