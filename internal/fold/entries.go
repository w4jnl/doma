package fold

import (
	"sort"

	"github.com/w4jnl/doma/internal/domain"
)

type entryPayload struct {
	ListID    string   `json:"list_id"`
	ItemID    string   `json:"item_id"`
	Note      string   `json:"note"`
	Qty       *float64 `json:"qty"`
	Unit      *string  `json:"unit"`
	ForHomeID *string  `json:"for_home_id"`
	Sort      *float64 `json:"sort"`
	BeforeHLC string   `json:"before_hlc"`
}

// applyEntryEvent replays the (list, item) key the event belongs to.
func applyEntryEvent(s Store, e Event) error {
	var p entryPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "list_id", p.ListID); err != nil {
		return err
	}
	if err := need(e, "item_id", p.ItemID); err != nil {
		return err
	}
	item, err := resolveItem(s, p.ItemID)
	if err != nil {
		return err
	}
	return replayEntries(s, p.ListID, item)
}

// applyEntryCleared replays every key of the list that has an open checked
// entry, or whose events the clear could touch. The clear is in the list's
// events, so the replay of each key sees it.
func applyEntryCleared(s Store, e Event) error {
	var p entryPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "list_id", p.ListID); err != nil {
		return err
	}
	if _, err := domain.ParseHLC(p.BeforeHLC); err != nil {
		return need(e, "before_hlc", "")
	}
	items, err := listItemIDs(s, p.ListID, false)
	if err != nil {
		return err
	}
	for _, item := range items {
		if err := replayEntries(s, p.ListID, item); err != nil {
			return err
		}
	}
	return nil
}

// listItemIDs collects the canonical item ids with events on a list, from
// the events the store returns for the list with no item filter; with
// isDefault, the items of out flags and trips as well.
func listItemIDs(s Store, listID string, isDefault bool) ([]string, error) {
	events, err := s.EntryEvents(listID, nil, isDefault)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []string
	add := func(raw string) error {
		if raw == "" {
			return nil
		}
		id, err := resolveItem(s, raw)
		if err != nil {
			return err
		}
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
		return nil
	}
	for _, ev := range events {
		var p struct {
			ItemID string   `json:"item_id"`
			Moved  []string `json:"moved"`
		}
		if err := decode(ev, &p); err != nil {
			continue
		}
		if err := add(p.ItemID); err != nil {
			return nil, err
		}
		for _, id := range p.Moved {
			if err := add(id); err != nil {
				return nil, err
			}
		}
	}
	return out, nil
}

type flagPayload struct {
	HomeID string `json:"home_id"`
	ItemID string `json:"item_id"`
	State  string `json:"state"`
	Note   string `json:"note"`
}

type tripPayload struct {
	TripID     string   `json:"trip_id"`
	FromHomeID string   `json:"from_home_id"`
	ToHomeID   string   `json:"to_home_id"`
	Moved      []string `json:"moved"`
}

// replayEntries derives the rows of one (list, item) key from the key's
// events in stamp order. An era opens with an add (or an out flag or a
// trip on the default list), may be checked and unchecked, and closes when
// a clear sees it checked or a remove takes it off the list; a cleared era is
// a purchase record, a removed one leaves no row, and the next add opens a
// new one either way.
func replayEntries(s Store, listID, itemID string) error {
	l, err := s.List(listID)
	if err != nil {
		return err
	}
	isDefault := l != nil && l.IsDefault
	ids, err := s.MergedIDs(itemID)
	if err != nil {
		return err
	}
	events, err := s.EntryEvents(listID, ids, isDefault)
	if err != nil {
		return err
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].HLC.Less(events[j].HLC) })
	// the homes whose flags the old and the new rows can reach
	homes := map[string]bool{}
	before, err := s.Entries(listID, ids)
	if err != nil {
		return err
	}
	for _, e := range before {
		if e.ForHomeID != nil {
			homes[*e.ForHomeID] = true
		}
	}

	var eras []Entry
	var cur *Entry
	// an era's id is the id of the event that opened it; a trip opens one
	// era per moved item, so those carry the item id as well
	open := func(id string, ev Event, forHome *string) {
		eras = append(eras, Entry{ID: id, ListID: listID, ItemID: itemID, ForHomeID: forHome, Sort: float64(ev.HLC.Wall), AddedHLC: ev.HLC, AddedBy: ev.PersonID})
		cur = &eras[len(eras)-1]
	}
	for _, ev := range events {
		switch ev.Kind {
		case "entry.added":
			var p entryPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			if cur == nil {
				open(ev.ID, ev, nil)
			} else if cur.CheckedHLC != nil {
				cur.CheckedHLC, cur.CheckedBy = nil, nil
			}
			cur.Note, cur.Qty, cur.Unit = p.Note, p.Qty, p.Unit
			if p.ForHomeID != nil {
				cur.ForHomeID = p.ForHomeID
			}
		case "entry.edited":
			if cur == nil {
				continue
			}
			var p entryPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			cur.Note, cur.Qty, cur.Unit = p.Note, p.Qty, p.Unit
		case "entry.checked":
			if cur != nil && cur.CheckedHLC == nil {
				cur.CheckedHLC, cur.CheckedBy = ptr(ev.HLC), ptr(ev.PersonID)
			}
		case "entry.unchecked":
			if cur != nil {
				cur.CheckedHLC, cur.CheckedBy = nil, nil
			}
		case "entry.moved":
			if cur == nil {
				continue
			}
			var p entryPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			if p.Sort != nil {
				cur.Sort = *p.Sort
			}
		case "entry.cleared":
			if cur == nil || cur.CheckedHLC == nil {
				continue
			}
			var p entryPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			before, err := domain.ParseHLC(p.BeforeHLC)
			if err != nil {
				continue
			}
			if cur.CheckedHLC.Less(before) {
				cur.ClearedHLC = ptr(ev.HLC)
				cur = nil
			}
		case "entry.removed":
			// not needed after all: the era goes without a record; a remove older
			// than the add that opened the era has nothing to take
			if cur != nil {
				eras = eras[:len(eras)-1]
				cur = nil
			}
		case "flag.set":
			if !isDefault || cur != nil {
				continue
			}
			var p flagPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			if p.State == "out" {
				open(ev.ID, ev, ptr(p.HomeID))
			}
		case "trip.arrived":
			if !isDefault || cur != nil {
				continue
			}
			var p tripPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			open(ev.ID+":"+itemID, ev, ptr(p.FromHomeID))
		}
	}
	if err := s.ReplaceEntries(listID, ids, eras); err != nil {
		return err
	}
	for _, id := range ids {
		if err := s.RecountItemUsage(id); err != nil {
			return err
		}
	}
	// clearing an entry that was for a home means it is there now: the
	// flags of the homes involved are derived again from everything
	for _, era := range eras {
		if era.ForHomeID != nil {
			homes[*era.ForHomeID] = true
		}
	}
	for _, h := range sortedKeys(homes) {
		if err := recomputeFlag(s, h, itemID); err != nil {
			return err
		}
	}
	return nil
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func cleanedBy(e Entry) string {
	if e.CheckedBy != nil {
		return *e.CheckedBy
	}
	return e.AddedBy
}
