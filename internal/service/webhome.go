package service

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
)

// The web client's homes, trips and the plan of a trip: the same reading of
// the tables the apps do in Swift (HomeQueries, TripPlan.derive), from the
// server's copy of the tables.

// WebFlagRow is one item at a home as the browser shows it.
type WebFlagRow struct {
	ItemID string
	Name   string
	// State is have, low, out or unknown, after staleness.
	State  string
	SetAt  int64
	Note   string
	Staple bool
}

// WebSpot is a spot with its newest picture's thumbnail, signed for an hour.
type WebSpot struct {
	ID    string
	Name  string
	Thumb string
}

// WebHome is a home card: the counts of staples that are not there.
type WebHome struct {
	ID      string
	Name    string
	Out     int
	Low     int
	Unknown int
	Spots   []WebSpot
}

// WebHomeView is one home: its staples, the other flagged items, its spots
// and the trips through it.
type WebHomeView struct {
	Home    WebHome
	Staples []WebFlagRow
	Others  []WebFlagRow
	Trips   []WebTrip
}

// tablesOf reads a household's tables with the item names and the staleness.
type hhTables struct {
	tables    fold.Tables
	names     map[string]string
	staleness time.Duration
	row       db.Household
}

func (s *Service) readHousehold(ctx context.Context, q *db.Queries, householdID string) (*hhTables, error) {
	h, err := q.GetHousehold(ctx, householdID)
	if err != nil {
		return nil, notFound(err)
	}
	tables, err := foldsql.New(ctx, q, householdID).Tables()
	if err != nil {
		return nil, err
	}
	names := map[string]string{}
	for _, it := range tables.Items {
		names[it.ID] = it.Name
	}
	return &hhTables{tables: tables, names: names, staleness: time.Duration(s.StalenessDays(ptr(household(h)))) * 24 * time.Hour, row: h}, nil
}

// flagRows is the home's staples first, by sort and name, then every other
// item with a flag there, by name; a flag older than the staleness reads
// unknown, as on the phone.
func (s *Service) flagRows(h *hhTables, homeID string) (staples, others []WebFlagRow) {
	flags := map[string]fold.Flag{}
	for _, f := range h.tables.Flags {
		if f.HomeID == homeID {
			flags[f.ItemID] = f
		}
	}
	sortOf := map[string]int64{}
	isStaple := map[string]bool{}
	for _, st := range h.tables.Staples {
		if st.HomeID == homeID && st.Present() {
			isStaple[st.ItemID] = true
			sortOf[st.ItemID] = st.Sort
		}
	}
	row := func(itemID string) WebFlagRow {
		r := WebFlagRow{ItemID: itemID, Name: nameOf(h.names, itemID), State: "unknown", Staple: isStaple[itemID]}
		if f, ok := flags[itemID]; ok {
			r.SetAt, r.Note = f.SetHLC.Wall, f.Note
			if s.now().Sub(f.SetHLC.Time()) < h.staleness {
				r.State = f.State
			}
		}
		return r
	}
	for id := range isStaple {
		staples = append(staples, row(id))
	}
	for id := range flags {
		if !isStaple[id] {
			others = append(others, row(id))
		}
	}
	sort.Slice(staples, func(i, j int) bool {
		if sortOf[staples[i].ItemID] != sortOf[staples[j].ItemID] {
			return sortOf[staples[i].ItemID] < sortOf[staples[j].ItemID]
		}
		return strings.ToLower(staples[i].Name) < strings.ToLower(staples[j].Name)
	})
	sort.Slice(others, func(i, j int) bool { return strings.ToLower(others[i].Name) < strings.ToLower(others[j].Name) })
	return staples, others
}

func (s *Service) spotsOf(h *hhTables, householdID, homeID string) []WebSpot {
	newest := map[string]fold.Photo{}
	for _, p := range h.tables.Photos {
		if cur, ok := newest[p.SpotID]; !ok || cur.TakenAt.Less(p.TakenAt) {
			newest[p.SpotID] = p
		}
	}
	var out []WebSpot
	for _, sp := range h.tables.Spots {
		if sp.HomeID != homeID || sp.ArchivedAt != nil {
			continue
		}
		ws := WebSpot{ID: sp.ID, Name: sp.Name}
		if p, ok := newest[sp.ID]; ok {
			ws.Thumb = s.SignLink("/photos/v1/" + householdID + "/" + p.ID + "/thumb")
		}
		out = append(out, ws)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (s *Service) homeCard(h *hhTables, householdID string, home fold.Home) WebHome {
	card := WebHome{ID: home.ID, Name: home.Name, Spots: s.spotsOf(h, householdID, home.ID)}
	staples, _ := s.flagRows(h, home.ID)
	for _, r := range staples {
		switch r.State {
		case "out":
			card.Out++
		case "low":
			card.Low++
		case "unknown":
			card.Unknown++
		}
	}
	return card
}

// WebHomes is one card per home that is not archived, by name.
func (s *Service) WebHomes(ctx context.Context, sc domain.Scope) ([]WebHome, error) {
	if sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	var out []WebHome
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		h, err := s.readHousehold(ctx, q, sc.HouseholdID)
		if err != nil {
			return err
		}
		for _, home := range h.tables.Homes {
			if home.ArchivedAt == nil {
				out = append(out, s.homeCard(h, sc.HouseholdID, home))
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// WebHome is one home with its rows, spots and trips.
func (s *Service) WebHome(ctx context.Context, sc domain.Scope, homeID string) (*WebHomeView, error) {
	if sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	var v WebHomeView
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		h, err := s.readHousehold(ctx, q, sc.HouseholdID)
		if err != nil {
			return err
		}
		home, ok := findHome(h.tables, homeID)
		if !ok {
			return domain.ErrNotFound
		}
		v.Home = s.homeCard(h, sc.HouseholdID, home)
		v.Staples, v.Others = s.flagRows(h, homeID)
		for _, t := range webTrips(h) {
			if t.FromID == homeID || t.ToID == homeID {
				v.Trips = append(v.Trips, t)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &v, nil
}

func findHome(t fold.Tables, id string) (fold.Home, bool) {
	for _, h := range t.Homes {
		if h.ID == id && h.ArchivedAt == nil {
			return h, true
		}
	}
	return fold.Home{}, false
}

// WebCreateHome makes a home.
func (s *Service) WebCreateHome(ctx context.Context, sc domain.Scope, credentialID, name string) (string, error) {
	if sc.IsGuest() {
		return "", domain.ErrForbidden
	}
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 200 {
		return "", domain.Invalid("name", "give the home a name")
	}
	id := domain.NewID()
	return id, s.webEvents(ctx, sc, credentialID, func(*db.Queries) ([]fold.Event, error) {
		return []fold.Event{s.guestEvent(sc, "home.created", map[string]any{"home_id": id, "name": name})}, nil
	})
}

// webEvents appends the events make returns, inside one transaction, and
// tells the push side.
func (s *Service) webEvents(ctx context.Context, sc domain.Scope, credentialID string, make func(q *db.Queries) ([]fold.Event, error)) error {
	var last int64
	err := s.db.Tx(ctx, func(q *db.Queries) error {
		evs, err := make(q)
		if err != nil {
			return err
		}
		seq, err := s.appendEvents(ctx, q, sc.HouseholdID, credentialID, evs)
		last = seq
		return err
	})
	if err != nil {
		return err
	}
	s.changed(sc.HouseholdID, last)
	return nil
}

// WebSetFlag says have, low or out for an item at a home.
func (s *Service) WebSetFlag(ctx context.Context, sc domain.Scope, credentialID, homeID, itemID, state string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	if state != "have" && state != "low" && state != "out" {
		return domain.Invalid("state", "have, low or out")
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		if _, err := q.GetHome(ctx, db.GetHomeParams{HouseholdID: sc.HouseholdID, ID: homeID}); err != nil {
			return nil, notFound(err)
		}
		return []fold.Event{s.guestEvent(sc, "flag.set", map[string]any{"home_id": homeID, "item_id": itemID, "state": state})}, nil
	})
}

// WebAddStaple puts a typed name on the home's staples, after the last one.
func (s *Service) WebAddStaple(ctx context.Context, sc domain.Scope, credentialID, homeID, text string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	parsed := domain.ParseEntry(text)
	if parsed.Name == "" || len(parsed.Name) > 200 {
		return domain.Invalid("text", "type what the home should have")
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		if _, err := q.GetHome(ctx, db.GetHomeParams{HouseholdID: sc.HouseholdID, ID: homeID}); err != nil {
			return nil, notFound(err)
		}
		itemID, evs, err := s.itemByName(ctx, q, sc, parsed.Name)
		if err != nil {
			return nil, err
		}
		var last int64
		st := foldsql.New(ctx, q, sc.HouseholdID)
		tables, err := st.Tables()
		if err != nil {
			return nil, err
		}
		for _, x := range tables.Staples {
			if x.HomeID == homeID && x.Present() && x.Sort > last {
				last = x.Sort
			}
		}
		return append(evs, s.guestEvent(sc, "staple.added", map[string]any{"home_id": homeID, "item_id": itemID, "sort": last + 1000})), nil
	})
}

// WebRemoveStaple takes an item off the home's staples.
func (s *Service) WebRemoveStaple(ctx context.Context, sc domain.Scope, credentialID, homeID, itemID string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.webEvents(ctx, sc, credentialID, func(*db.Queries) ([]fold.Event, error) {
		return []fold.Event{s.guestEvent(sc, "staple.removed", map[string]any{"home_id": homeID, "item_id": itemID})}, nil
	})
}

// itemByName finds the item a typed name means, by normalised name or alias,
// or makes it: the id and the item.named event to append first, if any.
func (s *Service) itemByName(ctx context.Context, q *db.Queries, sc domain.Scope, name string) (string, []fold.Event, error) {
	norm := domain.NormName(name)
	items, err := q.ListItems(ctx, sc.HouseholdID)
	if err != nil {
		return "", nil, err
	}
	for _, it := range items {
		if it.MergedInto == nil && it.NormName != nil && *it.NormName == norm {
			return it.ID, nil, nil
		}
	}
	aliases, err := q.ListAliases(ctx, sc.HouseholdID)
	if err != nil {
		return "", nil, err
	}
	for _, a := range aliases {
		if a.NormName == norm {
			return a.ItemID, nil, nil
		}
	}
	id := domain.NewID()
	return id, []fold.Event{s.guestEvent(sc, "item.named", map[string]any{"item_id": id, "name": name})}, nil
}

// Trips

// WebTrip is a trip row.
type WebTrip struct {
	ID        string
	FromID    string
	FromName  string
	ToID      string
	ToName    string
	Date      int64
	ListID    string
	ListName  string
	Arrived   bool
	Cancelled bool
}

// Open reports whether the trip is still to be walked.
func (t WebTrip) Open() bool { return !t.Arrived && !t.Cancelled }

// WebTripItem is one line of a trip's plan.
type WebTripItem struct {
	ItemID    string
	Name      string
	ToState   string
	FromState string
	OnList    bool
}

// WebTripView is a trip with its plan: bring from the from-home, buy on the
// way, check on arrival.
type WebTripView struct {
	Trip  WebTrip
	Bring []WebTripItem
	Buy   []WebTripItem
	Check []WebTripItem
	// Carries is false when a nearer open trip to the same home carries its needs.
	Carries bool
}

func webTrips(h *hhTables) []WebTrip {
	homes := map[string]string{}
	for _, x := range h.tables.Homes {
		homes[x.ID] = x.Name
	}
	lists := map[string]string{}
	for _, l := range h.tables.Lists {
		lists[l.ID] = l.Name
	}
	var out []WebTrip
	for _, t := range h.tables.Trips {
		w := WebTrip{ID: t.ID, FromID: t.FromHomeID, FromName: homes[t.FromHomeID], ToID: t.ToHomeID, ToName: homes[t.ToHomeID], Date: t.Date, Arrived: t.ArrivedAt != nil, Cancelled: t.CancelledAt != nil}
		if t.ListID != nil {
			w.ListID, w.ListName = *t.ListID, lists[*t.ListID]
		}
		out = append(out, w)
	}
	// open trips by date, nearest first; then the rest, newest first
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Open() != b.Open() {
			return a.Open()
		}
		if a.Date != b.Date {
			if a.Open() {
				return a.Date < b.Date
			}
			return a.Date > b.Date
		}
		return a.ID < b.ID
	})
	return out
}

// WebTrips is the household's trips.
func (s *Service) WebTrips(ctx context.Context, sc domain.Scope) ([]WebTrip, error) {
	if sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	var out []WebTrip
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		h, err := s.readHousehold(ctx, q, sc.HouseholdID)
		if err != nil {
			return err
		}
		out = webTrips(h)
		return nil
	})
	return out, err
}

// carries reports whether the trip is the nearest open one to its to-home.
func carries(trip WebTrip, among []WebTrip) bool {
	if !trip.Open() {
		return false
	}
	best := trip
	for _, t := range among {
		if t.Open() && t.ToID == trip.ToID && (t.Date < best.Date || (t.Date == best.Date && t.ID < best.ID)) {
			best = t
		}
	}
	return best.ID == trip.ID
}

// derive is TripPlan.derive: from the flags of both homes and what is open on
// the trip's list for the to-home.
func derive(fromRows, toRows []WebFlagRow, listed map[string]string) (bring, buy, check []WebTripItem) {
	from := map[string]string{}
	for _, r := range fromRows {
		from[r.ItemID] = r.State
	}
	state := func(id string) string {
		if st, ok := from[id]; ok {
			return st
		}
		return "unknown"
	}
	seen := map[string]bool{}
	for _, r := range toRows {
		seen[r.ItemID] = true
		item := WebTripItem{ItemID: r.ItemID, Name: r.Name, ToState: r.State, FromState: state(r.ItemID)}
		_, item.OnList = listed[r.ItemID]
		switch r.State {
		case "out", "low":
			if item.FromState == "have" {
				bring = append(bring, item)
			} else {
				buy = append(buy, item)
			}
		case "unknown":
			if r.Staple {
				check = append(check, item)
			}
		}
	}
	for id, name := range listed {
		if !seen[id] {
			buy = append(buy, WebTripItem{ItemID: id, Name: name, ToState: "unknown", FromState: state(id), OnList: true})
		}
	}
	sort.Slice(buy, func(i, j int) bool { return strings.ToLower(buy[i].Name) < strings.ToLower(buy[j].Name) })
	return bring, buy, check
}

// WebTrip is one trip with its plan as the tables stand now.
func (s *Service) WebTrip(ctx context.Context, sc domain.Scope, tripID string) (*WebTripView, error) {
	if sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	var v WebTripView
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		h, err := s.readHousehold(ctx, q, sc.HouseholdID)
		if err != nil {
			return err
		}
		trips := webTrips(h)
		found := false
		for _, t := range trips {
			if t.ID == tripID {
				v.Trip, found = t, true
			}
		}
		if !found {
			return domain.ErrNotFound
		}
		v.Carries = carries(v.Trip, trips) && v.Trip.FromID != v.Trip.ToID
		if !v.Carries {
			return nil
		}
		fromStaples, fromOthers := s.flagRows(h, v.Trip.FromID)
		toStaples, toOthers := s.flagRows(h, v.Trip.ToID)
		listID := v.Trip.ListID
		if listID == "" {
			for _, l := range h.tables.Lists {
				if l.IsDefault {
					listID = l.ID
				}
			}
		}
		listed := map[string]string{}
		for _, e := range h.tables.Entries {
			if e.ListID == listID && e.ClearedHLC == nil && e.ForHomeID != nil && *e.ForHomeID == v.Trip.ToID {
				listed[e.ItemID] = nameOf(h.names, e.ItemID)
			}
		}
		v.Bring, v.Buy, v.Check = derive(append(fromStaples, fromOthers...), append(toStaples, toOthers...), listed)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &v, nil
}

// WebPlanTrip plans a trip from one home to another on a day, shopping on a list.
func (s *Service) WebPlanTrip(ctx context.Context, sc domain.Scope, credentialID, from, to string, date int64, listID string) (string, error) {
	if sc.IsGuest() {
		return "", domain.ErrForbidden
	}
	if from == "" || to == "" || from == to {
		return "", domain.Invalid("to", "a trip goes from one home to another")
	}
	id := domain.NewID()
	return id, s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		for _, home := range []string{from, to} {
			if _, err := q.GetHome(ctx, db.GetHomeParams{HouseholdID: sc.HouseholdID, ID: home}); err != nil {
				return nil, notFound(err)
			}
		}
		payload := map[string]any{"trip_id": id, "from_home_id": from, "to_home_id": to, "date": date}
		if listID != "" {
			if _, err := s.webList(ctx, q, sc, listID); err != nil {
				return nil, err
			}
			payload["list_id"] = listID
		}
		return []fold.Event{s.guestEvent(sc, "trip.planned", payload)}, nil
	})
}

// WebCancelTrip cancels a trip.
func (s *Service) WebCancelTrip(ctx context.Context, sc domain.Scope, credentialID, tripID string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.webEvents(ctx, sc, credentialID, func(*db.Queries) ([]fold.Event, error) {
		return []fold.Event{s.guestEvent(sc, "trip.cancelled", map[string]any{"trip_id": tripID})}, nil
	})
}

// WebArrive commits the trip: what was to bring has moved, the flags follow.
func (s *Service) WebArrive(ctx context.Context, sc domain.Scope, credentialID, tripID string) error {
	v, err := s.WebTrip(ctx, sc, tripID)
	if err != nil {
		return err
	}
	if !v.Trip.Open() {
		return domain.ErrConflict
	}
	moved := []string{}
	for _, it := range v.Bring {
		moved = append(moved, it.ItemID)
	}
	return s.webEvents(ctx, sc, credentialID, func(*db.Queries) ([]fold.Event, error) {
		return []fold.Event{s.guestEvent(sc, "trip.arrived", map[string]any{"trip_id": tripID, "from_home_id": v.Trip.FromID, "to_home_id": v.Trip.ToID, "moved": moved})}, nil
	})
}

// WebAddToList puts an item of the trip's plan on its list for the to-home,
// unless it is open there already.
func (s *Service) WebAddToList(ctx context.Context, sc domain.Scope, credentialID, tripID, itemID string) error {
	v, err := s.WebTrip(ctx, sc, tripID)
	if err != nil {
		return err
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		listID := v.Trip.ListID
		if listID == "" {
			id, err := q.DefaultListID(ctx, sc.HouseholdID)
			if err != nil {
				return nil, notFound(err)
			}
			listID = id
		}
		rows, err := foldsql.New(ctx, q, sc.HouseholdID).Entries(listID, []string{itemID})
		if err != nil {
			return nil, err
		}
		for _, e := range rows {
			if e.ClearedHLC == nil && e.CheckedHLC == nil {
				return nil, nil
			}
		}
		return []fold.Event{s.guestEvent(sc, "entry.added", map[string]any{"list_id": listID, "item_id": itemID, "for_home_id": v.Trip.ToID})}, nil
	})
}
