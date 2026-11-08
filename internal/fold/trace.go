package fold

import "fmt"

// Traced wraps a store so every write the fold makes is reported to logf
// with the row after the write: the fold trace `doma serve -d` prints.
func Traced(s Store, logf func(format string, args ...any)) Store {
	return &traced{Store: s, logf: logf}
}

type traced struct {
	Store
	logf func(format string, args ...any)
}

func (t *traced) PutItem(it Item) error {
	t.logf("fold item %s name=%q norm=%v merged_into=%v", it.ID, it.Name, deref(it.NormName), deref(it.MergedInto))
	return t.Store.PutItem(it)
}

func (t *traced) ReplaceAliases(all []Alias) error {
	t.logf("fold aliases %d", len(all))
	return t.Store.ReplaceAliases(all)
}

func (t *traced) PutList(l List) error {
	t.logf("fold list %s name=%q default=%v archived=%v", l.ID, l.Name, l.IsDefault, l.ArchivedAt != nil)
	return t.Store.PutList(l)
}

func (t *traced) ReplaceEntries(listID string, itemIDs []string, rows []Entry) error {
	for _, e := range rows {
		t.logf("fold entry %s list=%s item=%s checked=%v cleared=%v qty=%v", e.ID, listID, e.ItemID, e.CheckedHLC != nil, e.ClearedHLC != nil, derefF(e.Qty))
	}
	if len(rows) == 0 {
		t.logf("fold entries list=%s items=%v none", listID, itemIDs)
	}
	return t.Store.ReplaceEntries(listID, itemIDs, rows)
}

func (t *traced) PutFlag(f Flag) error {
	t.logf("fold flag home=%s item=%s %s at %s", f.HomeID, f.ItemID, f.State, f.SetHLC)
	return t.Store.PutFlag(f)
}

func (t *traced) DeleteFlag(homeID, itemID string) error {
	t.logf("fold flag home=%s item=%s gone", homeID, itemID)
	return t.Store.DeleteFlag(homeID, itemID)
}

func (t *traced) PutStaple(s Staple) error {
	t.logf("fold staple home=%s item=%s present=%v", s.HomeID, s.ItemID, s.Present())
	return t.Store.PutStaple(s)
}

func (t *traced) PutHome(h Home) error {
	t.logf("fold home %s name=%q archived=%v", h.ID, h.Name, h.ArchivedAt != nil)
	return t.Store.PutHome(h)
}

func (t *traced) PutSpot(s Spot) error {
	t.logf("fold spot %s home=%s name=%q", s.ID, s.HomeID, s.Name)
	return t.Store.PutSpot(s)
}

func (t *traced) PutPhoto(p Photo) error {
	t.logf("fold photo %s spot=%s", p.ID, p.SpotID)
	return t.Store.PutPhoto(p)
}

func (t *traced) PutTrip(tr Trip) error {
	t.logf("fold trip %s %s->%s", tr.ID, tr.FromHomeID, tr.ToHomeID)
	return t.Store.PutTrip(tr)
}

func (t *traced) PutCard(c Card) error {
	t.logf("fold card %s name=%q format=%s logo=%v archived=%v", c.ID, c.Name, c.Format, deref(c.LogoID), c.ArchivedAt != nil)
	return t.Store.PutCard(c)
}

func deref(s *string) string {
	if s == nil {
		return "-"
	}
	return *s
}

func derefF(f *float64) string {
	if f == nil {
		return "-"
	}
	return fmt.Sprint(*f)
}
