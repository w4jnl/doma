package domain

import "testing"

func TestNormName(t *testing.T) {
	for in, want := range map[string]string{"  Olijfolie ": "olijfolie", "Crème  Fraîche": "creme fraiche", "MELK halfvol": "melk halfvol", "Žltý melón": "zlty melon", "": ""} {
		if got := NormName(in); got != want {
			t.Errorf("NormName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseEntry(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	cases := []struct {
		in   string
		name string
		qty  *float64
		unit string
		note string
	}{
		{"melk 2", "melk", f(2), "x", ""},
		{"2 melk", "melk", f(2), "x", ""},
		{"2x melk", "melk", f(2), "x", ""},
		{"2× melk", "melk", f(2), "x", ""},
		{"500 g gehakt", "gehakt", f(500), "g", ""},
		{"1,5 l melk", "melk", f(1.5), "l", ""},
		{"melk (the small jar)", "melk", nil, "", "the small jar"},
		{"melk", "melk", nil, "", ""},
		{"gehakt 500 g", "gehakt", f(500), "g", ""},
		{"eieren 12 (vrije uitloop)", "eieren", f(12), "x", "vrije uitloop"},
		{"3d printer filament", "3d printer filament", nil, "", ""},
		{"2 liter melk", "liter melk", f(2), "x", ""},
		{"melk 2 liter", "melk 2 liter", nil, "", ""},
		{"42", "42", nil, "", ""},
		{"  ", "", nil, "", ""},
		{"2 pak koffie", "koffie", f(2), "pak", ""},
		{"koffie 2kg", "koffie", f(2), "kg", ""},
	}
	for _, c := range cases {
		got := ParseEntry(c.in)
		if got.Name != c.name || got.Unit != c.unit || got.Note != c.note || (got.Qty == nil) != (c.qty == nil) || (got.Qty != nil && *got.Qty != *c.qty) {
			t.Errorf("ParseEntry(%q) = %+v (qty %v), want name %q qty %v unit %q note %q", c.in, got, deref(got.Qty), c.name, deref(c.qty), c.unit, c.note)
		}
	}
}

func deref(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}

func TestRole(t *testing.T) {
	if !RoleOwner.AtLeast(RoleMember) || RoleGuest.AtLeast(RoleMember) || !RoleMember.AtLeast(RoleMember) || Role("admin").Valid() {
		t.Error("role ranks")
	}
}
