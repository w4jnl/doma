package domain

import (
	"strings"
	"unicode"

	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"
)

var stripMarks = transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC)

// NormName is the catalog key of an item name: lowercased, diacritics
// stripped, whitespace collapsed. "Olijfolie " and "olijfolie" are one item.
func NormName(name string) string {
	s, _, err := transform.String(stripMarks, name)
	if err != nil {
		s = name
	}
	return strings.Join(strings.Fields(strings.ToLower(s)), " ")
}
