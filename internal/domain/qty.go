package domain

import (
	"regexp"
	"strconv"
	"strings"
)

// Units are the quantity units the parser recognises; anything else stays
// in the note. "×" is read as "x".
var Units = map[string]bool{
	"x": true, "st": true, "stuks": true, "pcs": true,
	"g": true, "kg": true, "ml": true, "cl": true, "l": true,
	"pak": true, "fles": true, "zak": true, "blik": true, "bos": true,
}

// Entry is a typed line split into its parts.
type Entry struct {
	Name string
	// Qty is nil when no quantity was typed.
	Qty  *float64
	Unit string
	Note string
}

var numberRe = regexp.MustCompile(`^(\d+(?:[.,]\d+)?)([^\d\s.,]*)$`)

// ParseEntry splits a typed line: a leading or trailing quantity with an
// optional unit goes into Qty and Unit, a trailing parenthesised text into
// Note, the rest is the item name. "melk 2", "2 melk", "2x melk",
// "500 g gehakt", "1,5 l melk" and "melk (the small jar)" give the item
// melk or gehakt with qty 2 / 2 / 2 / 500 / 1.5 / none and unit x / x / x /
// g / l / none. Nothing typed is lost.
func ParseEntry(text string) Entry {
	var e Entry
	s := strings.TrimSpace(text)
	if i := strings.LastIndex(s, "("); i > 0 && strings.HasSuffix(s, ")") {
		e.Note = strings.TrimSpace(s[i+1 : len(s)-1])
		s = strings.TrimSpace(s[:i])
	}
	toks := strings.Fields(s)
	if n, unit, used, ok := leadingQty(toks); ok {
		e.Qty, e.Unit = &n, unit
		toks = toks[used:]
	} else if n, unit, used, ok := trailingQty(toks); ok {
		e.Qty, e.Unit = &n, unit
		toks = toks[:len(toks)-used]
	}
	e.Name = strings.Join(toks, " ")
	if e.Name == "" && e.Qty != nil {
		// a bare number is a name, not a quantity of nothing
		e.Name = strings.TrimSpace(text)
		e.Qty, e.Unit = nil, ""
	}
	return e
}

func parseNumber(tok string) (float64, string, bool) {
	m := numberRe.FindStringSubmatch(strings.ToLower(tok))
	if m == nil {
		return 0, "", false
	}
	n, err := strconv.ParseFloat(strings.ReplaceAll(m[1], ",", "."), 64)
	if err != nil {
		return 0, "", false
	}
	suffix := m[2]
	if suffix == "×" {
		suffix = "x"
	}
	return n, suffix, true
}

// leadingQty reads "2 melk", "2x melk", "500 g gehakt", "1,5 l melk".
func leadingQty(toks []string) (n float64, unit string, used int, ok bool) {
	if len(toks) < 2 {
		return 0, "", 0, false
	}
	n, suffix, isNum := parseNumber(toks[0])
	if !isNum {
		return 0, "", 0, false
	}
	switch {
	case suffix != "" && Units[suffix]:
		return n, suffix, 1, len(toks) > 1
	case suffix != "":
		return 0, "", 0, false
	}
	if u := unitToken(toks[1]); u != "" && len(toks) > 2 {
		return n, u, 2, true
	}
	return n, "x", 1, true
}

// trailingQty reads "melk 2", "gehakt 500 g", "melk 2x".
func trailingQty(toks []string) (n float64, unit string, used int, ok bool) {
	if len(toks) < 2 {
		return 0, "", 0, false
	}
	last := toks[len(toks)-1]
	if n, suffix, isNum := parseNumber(last); isNum {
		switch {
		case suffix == "":
			return n, "x", 1, true
		case Units[suffix]:
			return n, suffix, 1, true
		}
		return 0, "", 0, false
	}
	if u := unitToken(last); u != "" && len(toks) >= 3 {
		if n, suffix, isNum := parseNumber(toks[len(toks)-2]); isNum && suffix == "" {
			return n, u, 2, true
		}
	}
	return 0, "", 0, false
}

func unitToken(tok string) string {
	t := strings.ToLower(tok)
	if t == "×" {
		t = "x"
	}
	if Units[t] {
		return t
	}
	return ""
}
