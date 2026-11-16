package web

import (
	"io/fs"
	"regexp"
	"strings"
	"testing"
)

// Every phrase a template hands to t is in the catalogue, in both languages
// and with the same things to fill in, so no page is half translated.
func TestEveryPhraseIsTranslated(t *testing.T) {
	names, err := fs.Glob(templateFS, "templates/*.html")
	if err != nil {
		t.Fatal(err)
	}
	phrase := regexp.MustCompile(`\bt "((?:[^"\\]|\\.)*)"`)
	verbs := regexp.MustCompile(`%[ds]`)
	seen := 0
	for _, name := range names {
		raw, err := templateFS.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range phrase.FindAllStringSubmatch(string(raw), -1) {
			seen++
			p := strings.ReplaceAll(m[1], `\"`, `"`)
			if _, ok := words[p]; !ok {
				t.Errorf("%s says %q, which the catalogue lacks", name, p)
			}
		}
	}
	if seen < 150 {
		t.Errorf("only %d phrases found in the templates; the pattern no longer matches them", seen)
	}
	for en, pair := range words {
		want := strings.Join(verbs.FindAllString(en, -1), "")
		for i, lang := range []string{"nl", "sk"} {
			if pair[i] == "" {
				t.Errorf("%q has no %s", en, lang)
			}
			if got := strings.Join(verbs.FindAllString(pair[i], -1), ""); got != want {
				t.Errorf("%q in %s fills in %q, the English %q", en, lang, got, want)
			}
		}
	}
}

func TestTranslateAndDates(t *testing.T) {
	if got := translate("nl", "%d to get", 3); got != "3 te halen" {
		t.Errorf("nl: %q", got)
	}
	if got := translate("sk", "Lists"); got != "Zoznamy" {
		t.Errorf("sk: %q", got)
	}
	if got := translate("nl", "Boodschappen bij de buren"); got != "Boodschappen bij de buren" {
		t.Errorf("a name came back as %q", got)
	}
	if got := monthIn("nl", "2026-03"); got != "maart 2026" {
		t.Errorf("month: %q", got)
	}
	if got := dateIn("sk", 1793491200000); !strings.Contains(got, "nov 2026") {
		t.Errorf("date: %q", got)
	}
}
