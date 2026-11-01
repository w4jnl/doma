package fold

import (
	"encoding/json"
	"slices"
	"sort"
	"strings"

	"github.com/w4jnl/doma/internal/domain"
)

// MemStore is an in-memory Store for the fixture and property tests. It
// keeps the log it was given, as the SQL store reads the events table.
type MemStore struct {
	Log     []Event
	items   map[string]Item
	aliases map[string]Alias // by norm
	lists   map[string]List
	entries map[string]Entry
	flags   map[[2]string]Flag
	staples map[[2]string]Staple
	homes   map[string]Home
	spots   map[string]Spot
	photos  map[string]Photo
	trips   map[string]Trip
}

// NewMemStore returns an empty store.
func NewMemStore() *MemStore {
	return &MemStore{
		items: map[string]Item{}, aliases: map[string]Alias{}, lists: map[string]List{}, entries: map[string]Entry{},
		flags: map[[2]string]Flag{}, staples: map[[2]string]Staple{}, homes: map[string]Home{}, spots: map[string]Spot{},
		photos: map[string]Photo{}, trips: map[string]Trip{},
	}
}

// Append adds e to the log and folds it, skipping an id seen before.
func (m *MemStore) Append(e Event) error {
	for _, have := range m.Log {
		if have.ID == e.ID {
			return nil
		}
	}
	m.Log = append(m.Log, e)
	return Apply(m, e)
}

func (m *MemStore) Item(id string) (*Item, error) {
	if it, ok := m.items[id]; ok {
		return &it, nil
	}
	return nil, nil
}

func (m *MemStore) Items() ([]Item, error) {
	out := make([]Item, 0, len(m.items))
	for _, it := range m.items {
		out = append(out, it)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (m *MemStore) PutItem(it Item) error { m.items[it.ID] = it; return nil }

func (m *MemStore) ReplaceAliases(all []Alias) error {
	m.aliases = map[string]Alias{}
	for _, a := range all {
		m.aliases[a.NormName] = a
	}
	return nil
}

func (m *MemStore) MergedIDs(id string) ([]string, error) {
	out := []string{id}
	for i := 0; i < len(out); i++ {
		for _, it := range m.items {
			if it.MergedInto != nil && *it.MergedInto == out[i] && !slices.Contains(out, it.ID) {
				out = append(out, it.ID)
			}
		}
	}
	sort.Strings(out[1:])
	return out, nil
}

func (m *MemStore) ItemEvents() ([]Event, error) {
	var out []Event
	for _, ev := range m.Log {
		if strings.HasPrefix(ev.Kind, "item.") {
			out = append(out, ev)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].HLC.Less(out[j].HLC) })
	return out, nil
}

func (m *MemStore) ItemEventsFor(itemIDs []string) ([]Event, error) {
	var out []Event
	for _, ev := range m.Log {
		var p struct {
			ItemID string   `json:"item_id"`
			Moved  []string `json:"moved"`
		}
		if err := json.Unmarshal(ev.Payload, &p); err != nil {
			continue
		}
		switch ev.Kind {
		case "flag.set", "staple.added", "staple.removed":
			if slices.Contains(itemIDs, p.ItemID) {
				out = append(out, ev)
			}
		case "trip.arrived":
			for _, id := range p.Moved {
				if slices.Contains(itemIDs, id) {
					out = append(out, ev)
					break
				}
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].HLC.Less(out[j].HLC) })
	return out, nil
}

func (m *MemStore) RecountItemUsage(id string) error {
	it, ok := m.items[id]
	if !ok {
		return nil
	}
	var n int64
	var last *int64
	for _, e := range m.entries {
		if e.ItemID == id {
			n++
			if last == nil || *last < e.AddedHLC.Wall {
				last = ptr(e.AddedHLC.Wall)
			}
		}
	}
	it.UseCount, it.LastUsedAt = n, last
	m.items[id] = it
	return nil
}

func (m *MemStore) List(id string) (*List, error) {
	if l, ok := m.lists[id]; ok {
		return &l, nil
	}
	return nil, nil
}

func (m *MemStore) PutList(l List) error { m.lists[l.ID] = l; return nil }

func (m *MemStore) DefaultListID() (string, error) {
	ids := make([]string, 0, 1)
	for _, l := range m.lists {
		if l.IsDefault {
			ids = append(ids, l.ID)
		}
	}
	sort.Strings(ids)
	if len(ids) == 0 {
		return "", nil
	}
	return ids[0], nil
}

func (m *MemStore) EntryEvents(listID string, itemIDs []string, isDefault bool) ([]Event, error) {
	var out []Event
	match := func(id string) bool { return itemIDs == nil || slices.Contains(itemIDs, id) }
	for _, ev := range m.Log {
		var p struct {
			ListID string   `json:"list_id"`
			ItemID string   `json:"item_id"`
			State  string   `json:"state"`
			Moved  []string `json:"moved"`
		}
		if err := json.Unmarshal(ev.Payload, &p); err != nil {
			continue
		}
		switch ev.Kind {
		case "entry.added", "entry.edited", "entry.checked", "entry.unchecked", "entry.moved":
			if p.ListID == listID && match(p.ItemID) {
				out = append(out, ev)
			}
		case "entry.cleared":
			if p.ListID == listID {
				out = append(out, ev)
			}
		case "flag.set":
			if isDefault && p.State == "out" && match(p.ItemID) {
				out = append(out, ev)
			}
		case "trip.arrived":
			if isDefault {
				for _, id := range p.Moved {
					if match(id) {
						out = append(out, ev)
						break
					}
				}
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].HLC.Less(out[j].HLC) })
	return out, nil
}

func (m *MemStore) EntryListIDs(itemIDs []string) ([]string, error) {
	seen := map[string]bool{}
	var out []string
	for _, ev := range m.Log {
		if !strings.HasPrefix(ev.Kind, "entry.") {
			continue
		}
		var p struct {
			ListID string `json:"list_id"`
			ItemID string `json:"item_id"`
		}
		if err := json.Unmarshal(ev.Payload, &p); err != nil {
			continue
		}
		if slices.Contains(itemIDs, p.ItemID) && !seen[p.ListID] {
			seen[p.ListID] = true
			out = append(out, p.ListID)
		}
	}
	sort.Strings(out)
	return out, nil
}

func (m *MemStore) Entries(listID string, itemIDs []string) ([]Entry, error) {
	var out []Entry
	for _, e := range m.entries {
		if e.ListID == listID && slices.Contains(itemIDs, e.ItemID) {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (m *MemStore) ClearedEntriesForHome(itemIDs []string, homeID string) ([]Entry, error) {
	var out []Entry
	for _, e := range m.entries {
		if e.ClearedHLC != nil && e.ForHomeID != nil && *e.ForHomeID == homeID && slices.Contains(itemIDs, e.ItemID) {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (m *MemStore) ReplaceEntries(listID string, itemIDs []string, rows []Entry) error {
	for id, e := range m.entries {
		if e.ListID == listID && slices.Contains(itemIDs, e.ItemID) {
			delete(m.entries, id)
		}
	}
	for _, r := range rows {
		m.entries[r.ID] = r
	}
	return nil
}

func (m *MemStore) Flag(homeID, itemID string) (*Flag, error) {
	if f, ok := m.flags[[2]string{homeID, itemID}]; ok {
		return &f, nil
	}
	return nil, nil
}

func (m *MemStore) PutFlag(f Flag) error { m.flags[[2]string{f.HomeID, f.ItemID}] = f; return nil }

func (m *MemStore) DeleteFlag(homeID, itemID string) error {
	delete(m.flags, [2]string{homeID, itemID})
	return nil
}

func (m *MemStore) DeleteFlagsForItems(itemIDs []string) error {
	for k, f := range m.flags {
		if slices.Contains(itemIDs, f.ItemID) {
			delete(m.flags, k)
		}
	}
	return nil
}

func (m *MemStore) Staple(homeID, itemID string) (*Staple, error) {
	if s, ok := m.staples[[2]string{homeID, itemID}]; ok {
		return &s, nil
	}
	return nil, nil
}

func (m *MemStore) PutStaple(s Staple) error {
	m.staples[[2]string{s.HomeID, s.ItemID}] = s
	return nil
}

func (m *MemStore) DeleteStaplesForItems(itemIDs []string) error {
	for k, st := range m.staples {
		if slices.Contains(itemIDs, st.ItemID) {
			delete(m.staples, k)
		}
	}
	return nil
}

func (m *MemStore) Home(id string) (*Home, error) {
	if h, ok := m.homes[id]; ok {
		return &h, nil
	}
	return nil, nil
}

func (m *MemStore) PutHome(h Home) error { m.homes[h.ID] = h; return nil }

func (m *MemStore) Spot(id string) (*Spot, error) {
	if s, ok := m.spots[id]; ok {
		return &s, nil
	}
	return nil, nil
}

func (m *MemStore) PutSpot(s Spot) error { m.spots[s.ID] = s; return nil }

func (m *MemStore) PutPhoto(p Photo) error {
	if _, ok := m.photos[p.ID]; !ok {
		m.photos[p.ID] = p
	}
	return nil
}

func (m *MemStore) PutTrip(t Trip) error {
	if _, ok := m.trips[t.ID]; !ok {
		m.trips[t.ID] = t
	}
	return nil
}

// Tables returns every materialised table, sorted.
func (m *MemStore) Tables() Tables {
	var t Tables
	for _, v := range m.items {
		t.Items = append(t.Items, v)
	}
	for _, v := range m.aliases {
		t.Aliases = append(t.Aliases, v)
	}
	for _, v := range m.lists {
		t.Lists = append(t.Lists, v)
	}
	for _, v := range m.entries {
		t.Entries = append(t.Entries, v)
	}
	for _, v := range m.flags {
		t.Flags = append(t.Flags, v)
	}
	for _, v := range m.staples {
		t.Staples = append(t.Staples, v)
	}
	for _, v := range m.homes {
		t.Homes = append(t.Homes, v)
	}
	for _, v := range m.spots {
		t.Spots = append(t.Spots, v)
	}
	for _, v := range m.photos {
		t.Photos = append(t.Photos, v)
	}
	for _, v := range m.trips {
		t.Trips = append(t.Trips, v)
	}
	t.Sort()
	return t
}

var _ Store = (*MemStore)(nil)
var _ = domain.HLC{}
