package fold

import (
	"encoding/json"
	"sort"
)

// Tables is a snapshot of every materialised table, the form the fixture
// states its expectations in and the form two stores are compared by.
type Tables struct {
	Items   []Item   `json:"items"`
	Aliases []Alias  `json:"item_aliases"`
	Lists   []List   `json:"lists"`
	Entries []Entry  `json:"entries"`
	Flags   []Flag   `json:"flags"`
	Staples []Staple `json:"staples"`
	Homes   []Home   `json:"homes"`
	Spots   []Spot   `json:"spots"`
	Photos  []Photo  `json:"photos"`
	Trips   []Trip   `json:"trips"`
	// Proposals are what a vision model suggested, open or closed.
	Proposals []Proposal `json:"proposals"`
	// Cards are the family's loyalty cards.
	Cards []Card `json:"cards"`
}

// Sort orders every table by its key.
func (t *Tables) Sort() {
	sort.Slice(t.Items, func(i, j int) bool { return t.Items[i].ID < t.Items[j].ID })
	sort.Slice(t.Aliases, func(i, j int) bool { return t.Aliases[i].NormName < t.Aliases[j].NormName })
	sort.Slice(t.Lists, func(i, j int) bool { return t.Lists[i].ID < t.Lists[j].ID })
	sort.Slice(t.Entries, func(i, j int) bool { return t.Entries[i].ID < t.Entries[j].ID })
	sort.Slice(t.Flags, func(i, j int) bool {
		if t.Flags[i].HomeID != t.Flags[j].HomeID {
			return t.Flags[i].HomeID < t.Flags[j].HomeID
		}
		return t.Flags[i].ItemID < t.Flags[j].ItemID
	})
	sort.Slice(t.Staples, func(i, j int) bool {
		if t.Staples[i].HomeID != t.Staples[j].HomeID {
			return t.Staples[i].HomeID < t.Staples[j].HomeID
		}
		return t.Staples[i].ItemID < t.Staples[j].ItemID
	})
	sort.Slice(t.Homes, func(i, j int) bool { return t.Homes[i].ID < t.Homes[j].ID })
	sort.Slice(t.Spots, func(i, j int) bool { return t.Spots[i].ID < t.Spots[j].ID })
	sort.Slice(t.Photos, func(i, j int) bool { return t.Photos[i].ID < t.Photos[j].ID })
	sort.Slice(t.Trips, func(i, j int) bool { return t.Trips[i].ID < t.Trips[j].ID })
	sort.Slice(t.Proposals, func(i, j int) bool { return t.Proposals[i].ID < t.Proposals[j].ID })
	sort.Slice(t.Cards, func(i, j int) bool { return t.Cards[i].ID < t.Cards[j].ID })
}

// Canonical renders the tables as JSON with every null, empty, zero and
// false field dropped, so a fixture states only what matters and two stores
// compare without caring about pointer-versus-value differences.
func (t Tables) Canonical() ([]byte, error) {
	raw, err := json.Marshal(t)
	if err != nil {
		return nil, err
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, err
	}
	return json.MarshalIndent(prune(v), "", "  ")
}

// CanonicalJSON prunes arbitrary JSON the same way, for the fixture side.
func CanonicalJSON(raw []byte) ([]byte, error) {
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, err
	}
	return json.MarshalIndent(prune(v), "", "  ")
}

func prune(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, val := range x {
			p := prune(val)
			if isZero(p) {
				continue
			}
			out[k] = p
		}
		return out
	case []any:
		out := make([]any, 0, len(x))
		for _, val := range x {
			out = append(out, prune(val))
		}
		return out
	}
	return v
}

func isZero(v any) bool {
	switch x := v.(type) {
	case nil:
		return true
	case string:
		return x == ""
	case float64:
		return x == 0
	case bool:
		return !x
	case map[string]any:
		return len(x) == 0
	case []any:
		return len(x) == 0
	}
	return false
}
