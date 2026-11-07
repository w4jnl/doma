package fold

import (
	"sort"

	"github.com/w4jnl/doma/internal/domain"
)

type itemPayload struct {
	ItemID string `json:"item_id"`
	Name   string `json:"name"`
	KeepID string `json:"keep_id"`
	DropID string `json:"drop_id"`
}

// catItem is one item while the catalog is replayed.
type catItem struct {
	id, name, norm, mergedInto string
	created, updated           domain.HLC
}

// catalog replays item events in stamp order with the sequential rules.
type catalog struct {
	items   map[string]*catItem
	aliases map[string]string // norm -> owner id
}

func (c *catalog) resolve(id string) string {
	for n := 0; n < 64; n++ {
		it := c.items[id]
		if it == nil || it.mergedInto == "" {
			return id
		}
		id = it.mergedInto
	}
	return id
}

// ownerOf returns the item that owns norm, by name or alias, or "".
func (c *catalog) ownerOf(norm string) string {
	for _, it := range c.items {
		if it.mergedInto == "" && it.norm == norm {
			return it.id
		}
	}
	if id, ok := c.aliases[norm]; ok {
		return c.resolve(id)
	}
	return ""
}

func (c *catalog) named(id, name string, h domain.HLC) {
	if _, ok := c.items[id]; ok {
		c.renamed(id, name, h)
		return
	}
	norm := domain.NormName(name)
	it := &catItem{id: id, name: name, created: h, updated: h}
	if owner := c.ownerOf(norm); owner != "" {
		// two phones typed the same thing: one item, the newcomer an alias id
		it.mergedInto = owner
	} else {
		it.norm = norm
	}
	c.items[id] = it
}

func (c *catalog) renamed(id, name string, h domain.HLC) {
	owner := c.resolve(id)
	it := c.items[owner]
	if it == nil {
		c.named(id, name, h)
		return
	}
	norm := domain.NormName(name)
	if other := c.ownerOf(norm); other != "" && other != owner {
		// renamed into a name another item has: they are one item now; the
		// old name is not kept as an alias, only an explicit merge does that
		if raw := c.items[id]; raw != nil {
			raw.name, raw.updated = name, h
		}
		c.mergeInto(other, owner, false)
		return
	}
	if c.aliases[norm] == owner || c.resolve(c.aliases[norm]) == owner {
		delete(c.aliases, norm)
	}
	it.name, it.norm, it.updated = name, norm, h
}

func (c *catalog) merged(keep, drop string) {
	k, d := c.resolve(keep), c.resolve(drop)
	if k == d || c.items[k] == nil || c.items[d] == nil {
		return
	}
	c.mergeInto(k, d, true)
}

// mergeInto makes drop part of keep: drop's name becomes an alias of keep
// when alias is set, drop's aliases move to keep, items merged into drop
// now point at keep.
func (c *catalog) mergeInto(keep, drop string, alias bool) {
	d := c.items[drop]
	if alias && d.norm != "" && c.items[keep].norm != d.norm {
		c.aliases[d.norm] = keep
	}
	for norm, id := range c.aliases {
		if id == drop {
			c.aliases[norm] = keep
		}
	}
	d.norm, d.mergedInto = "", keep
	for _, it := range c.items {
		if it.mergedInto == drop {
			it.mergedInto = keep
		}
	}
}

// replayCatalog derives items and aliases from every item event, writes
// the rows that changed, and re-derives the flags, staples and entries of
// every item whose owner changed.
func replayCatalog(s Store) error {
	events, err := s.ItemEvents()
	if err != nil {
		return err
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].HLC.Less(events[j].HLC) })
	c := &catalog{items: map[string]*catItem{}, aliases: map[string]string{}}
	for _, ev := range events {
		var p itemPayload
		if err := decode(ev, &p); err != nil {
			return err
		}
		switch ev.Kind {
		case "item.named":
			if p.ItemID == "" || domain.NormName(p.Name) == "" {
				return need(ev, "item_id and name", "")
			}
			c.named(p.ItemID, p.Name, ev.HLC)
		case "item.renamed":
			if p.ItemID == "" || domain.NormName(p.Name) == "" {
				return need(ev, "item_id and name", "")
			}
			c.renamed(p.ItemID, p.Name, ev.HLC)
		case "item.merged":
			if p.KeepID == "" || p.DropID == "" {
				return need(ev, "keep_id and drop_id", "")
			}
			c.merged(p.KeepID, p.DropID)
		}
	}

	old, err := s.Items()
	if err != nil {
		return err
	}
	oldRows := make(map[string]Item, len(old))
	for _, it := range old {
		oldRows[it.ID] = it
	}
	oldOwner := func(id string) string {
		for n := 0; n < 64; n++ {
			it, ok := oldRows[id]
			if !ok || it.MergedInto == nil {
				return id
			}
			id = *it.MergedInto
		}
		return id
	}
	// write the rows, keeping what item events do not decide; rows that
	// give up a name go first, so the unique index on norm_name never sees
	// two owners while a name changes hands
	changed := map[string]bool{}
	ids := make([]string, 0, len(c.items))
	for id := range c.items {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var later []Item
	for _, id := range ids {
		ci := c.items[id]
		row := Item{ID: ci.id, Name: ci.name, CreatedHLC: ci.created, UpdatedHLC: ci.updated}
		if ci.norm != "" {
			row.NormName = ptr(ci.norm)
		}
		if ci.mergedInto != "" {
			row.MergedInto = ptr(ci.mergedInto)
		}
		prev, had := oldRows[ci.id]
		if had {
			row.Category, row.LastUsedAt, row.UseCount, row.ArchivedAt = prev.Category, prev.LastUsedAt, prev.UseCount, prev.ArchivedAt
		}
		if !had || oldOwner(ci.id) != c.resolve(ci.id) {
			changed[c.resolve(ci.id)] = true
			changed[oldOwner(ci.id)] = true
		}
		if had && sameItem(prev, row) {
			continue
		}
		if had && prev.NormName != nil && !eqPtr(prev.NormName, row.NormName) {
			if err := s.PutItem(row); err != nil {
				return err
			}
			continue
		}
		later = append(later, row)
	}
	for _, row := range later {
		if err := s.PutItem(row); err != nil {
			return err
		}
	}
	aliases := make([]Alias, 0, len(c.aliases))
	for norm, id := range c.aliases {
		aliases = append(aliases, Alias{ItemID: id, NormName: norm})
	}
	sort.Slice(aliases, func(i, j int) bool { return aliases[i].NormName < aliases[j].NormName })
	if err := s.ReplaceAliases(aliases); err != nil {
		return err
	}
	owners := make([]string, 0, len(changed))
	for id := range changed {
		if c.resolve(id) == id {
			owners = append(owners, id)
		}
	}
	sort.Strings(owners)
	for _, id := range owners {
		if err := rederiveItem(s, id); err != nil {
			return err
		}
	}
	// an entry that changed hands between two of these items was counted
	// for the one re-derived first while it still held it; count again now
	// that every row is where it belongs
	for _, id := range owners {
		if err := s.RecountItemUsage(id); err != nil {
			return err
		}
	}
	return nil
}

func sameItem(a, b Item) bool {
	return a.Name == b.Name && eqPtr(a.NormName, b.NormName) && eqPtr(a.MergedInto, b.MergedInto) &&
		a.CreatedHLC == b.CreatedHLC && a.UpdatedHLC == b.UpdatedHLC
}

func eqPtr(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// rederiveItem rebuilds, from the log, everything stored under an item and
// the ids merged into it: staples from their events, the entries of every
// list that names the item, and the flags of every home those touch.
func rederiveItem(s Store, itemID string) error {
	ids, err := s.MergedIDs(itemID)
	if err != nil {
		return err
	}
	if err := s.DeleteProposalsForItems(ids); err != nil {
		return err
	}
	if err := s.DeleteFlagsForItems(ids); err != nil {
		return err
	}
	if err := s.DeleteStaplesForItems(ids); err != nil {
		return err
	}
	events, err := s.ItemEventsFor(ids)
	if err != nil {
		return err
	}
	homes := map[string]bool{}
	for _, ev := range events {
		switch ev.Kind {
		case "flag.set":
			var p flagPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			homes[p.HomeID] = true
		case "flag.proposed", "proposal.declined":
			var p proposalPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			homes[p.HomeID] = true
		case "staple.added", "staple.removed":
			var p staplePayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			if err := putStaple(s, ev, p, itemID); err != nil {
				return err
			}
		case "trip.arrived":
			var p tripPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			homes[p.FromHomeID] = true
			homes[p.ToHomeID] = true
		}
	}
	lists, err := s.EntryListIDs(ids)
	if err != nil {
		return err
	}
	def, err := s.DefaultListID()
	if err != nil {
		return err
	}
	if def != "" {
		lists = append(lists, def)
	}
	seen := map[string]bool{}
	for _, l := range lists {
		if seen[l] {
			continue
		}
		seen[l] = true
		if err := replayEntries(s, l, itemID); err != nil {
			return err
		}
	}
	for _, h := range sortedKeys(homes) {
		if err := recomputeFlag(s, h, itemID); err != nil {
			return err
		}
	}
	for _, id := range ids {
		if err := s.RecountItemUsage(id); err != nil {
			return err
		}
	}
	return nil
}
