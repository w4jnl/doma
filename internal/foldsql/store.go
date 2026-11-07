// Package foldsql implements fold.Store over the sqlc queries, bound to one
// household inside one write transaction. The service appends an event and
// folds it through this store in the same transaction.
package foldsql

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
)

// Store is the fold's view of one household.
type Store struct {
	ctx         context.Context //nolint:containedctx // bound for the life of one transaction
	q           *db.Queries
	HouseholdID string
}

// New binds q, usually a transaction's queries, to a household.
func New(ctx context.Context, q *db.Queries, householdID string) *Store {
	return &Store{ctx: ctx, q: q, HouseholdID: householdID}
}

// Append writes e to the log with the next seq and folds it. A duplicate
// id is not an error: applied is false and nothing changes.
func (s *Store) Append(e fold.Event, credentialID string, receivedAt int64) (seq int64, applied bool, err error) {
	return s.AppendWith(s, e, credentialID, receivedAt)
}

// AppendWith is Append folding through through, usually this store wrapped
// by a trace.
func (s *Store) AppendWith(through fold.Store, e fold.Event, credentialID string, receivedAt int64) (seq int64, applied bool, err error) {
	seq, err = s.q.NextSeq(s.ctx, s.HouseholdID)
	if err != nil {
		return 0, false, fmt.Errorf("next seq: %w", err)
	}
	err = s.q.InsertEvent(s.ctx, db.InsertEventParams{
		HouseholdID: s.HouseholdID, Seq: seq, ID: e.ID, PersonID: e.PersonID, CredentialID: credentialID,
		Hlc: e.HLC.String(), Kind: e.Kind, Payload: string(e.Payload), ReceivedAt: receivedAt,
	})
	if err != nil {
		if db.IsUniqueViolation(err) {
			return 0, false, nil
		}
		return 0, false, fmt.Errorf("insert event: %w", err)
	}
	if err := fold.Apply(through, e); err != nil {
		return 0, false, err
	}
	return seq, true, nil
}

// Event converts a stored event for the fold.
func Event(e db.Event) (fold.Event, error) {
	h, err := domain.ParseHLC(e.Hlc)
	if err != nil {
		return fold.Event{}, fmt.Errorf("event %s: %w", e.ID, err)
	}
	return fold.Event{ID: e.ID, PersonID: e.PersonID, HLC: h, Kind: e.Kind, Payload: json.RawMessage(e.Payload)}, nil
}

func events(rows []db.Event) ([]fold.Event, error) {
	out := make([]fold.Event, 0, len(rows))
	for _, r := range rows {
		e, err := Event(r)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, nil
}

func idsJSON(ids []string) string {
	if ids == nil {
		ids = []string{}
	}
	raw, _ := json.Marshal(ids)
	return string(raw)
}

func hlcPtr(s *string) (*domain.HLC, error) {
	if s == nil {
		return nil, nil
	}
	h, err := domain.ParseHLC(*s)
	if err != nil {
		return nil, err
	}
	return &h, nil
}

func strPtr(h *domain.HLC) *string {
	if h == nil {
		return nil
	}
	s := h.String()
	return &s
}

func noRows(err error) bool { return errors.Is(err, sql.ErrNoRows) }

// items

func itemRow(r db.Item) (fold.Item, error) {
	c, err := domain.ParseHLC(r.CreatedHlc)
	if err != nil {
		return fold.Item{}, err
	}
	u, err := domain.ParseHLC(r.UpdatedHlc)
	if err != nil {
		return fold.Item{}, err
	}
	return fold.Item{ID: r.ID, Name: r.Name, NormName: r.NormName, Category: r.Category, LastUsedAt: r.LastUsedAt, UseCount: r.UseCount, ArchivedAt: r.ArchivedAt, MergedInto: r.MergedInto, CreatedHLC: c, UpdatedHLC: u}, nil
}

func (s *Store) Item(id string) (*fold.Item, error) {
	r, err := s.q.GetItem(s.ctx, db.GetItemParams{HouseholdID: s.HouseholdID, ID: id})
	if noRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	it, err := itemRow(r)
	return &it, err
}

func (s *Store) Items() ([]fold.Item, error) {
	rows, err := s.q.ListItems(s.ctx, s.HouseholdID)
	if err != nil {
		return nil, err
	}
	out := make([]fold.Item, 0, len(rows))
	for _, r := range rows {
		it, err := itemRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, nil
}

func (s *Store) PutItem(it fold.Item) error {
	return s.q.UpsertItem(s.ctx, db.UpsertItemParams{
		ID: it.ID, HouseholdID: s.HouseholdID, Name: it.Name, NormName: it.NormName, Category: it.Category, LastUsedAt: it.LastUsedAt,
		UseCount: it.UseCount, ArchivedAt: it.ArchivedAt, MergedInto: it.MergedInto, CreatedHlc: it.CreatedHLC.String(), UpdatedHlc: it.UpdatedHLC.String(),
	})
}

func (s *Store) ReplaceAliases(all []fold.Alias) error {
	if err := s.q.DeleteAliases(s.ctx, s.HouseholdID); err != nil {
		return err
	}
	for _, a := range all {
		if err := s.q.InsertAlias(s.ctx, db.InsertAliasParams{ItemID: a.ItemID, HouseholdID: s.HouseholdID, NormName: a.NormName}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) MergedIDs(id string) ([]string, error) {
	items, err := s.Items()
	if err != nil {
		return nil, err
	}
	out := []string{id}
	for i := 0; i < len(out); i++ {
		for _, it := range items {
			if it.MergedInto != nil && *it.MergedInto == out[i] && !contains(out, it.ID) {
				out = append(out, it.ID)
			}
		}
	}
	sort.Strings(out[1:])
	return out, nil
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

func (s *Store) RecountItemUsage(id string) error {
	return s.q.RecountItemUsage(s.ctx, db.RecountItemUsageParams{HouseholdID: s.HouseholdID, ID: id})
}

func (s *Store) ItemEvents() ([]fold.Event, error) {
	rows, err := s.q.ItemEvents(s.ctx, s.HouseholdID)
	if err != nil {
		return nil, err
	}
	return events(rows)
}

func (s *Store) ItemEventsFor(itemIDs []string) ([]fold.Event, error) {
	rows, err := s.q.ItemEventsFor(s.ctx, db.ItemEventsForParams{HouseholdID: s.HouseholdID, ItemIds: idsJSON(itemIDs)})
	if err != nil {
		return nil, err
	}
	return events(rows)
}

// lists

func listRow(r db.List) (fold.List, error) {
	u, err := hlcPtr(r.UpdatedHlc)
	if err != nil {
		return fold.List{}, err
	}
	return fold.List{ID: r.ID, Name: r.Name, Colour: r.Colour, OwnerPersonID: r.OwnerPersonID, Sort: r.Sort, IsDefault: r.IsDefault != 0, ArchivedAt: r.ArchivedAt, UpdatedHLC: u, Kind: r.Kind}, nil
}

func (s *Store) List(id string) (*fold.List, error) {
	r, err := s.q.GetList(s.ctx, db.GetListParams{HouseholdID: s.HouseholdID, ID: id})
	if noRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	l, err := listRow(r)
	return &l, err
}

func (s *Store) PutList(l fold.List) error {
	var def int64
	if l.IsDefault {
		def = 1
	}
	return s.q.UpsertList(s.ctx, db.UpsertListParams{
		ID: l.ID, HouseholdID: s.HouseholdID, Name: l.Name, Colour: l.Colour, OwnerPersonID: l.OwnerPersonID, Sort: l.Sort,
		IsDefault: def, ArchivedAt: l.ArchivedAt, UpdatedHlc: strPtr(l.UpdatedHLC), Kind: l.Kind,
	})
}

func (s *Store) DefaultListID() (string, error) {
	id, err := s.q.DefaultListID(s.ctx, s.HouseholdID)
	if noRows(err) {
		return "", nil
	}
	return id, err
}

// entries

func entryRow(r db.Entry) (fold.Entry, error) {
	a, err := domain.ParseHLC(r.AddedHlc)
	if err != nil {
		return fold.Entry{}, err
	}
	ch, err := hlcPtr(r.CheckedHlc)
	if err != nil {
		return fold.Entry{}, err
	}
	cl, err := hlcPtr(r.ClearedHlc)
	if err != nil {
		return fold.Entry{}, err
	}
	return fold.Entry{ID: r.ID, ListID: r.ListID, ItemID: r.ItemID, Note: r.Note, Qty: r.Qty, Unit: r.Unit, ForHomeID: r.ForHomeID, Sort: r.Sort, AddedHLC: a, AddedBy: r.AddedBy, CheckedHLC: ch, CheckedBy: r.CheckedBy, ClearedHLC: cl}, nil
}

func entryRows(rows []db.Entry) ([]fold.Entry, error) {
	out := make([]fold.Entry, 0, len(rows))
	for _, r := range rows {
		e, err := entryRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, nil
}

func (s *Store) EntryEvents(listID string, itemIDs []string, isDefault bool) ([]fold.Event, error) {
	var any, def int64
	if itemIDs == nil {
		any = 1
	}
	if isDefault {
		def = 1
	}
	rows, err := s.q.EntryEventsForKey(s.ctx, db.EntryEventsForKeyParams{HouseholdID: s.HouseholdID, ListID: listID, AnyItem: any, ItemIds: idsJSON(itemIDs), IsDefault: def})
	if err != nil {
		return nil, err
	}
	return events(rows)
}

func (s *Store) EntryListIDs(itemIDs []string) ([]string, error) {
	return s.q.EntryListIDs(s.ctx, db.EntryListIDsParams{HouseholdID: s.HouseholdID, ItemIds: idsJSON(itemIDs)})
}

func (s *Store) Entries(listID string, itemIDs []string) ([]fold.Entry, error) {
	if itemIDs == nil {
		// every entry of the list, for the pages
		all, err := s.q.ListEntries(s.ctx, s.HouseholdID)
		if err != nil {
			return nil, err
		}
		var rows []db.Entry
		for _, r := range all {
			if r.ListID == listID {
				rows = append(rows, r)
			}
		}
		return entryRows(rows)
	}
	rows, err := s.q.EntriesForKey(s.ctx, db.EntriesForKeyParams{HouseholdID: s.HouseholdID, ListID: listID, ItemIds: idsJSON(itemIDs)})
	if err != nil {
		return nil, err
	}
	return entryRows(rows)
}

func (s *Store) ReplaceEntries(listID string, itemIDs []string, rows []fold.Entry) error {
	if err := s.q.DeleteEntriesForKey(s.ctx, db.DeleteEntriesForKeyParams{HouseholdID: s.HouseholdID, ListID: listID, ItemIds: idsJSON(itemIDs)}); err != nil {
		return err
	}
	for _, e := range rows {
		err := s.q.InsertEntry(s.ctx, db.InsertEntryParams{
			ID: e.ID, HouseholdID: s.HouseholdID, ListID: e.ListID, ItemID: e.ItemID, Note: e.Note, Qty: e.Qty, Unit: e.Unit, ForHomeID: e.ForHomeID, Sort: e.Sort,
			AddedHlc: e.AddedHLC.String(), AddedBy: e.AddedBy, CheckedHlc: strPtr(e.CheckedHLC), CheckedBy: e.CheckedBy, ClearedHlc: strPtr(e.ClearedHLC),
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) ClearedEntriesForHome(itemIDs []string, homeID string) ([]fold.Entry, error) {
	rows, err := s.q.ClearedEntriesForHome(s.ctx, db.ClearedEntriesForHomeParams{HouseholdID: s.HouseholdID, HomeID: &homeID, ItemIds: idsJSON(itemIDs)})
	if err != nil {
		return nil, err
	}
	return entryRows(rows)
}

// flags and staples

func flagRow(r db.Flag) (fold.Flag, error) {
	h, err := domain.ParseHLC(r.SetHlc)
	if err != nil {
		return fold.Flag{}, err
	}
	return fold.Flag{HomeID: r.HomeID, ItemID: r.ItemID, State: r.State, SetHLC: h, SetBy: r.SetBy, Note: r.Note}, nil
}

func (s *Store) Flag(homeID, itemID string) (*fold.Flag, error) {
	r, err := s.q.GetFlag(s.ctx, db.GetFlagParams{HouseholdID: s.HouseholdID, HomeID: homeID, ItemID: itemID})
	if noRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	f, err := flagRow(r)
	return &f, err
}

func (s *Store) PutFlag(f fold.Flag) error {
	return s.q.UpsertFlag(s.ctx, db.UpsertFlagParams{HouseholdID: s.HouseholdID, HomeID: f.HomeID, ItemID: f.ItemID, State: f.State, SetHlc: f.SetHLC.String(), SetBy: f.SetBy, Note: f.Note})
}

func (s *Store) DeleteFlag(homeID, itemID string) error {
	return s.q.DeleteFlag(s.ctx, db.DeleteFlagParams{HouseholdID: s.HouseholdID, HomeID: homeID, ItemID: itemID})
}

func (s *Store) DeleteFlagsForItems(itemIDs []string) error {
	return s.q.DeleteFlagsForItems(s.ctx, db.DeleteFlagsForItemsParams{HouseholdID: s.HouseholdID, ItemIds: idsJSON(itemIDs)})
}

func stapleRow(r db.Staple) (fold.Staple, error) {
	a, err := hlcPtr(r.AddedHlc)
	if err != nil {
		return fold.Staple{}, err
	}
	rm, err := hlcPtr(r.RemovedHlc)
	if err != nil {
		return fold.Staple{}, err
	}
	return fold.Staple{HomeID: r.HomeID, ItemID: r.ItemID, Sort: r.Sort, AddedHLC: a, RemovedHLC: rm}, nil
}

func (s *Store) Staple(homeID, itemID string) (*fold.Staple, error) {
	r, err := s.q.GetStaple(s.ctx, db.GetStapleParams{HouseholdID: s.HouseholdID, HomeID: homeID, ItemID: itemID})
	if noRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	st, err := stapleRow(r)
	return &st, err
}

func (s *Store) PutStaple(st fold.Staple) error {
	return s.q.UpsertStaple(s.ctx, db.UpsertStapleParams{HouseholdID: s.HouseholdID, HomeID: st.HomeID, ItemID: st.ItemID, Sort: st.Sort, AddedHlc: strPtr(st.AddedHLC), RemovedHlc: strPtr(st.RemovedHLC)})
}

func (s *Store) DeleteStaplesForItems(itemIDs []string) error {
	return s.q.DeleteStaplesForItems(s.ctx, db.DeleteStaplesForItemsParams{HouseholdID: s.HouseholdID, ItemIds: idsJSON(itemIDs)})
}

// homes, spots, photos, trips

func (s *Store) Home(id string) (*fold.Home, error) {
	r, err := s.q.GetHome(s.ctx, db.GetHomeParams{HouseholdID: s.HouseholdID, ID: id})
	if noRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	u, err := hlcPtr(r.UpdatedHlc)
	if err != nil {
		return nil, err
	}
	return &fold.Home{ID: r.ID, Name: r.Name, Sort: r.Sort, ArchivedAt: r.ArchivedAt, UpdatedHLC: u}, nil
}

func (s *Store) PutHome(h fold.Home) error {
	return s.q.UpsertHome(s.ctx, db.UpsertHomeParams{ID: h.ID, HouseholdID: s.HouseholdID, Name: h.Name, Sort: h.Sort, ArchivedAt: h.ArchivedAt, UpdatedHlc: strPtr(h.UpdatedHLC)})
}

func (s *Store) Spot(id string) (*fold.Spot, error) {
	r, err := s.q.GetSpot(s.ctx, db.GetSpotParams{HouseholdID: s.HouseholdID, ID: id})
	if noRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	u, err := hlcPtr(r.UpdatedHlc)
	if err != nil {
		return nil, err
	}
	return &fold.Spot{ID: r.ID, HomeID: r.HomeID, Name: r.Name, Sort: r.Sort, ArchivedAt: r.ArchivedAt, UpdatedHLC: u}, nil
}

func (s *Store) PutSpot(sp fold.Spot) error {
	return s.q.UpsertSpot(s.ctx, db.UpsertSpotParams{ID: sp.ID, HouseholdID: s.HouseholdID, HomeID: sp.HomeID, Name: sp.Name, Sort: sp.Sort, ArchivedAt: sp.ArchivedAt, UpdatedHlc: strPtr(sp.UpdatedHLC)})
}

func (s *Store) PutPhoto(p fold.Photo) error {
	return s.q.InsertPhoto(s.ctx, db.InsertPhotoParams{ID: p.ID, HouseholdID: s.HouseholdID, SpotID: p.SpotID, TakenHlc: p.TakenAt.String(), TakenBy: p.TakenBy, Bytes: p.Bytes, Width: p.Width, Height: p.Height})
}

func (s *Store) Trip(id string) (*fold.Trip, error) {
	r, err := s.q.GetTrip(s.ctx, db.GetTripParams{HouseholdID: s.HouseholdID, ID: id})
	if noRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	t, err := tripOf(r)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func tripOf(r db.Trip) (fold.Trip, error) {
	u, err := hlcPtr(r.UpdatedHlc)
	if err != nil {
		return fold.Trip{}, err
	}
	return fold.Trip{ID: r.ID, FromHomeID: r.FromHomeID, ToHomeID: r.ToHomeID, Date: r.Date, CreatedBy: r.CreatedBy, ListID: r.ListID, UpdatedHLC: u, ArrivedAt: r.ArrivedAt, CancelledAt: r.CancelledAt}, nil
}

func (s *Store) PutTrip(t fold.Trip) error {
	return s.q.UpsertTrip(s.ctx, db.UpsertTripParams{ID: t.ID, HouseholdID: s.HouseholdID, FromHomeID: t.FromHomeID, ToHomeID: t.ToHomeID, Date: t.Date, CreatedBy: t.CreatedBy, ListID: t.ListID, UpdatedHlc: strPtr(t.UpdatedHLC), ArrivedAt: t.ArrivedAt, CancelledAt: t.CancelledAt})
}

// Tables reads every materialised table of the household, for tests and
// for the snapshot job.
func (s *Store) Tables() (fold.Tables, error) {
	var t fold.Tables
	items, err := s.Items()
	if err != nil {
		return t, err
	}
	t.Items = items
	aliases, err := s.q.ListAliases(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	for _, a := range aliases {
		t.Aliases = append(t.Aliases, fold.Alias{ItemID: a.ItemID, NormName: a.NormName})
	}
	lists, err := s.q.ListLists(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	for _, r := range lists {
		l, err := listRow(r)
		if err != nil {
			return t, err
		}
		t.Lists = append(t.Lists, l)
	}
	entries, err := s.q.ListEntries(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	if t.Entries, err = entryRows(entries); err != nil {
		return t, err
	}
	flags, err := s.q.ListFlags(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	for _, r := range flags {
		f, err := flagRow(r)
		if err != nil {
			return t, err
		}
		t.Flags = append(t.Flags, f)
	}
	staples, err := s.q.ListStaples(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	for _, r := range staples {
		st, err := stapleRow(r)
		if err != nil {
			return t, err
		}
		t.Staples = append(t.Staples, st)
	}
	homes, err := s.q.ListHomes(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	for _, r := range homes {
		u, err := hlcPtr(r.UpdatedHlc)
		if err != nil {
			return t, err
		}
		t.Homes = append(t.Homes, fold.Home{ID: r.ID, Name: r.Name, Sort: r.Sort, ArchivedAt: r.ArchivedAt, UpdatedHLC: u})
	}
	spots, err := s.q.ListSpots(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	for _, r := range spots {
		u, err := hlcPtr(r.UpdatedHlc)
		if err != nil {
			return t, err
		}
		t.Spots = append(t.Spots, fold.Spot{ID: r.ID, HomeID: r.HomeID, Name: r.Name, Sort: r.Sort, ArchivedAt: r.ArchivedAt, UpdatedHLC: u})
	}
	photos, err := s.q.ListPhotos(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	for _, r := range photos {
		h, err := domain.ParseHLC(r.TakenHlc)
		if err != nil {
			return t, err
		}
		t.Photos = append(t.Photos, fold.Photo{ID: r.ID, SpotID: r.SpotID, TakenAt: h, TakenBy: r.TakenBy, Bytes: r.Bytes, Width: r.Width, Height: r.Height})
	}
	trips, err := s.q.ListTrips(s.ctx, s.HouseholdID)
	if err != nil {
		return t, err
	}
	for _, r := range trips {
		tr, err := tripOf(r)
		if err != nil {
			return t, err
		}
		t.Trips = append(t.Trips, tr)
	}
	t.Sort()
	return t, nil
}

var _ fold.Store = (*Store)(nil)
