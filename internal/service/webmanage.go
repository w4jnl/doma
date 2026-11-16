package service

import (
	"context"
	"strings"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
)

// What a member manages from a browser, as on the phone: a list's name and
// colour, sharing and archiving it, a home's name, its spots' names, and the
// sections its staples are shown under. Every one is the event the app writes.

// sectionMax is the longest a section's name may be, the event schema's bound.
const sectionMax = 40

// ListColours are the six list colours of the design system, in order.
func ListColours() []string { return append([]string(nil), listColours...) }

// WebRenameList gives a list a name and, when one of the six is named, a colour.
func (s *Service) WebRenameList(ctx context.Context, sc domain.Scope, credentialID, listID, name, colour string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 200 {
		return domain.Invalid("name", "give the list a name")
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		l, err := s.webList(ctx, q, sc, listID)
		if err != nil {
			return nil, err
		}
		payload := map[string]any{"list_id": listID, "name": name, "colour": l.Colour}
		for _, c := range listColours {
			if c == colour {
				payload["colour"] = c
			}
		}
		return []fold.Event{s.guestEvent(sc, "list.renamed", payload)}, nil
	})
}

// WebArchiveList takes a list off the screen with its history kept. The
// household's default list stays.
func (s *Service) WebArchiveList(ctx context.Context, sc domain.Scope, credentialID, listID string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		l, err := s.webList(ctx, q, sc, listID)
		if err != nil {
			return nil, err
		}
		if l.IsDefault != 0 {
			return nil, domain.Invalid("list", "the household's first list stays")
		}
		return []fold.Event{s.guestEvent(sc, "list.archived", map[string]any{"list_id": listID})}, nil
	})
}

// WebShareList makes a household list of a personal one, as the phone's Share
// with the family does: the same name, colour and kind, what is still open
// moved onto it, and the personal list archived with its history. It returns
// the new list's id.
func (s *Service) WebShareList(ctx context.Context, sc domain.Scope, credentialID, listID string) (string, error) {
	if sc.IsGuest() {
		return "", domain.ErrForbidden
	}
	id := domain.NewID()
	err := s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		l, err := s.webList(ctx, q, sc, listID)
		if err != nil {
			return nil, err
		}
		if l.OwnerPersonID == nil {
			return nil, domain.Invalid("list", "the family sees this list already")
		}
		created := map[string]any{"list_id": id, "name": l.Name, "colour": l.Colour}
		if l.Kind == "tasks" {
			created["kind"] = "tasks"
		}
		evs := []fold.Event{s.guestEvent(sc, "list.created", created)}
		rows, err := foldsql.New(ctx, q, sc.HouseholdID).Entries(listID, nil)
		if err != nil {
			return nil, err
		}
		for _, e := range rows {
			if e.ClearedHLC != nil || e.CheckedHLC != nil {
				continue
			}
			p := map[string]any{"list_id": id, "item_id": e.ItemID, "note": e.Note}
			if e.Qty != nil {
				p["qty"] = *e.Qty
				p["unit"] = e.Unit
			}
			if e.ForHomeID != nil {
				p["for_home_id"] = *e.ForHomeID
			}
			evs = append(evs, s.guestEvent(sc, "entry.added", p))
		}
		return append(evs, s.guestEvent(sc, "list.archived", map[string]any{"list_id": listID})), nil
	})
	if err != nil {
		return "", err
	}
	return id, nil
}

// WebRenameHome gives a home another name.
func (s *Service) WebRenameHome(ctx context.Context, sc domain.Scope, credentialID, homeID, name string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 200 {
		return domain.Invalid("name", "give the home a name")
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		if _, err := q.GetHome(ctx, db.GetHomeParams{HouseholdID: sc.HouseholdID, ID: homeID}); err != nil {
			return nil, notFound(err)
		}
		return []fold.Event{s.guestEvent(sc, "home.renamed", map[string]any{"home_id": homeID, "name": name})}, nil
	})
}

// spotAt is the spot when it is at the home and not removed.
func spotAt(ctx context.Context, q *db.Queries, sc domain.Scope, homeID, spotID string) error {
	sp, err := q.GetSpot(ctx, db.GetSpotParams{HouseholdID: sc.HouseholdID, ID: spotID})
	if err != nil {
		return notFound(err)
	}
	if sp.HomeID != homeID || sp.ArchivedAt != nil {
		return domain.ErrNotFound
	}
	return nil
}

// WebRenameSpot gives a spot of the home another name.
func (s *Service) WebRenameSpot(ctx context.Context, sc domain.Scope, credentialID, homeID, spotID, name string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 200 {
		return domain.Invalid("name", "give the spot a name")
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		if err := spotAt(ctx, q, sc, homeID, spotID); err != nil {
			return nil, err
		}
		return []fold.Event{s.guestEvent(sc, "spot.renamed", map[string]any{"spot_id": spotID, "name": name})}, nil
	})
}

// WebRemoveSpot takes a spot off the home; its pictures go with it from the screen.
func (s *Service) WebRemoveSpot(ctx context.Context, sc domain.Scope, credentialID, homeID, spotID string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		if err := spotAt(ctx, q, sc, homeID, spotID); err != nil {
			return nil, err
		}
		return []fold.Event{s.guestEvent(sc, "spot.archived", map[string]any{"spot_id": spotID})}, nil
	})
}

// sectionName is a section's name as kept: trimmed, bounded, and spelled as a
// section the home already has when only the case differs.
func sectionName(typed string, staples []fold.Staple, homeID string) (string, error) {
	name := strings.TrimSpace(typed)
	if len(name) > sectionMax {
		return "", domain.Invalid("section", "a shorter name for the section")
	}
	for _, x := range staples {
		if x.HomeID == homeID && x.Present() && x.Section != "" && strings.EqualFold(x.Section, name) {
			return x.Section, nil
		}
	}
	return name, nil
}

// WebMoveStaple puts a staple at the end of a section of the home, one that
// is there or a new one; "" is no section. A staple's section is only the
// name it carries, so this is the add the phone's Move to writes.
func (s *Service) WebMoveStaple(ctx context.Context, sc domain.Scope, credentialID, homeID, itemID, section string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		tables, err := foldsql.New(ctx, q, sc.HouseholdID).Tables()
		if err != nil {
			return nil, err
		}
		name, err := sectionName(section, tables.Staples, homeID)
		if err != nil {
			return nil, err
		}
		found := false
		var last int64
		for _, x := range tables.Staples {
			if x.HomeID != homeID || !x.Present() {
				continue
			}
			if x.ItemID == itemID {
				found = true
				if x.Section == name {
					return nil, nil
				}
			}
			if x.Sort > last {
				last = x.Sort
			}
		}
		if !found {
			return nil, domain.ErrNotFound
		}
		// after every staple there is: last in its section, and a new section last of all
		return []fold.Event{s.guestEvent(sc, "staple.added", map[string]any{"home_id": homeID, "item_id": itemID, "sort": last + 1000, "section": name})}, nil
	})
}

// WebRenameSection renames a section of the home, or with "" dissolves it:
// each of its staples is added again under the new name, in its place.
// Another section's name joins the two.
func (s *Service) WebRenameSection(ctx context.Context, sc domain.Scope, credentialID, homeID, old, typed string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.webEvents(ctx, sc, credentialID, func(q *db.Queries) ([]fold.Event, error) {
		tables, err := foldsql.New(ctx, q, sc.HouseholdID).Tables()
		if err != nil {
			return nil, err
		}
		name, err := sectionName(typed, tables.Staples, homeID)
		if err != nil {
			return nil, err
		}
		var evs []fold.Event
		for _, x := range tables.Staples {
			if x.HomeID == homeID && x.Present() && x.Section == old && old != "" && x.Section != name {
				evs = append(evs, s.guestEvent(sc, "staple.added", map[string]any{"home_id": homeID, "item_id": x.ItemID, "sort": x.Sort, "section": name}))
			}
		}
		return evs, nil
	})
}
