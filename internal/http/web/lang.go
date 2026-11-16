package web

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/domain"
)

// The family's pages speak the app's three languages. Which one is the
// browser's own choice, from Accept-Language; there is no setting and no
// cookie. The admin's pages are the operator's and stay English.

// langs are the languages the pages are written in, English first.
var langs = []string{"en", "nl", "sk"}

// lang is the first of the browser's languages that doma speaks, English
// when it names none of them.
func (h *Web) lang(r *http.Request) string {
	for _, part := range strings.Split(r.Header.Get("Accept-Language"), ",") {
		tag := strings.ToLower(strings.TrimSpace(strings.SplitN(part, ";", 2)[0]))
		for _, l := range langs {
			if tag == l || strings.HasPrefix(tag, l+"-") {
				return l
			}
		}
	}
	return "en"
}

// translate is the phrase in the language, with args filled in as Sprintf
// does. A phrase the catalogue lacks, a name or a title, comes back as it is.
func translate(lang, phrase string, args ...any) string {
	if pair, ok := words[phrase]; ok {
		switch lang {
		case "nl":
			phrase = pair[0]
		case "sk":
			phrase = pair[1]
		}
	}
	if len(args) == 0 {
		return phrase
	}
	return fmt.Sprintf(phrase, args...)
}

// months are the month names, short and long, per language.
var months = map[string][2][12]string{
	"en": {{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"},
		{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}},
	"nl": {{"jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"},
		{"januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"}},
	"sk": {{"jan", "feb", "mar", "apr", "máj", "jún", "júl", "aug", "sep", "okt", "nov", "dec"},
		{"január", "február", "marec", "apríl", "máj", "jún", "júl", "august", "september", "október", "november", "december"}},
}

func monthNames(lang string) [2][12]string {
	if m, ok := months[lang]; ok {
		return m
	}
	return months["en"]
}

// dateIn is a day as the pages write it: 2 Jan 2006, the month in the language.
func dateIn(lang string, ms int64) string {
	t := domain.FromMillis(ms)
	return strconv.Itoa(t.Day()) + " " + monthNames(lang)[0][t.Month()-1] + " " + strconv.Itoa(t.Year())
}

// monthIn spells out a "2006-01": November 2026.
func monthIn(lang, month string) string {
	t, err := time.Parse("2006-01", month)
	if err != nil {
		return month
	}
	return monthNames(lang)[1][t.Month()-1] + " " + strconv.Itoa(t.Year())
}

// agoIn is how long ago, relative first, the day itself after two months.
func agoIn(lang string, ms int64, now time.Time) string {
	d := now.Sub(domain.FromMillis(ms))
	switch {
	case d < time.Minute:
		return translate(lang, "just now")
	case d < time.Hour:
		return translate(lang, "%d min ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return translate(lang, "%d h ago", int(d.Hours()))
	case d < 48*time.Hour:
		return translate(lang, "yesterday")
	case d < 14*24*time.Hour:
		return translate(lang, "%d days ago", int(d.Hours()/24))
	case d < 60*24*time.Hour:
		return translate(lang, "%d wk ago", int(d.Hours()/24/7))
	default:
		return dateIn(lang, ms)
	}
}
