package service

import (
	"archive/zip"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
)

// Export writes the household as a zip: household.json, events.ndjson,
// purchases.csv, lists/*.md and homes/*.md, without other people's
// personal lists. Photos join in phase 1. Members only.
func (s *Service) Export(ctx context.Context, sc domain.Scope, w io.Writer) error {
	if err := requireMember(sc); err != nil {
		return err
	}
	var (
		h       domain.Household
		members []domain.Member
		tables  fold.Tables
		evs     []db.Event
		owners  map[string]string
	)
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		row, err := q.GetHousehold(ctx, sc.HouseholdID)
		if err != nil {
			return notFound(err)
		}
		h = household(row)
		rows, err := q.MembersOfHousehold(ctx, sc.HouseholdID)
		if err != nil {
			return err
		}
		for _, r := range rows {
			members = append(members, domain.Member{Membership: domain.Membership{PersonID: r.PersonID, Role: domain.Role(r.Role), CreatedAt: r.CreatedAt}, DisplayName: r.DisplayName, LastSeenAt: r.LastSeenAt})
		}
		if tables, err = foldsql.New(ctx, q, sc.HouseholdID).Tables(); err != nil {
			return err
		}
		if evs, err = q.AllEvents(ctx, sc.HouseholdID); err != nil {
			return err
		}
		owners, err = listOwners(ctx, q, sc.HouseholdID)
		return err
	})
	if err != nil {
		return err
	}
	hidden := map[string]bool{}
	for id, owner := range owners {
		if owner != sc.PersonID {
			hidden[id] = true
		}
	}
	names := map[string]string{}
	for _, m := range members {
		names[m.PersonID] = m.DisplayName
	}
	names[domain.SystemPerson] = "doma"
	items := map[string]fold.Item{}
	for _, it := range tables.Items {
		items[it.ID] = it
	}
	homes := map[string]fold.Home{}
	for _, hm := range tables.Homes {
		homes[hm.ID] = hm
	}
	itemName := func(id string) string {
		if it, ok := items[id]; ok {
			return it.Name
		}
		return id
	}
	homeName := func(id *string) string {
		if id == nil {
			return ""
		}
		if hm, ok := homes[*id]; ok {
			return hm.Name
		}
		return *id
	}
	who := func(id string) string {
		if n, ok := names[id]; ok {
			return n
		}
		return id
	}

	z := zip.NewWriter(w)
	add := func(name string, fn func(io.Writer) error) error {
		f, err := z.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Deflate, Modified: s.now()})
		if err != nil {
			return err
		}
		return fn(f)
	}

	// household.json: the household, its members, homes, spots and lists
	if err := add("household.json", func(f io.Writer) error {
		type memberJSON struct {
			Name     string `json:"name"`
			Role     string `json:"role"`
			JoinedAt int64  `json:"joined_at"`
		}
		var ms []memberJSON
		for _, m := range members {
			ms = append(ms, memberJSON{Name: m.DisplayName, Role: string(m.Role), JoinedAt: m.CreatedAt})
		}
		var lists []fold.List
		for _, l := range tables.Lists {
			if !hidden[l.ID] {
				lists = append(lists, l)
			}
		}
		enc := json.NewEncoder(f)
		enc.SetIndent("", "  ")
		return enc.Encode(map[string]any{
			"exported_at": s.now().UTC().Format(time.RFC3339), "household": h, "members": ms,
			"homes": tables.Homes, "spots": tables.Spots, "lists": lists, "items": tables.Items, "aliases": tables.Aliases,
		})
	}); err != nil {
		return err
	}

	// events.ndjson: the remaining log
	if err := add("events.ndjson", func(f io.Writer) error {
		enc := json.NewEncoder(f)
		for _, e := range evs {
			if !visible(e.Kind, []byte(e.Payload), owners, sc.PersonID) {
				continue
			}
			if err := enc.Encode(SyncEvent{Seq: e.Seq, ID: e.ID, PersonID: e.PersonID, HLC: e.Hlc, Kind: e.Kind, Payload: json.RawMessage(e.Payload)}); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return err
	}

	// purchases.csv: one row per cleared entry
	if err := add("purchases.csv", func(f io.Writer) error {
		cw := csv.NewWriter(f)
		if err := cw.Write([]string{"cleared_at", "added_at", "list", "item", "qty", "unit", "note", "for_home", "added_by", "checked_by"}); err != nil {
			return err
		}
		listName := map[string]string{}
		for _, l := range tables.Lists {
			listName[l.ID] = l.Name
		}
		var cleared []fold.Entry
		for _, e := range tables.Entries {
			if e.ClearedHLC != nil && !hidden[e.ListID] {
				cleared = append(cleared, e)
			}
		}
		sort.Slice(cleared, func(i, j int) bool { return cleared[i].ClearedHLC.Less(*cleared[j].ClearedHLC) })
		for _, e := range cleared {
			qty, unit := "", ""
			if e.Qty != nil {
				qty = strconv.FormatFloat(*e.Qty, 'f', -1, 64)
			}
			if e.Unit != nil {
				unit = *e.Unit
			}
			checked := ""
			if e.CheckedBy != nil {
				checked = who(*e.CheckedBy)
			}
			if err := cw.Write([]string{e.ClearedHLC.Time().Format(time.RFC3339), e.AddedHLC.Time().Format(time.RFC3339), listName[e.ListID], itemName(e.ItemID), qty, unit, e.Note, homeName(e.ForHomeID), who(e.AddedBy), checked}); err != nil {
				return err
			}
		}
		cw.Flush()
		return cw.Error()
	}); err != nil {
		return err
	}

	// lists/*.md: open entries, then the last cleared ones
	for _, l := range tables.Lists {
		if hidden[l.ID] {
			continue
		}
		if err := add("lists/"+slugify(l.Name)+"-"+strings.ToLower(l.ID[len(l.ID)-4:])+".md", func(f io.Writer) error {
			fmt.Fprintf(f, "# %s\n\n", l.Name)
			var open, done []fold.Entry
			for _, e := range tables.Entries {
				if e.ListID != l.ID {
					continue
				}
				if e.ClearedHLC == nil {
					open = append(open, e)
				} else {
					done = append(done, e)
				}
			}
			sort.Slice(open, func(i, j int) bool { return open[i].Sort < open[j].Sort })
			for _, e := range open {
				mark := " "
				if e.CheckedHLC != nil {
					mark = "x"
				}
				fmt.Fprintf(f, "- [%s] %s%s\n", mark, itemName(e.ItemID), entrySuffix(e, homeName))
			}
			if len(done) > 0 {
				sort.Slice(done, func(i, j int) bool { return done[j].ClearedHLC.Less(*done[i].ClearedHLC) })
				fmt.Fprintf(f, "\n## Recent\n\n")
				for i, e := range done {
					if i >= 30 {
						break
					}
					fmt.Fprintf(f, "- %s%s, %s\n", itemName(e.ItemID), entrySuffix(e, homeName), e.ClearedHLC.Time().Format("2006-01-02"))
				}
			}
			return nil
		}); err != nil {
			return err
		}
	}

	// homes/*.md: staples with their flags, then spots
	for _, hm := range tables.Homes {
		if err := add("homes/"+slugify(hm.Name)+".md", func(f io.Writer) error {
			fmt.Fprintf(f, "# %s\n\n", hm.Name)
			flags := map[string]fold.Flag{}
			for _, fl := range tables.Flags {
				if fl.HomeID == hm.ID {
					flags[fl.ItemID] = fl
				}
			}
			var staples []fold.Staple
			for _, st := range tables.Staples {
				if st.HomeID == hm.ID && st.Present() {
					staples = append(staples, st)
				}
			}
			sort.Slice(staples, func(i, j int) bool { return itemName(staples[i].ItemID) < itemName(staples[j].ItemID) })
			if len(staples) > 0 {
				fmt.Fprintf(f, "## Staples\n\n")
				for _, st := range staples {
					state := "unknown"
					when := ""
					if fl, ok := flags[st.ItemID]; ok {
						state = fl.State
						when = ", " + who(fl.SetBy) + " on " + fl.SetHLC.Time().Format("2006-01-02")
					}
					fmt.Fprintf(f, "- %s: %s%s\n", itemName(st.ItemID), state, when)
				}
				fmt.Fprintln(f)
			}
			var spots []fold.Spot
			for _, sp := range tables.Spots {
				if sp.HomeID == hm.ID && sp.ArchivedAt == nil {
					spots = append(spots, sp)
				}
			}
			if len(spots) > 0 {
				fmt.Fprintf(f, "## Spots\n\n")
				for _, sp := range spots {
					fmt.Fprintf(f, "- %s\n", sp.Name)
				}
			}
			return nil
		}); err != nil {
			return err
		}
	}
	return z.Close()
}

func entrySuffix(e fold.Entry, homeName func(*string) string) string {
	var parts []string
	if e.Qty != nil {
		q := strconv.FormatFloat(*e.Qty, 'f', -1, 64)
		if e.Unit != nil {
			q += " " + *e.Unit
		}
		parts = append(parts, q)
	}
	if e.Note != "" {
		parts = append(parts, e.Note)
	}
	if hn := homeName(e.ForHomeID); hn != "" {
		parts = append(parts, "for "+hn)
	}
	if len(parts) == 0 {
		return ""
	}
	return " (" + strings.Join(parts, ", ") + ")"
}
