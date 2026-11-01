package service

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
)

// GuestLink is one guest: a throwaway person with a guest_link credential
// and a guest membership on one home and one list.
type GuestLink struct {
	PersonID     string
	CredentialID string
	Label        string
	HomeID       string
	ListID       string
	ExpiresAt    int64
	CreatedAt    int64
	LastUsedAt   *int64
	Revoked      bool
}

// Active reports whether the link still opens.
func (g GuestLink) Active(now int64) bool { return !g.Revoked && g.ExpiresAt > now }

// NewGuest is a fresh link with its one-time token and URL.
type NewGuest struct {
	Link  GuestLink
	Token string
	URL   string
}

// GuestURL is the link a guest opens.
func (s *Service) GuestURL(token string) string { return s.cfg.BaseURL + "/g/" + token }

// CreateGuestLink makes a guest for one home and one list; owners only.
// days of 0 takes invites.guest_default_days.
func (s *Service) CreateGuestLink(ctx context.Context, sc domain.Scope, homeID, listID, label string, days int) (*NewGuest, error) {
	if err := requireOwner(sc); err != nil {
		return nil, err
	}
	label = strings.TrimSpace(label)
	if label == "" || len(label) > 64 {
		return nil, domain.Invalid("label", "say who the link is for, in up to 64 characters")
	}
	if days <= 0 {
		days = s.cfg.GuestDays
	}
	if days > 365 {
		return nil, domain.Invalid("days", "at most 365 days")
	}
	token, err := auth.NewToken()
	if err != nil {
		return nil, err
	}
	now := s.nowMs()
	g := GuestLink{PersonID: domain.NewID(), CredentialID: domain.NewID(), Label: label, HomeID: homeID, ListID: listID, ExpiresAt: domain.Millis(s.now().Add(time.Duration(days) * 24 * time.Hour)), CreatedAt: now}
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		if _, err := q.GetHome(ctx, db.GetHomeParams{HouseholdID: sc.HouseholdID, ID: homeID}); err != nil {
			return domain.Invalid("home_id", "no such home")
		}
		l, err := q.GetList(ctx, db.GetListParams{HouseholdID: sc.HouseholdID, ID: listID})
		if err != nil || l.OwnerPersonID != nil {
			return domain.Invalid("list_id", "no such shared list")
		}
		if err := q.InsertPerson(ctx, db.InsertPersonParams{ID: g.PersonID, DisplayName: label, CreatedAt: now}); err != nil {
			return err
		}
		if err := q.InsertCredential(ctx, db.InsertCredentialParams{ID: g.CredentialID, PersonID: g.PersonID, Kind: domain.KindGuestLink, Hash: auth.HashToken(token), Label: label, Platform: "web", CreatedAt: now}); err != nil {
			return err
		}
		return q.InsertMembership(ctx, db.InsertMembershipParams{PersonID: g.PersonID, HouseholdID: sc.HouseholdID, Role: string(domain.RoleGuest), HomeID: &homeID, ListID: &listID, ExpiresAt: &g.ExpiresAt, CreatedAt: now})
	})
	if err != nil {
		return nil, err
	}
	return &NewGuest{Link: g, Token: token, URL: s.GuestURL(token)}, nil
}

// Guests lists the household's guest links; owners only.
func (s *Service) Guests(ctx context.Context, sc domain.Scope) ([]GuestLink, error) {
	if err := requireOwner(sc); err != nil {
		return nil, err
	}
	rows, err := s.db.Read().GuestsForHousehold(ctx, sc.HouseholdID)
	if err != nil {
		return nil, err
	}
	out := make([]GuestLink, 0, len(rows))
	for _, r := range rows {
		g := GuestLink{PersonID: r.PersonID, CredentialID: r.CredentialID, Label: r.Label, CreatedAt: r.CreatedAt, LastUsedAt: r.LastUsedAt, Revoked: r.RevokedAt != nil}
		if r.HomeID != nil {
			g.HomeID = *r.HomeID
		}
		if r.ListID != nil {
			g.ListID = *r.ListID
		}
		if r.ExpiresAt != nil {
			g.ExpiresAt = *r.ExpiresAt
		}
		out = append(out, g)
	}
	return out, nil
}

// RevokeGuest ends a guest link now; owners only.
func (s *Service) RevokeGuest(ctx context.Context, sc domain.Scope, credentialID string) error {
	if err := requireOwner(sc); err != nil {
		return err
	}
	now := s.nowMs()
	return s.db.Tx(ctx, func(q *db.Queries) error {
		c, err := q.GetCredential(ctx, credentialID)
		if err != nil || c.Kind != domain.KindGuestLink {
			return domain.ErrNotFound
		}
		n, err := q.ExpireGuest(ctx, db.ExpireGuestParams{ExpiresAt: &now, HouseholdID: sc.HouseholdID, PersonID: c.PersonID})
		if err != nil {
			return err
		}
		if n == 0 {
			return domain.ErrNotFound
		}
		_, err = q.RevokeCredential(ctx, db.RevokeCredentialParams{RevokedAt: &now, ID: credentialID})
		return err
	})
}

// GuestScope resolves a guest token to its scope: unknown, revoked or
// expired is ErrNotFound.
func (s *Service) GuestScope(ctx context.Context, token string) (domain.Scope, string, error) {
	if len(token) < 20 || len(token) > 64 {
		return domain.Scope{}, "", domain.ErrNotFound
	}
	q := s.db.Read()
	c, err := q.GetCredentialByHash(ctx, auth.HashToken(token))
	if err != nil || c.Kind != domain.KindGuestLink || c.RevokedAt != nil {
		return domain.Scope{}, "", domain.ErrNotFound
	}
	ms, err := q.MembershipsForPerson(ctx, c.PersonID)
	if err != nil || len(ms) != 1 {
		return domain.Scope{}, "", domain.ErrNotFound
	}
	m := ms[0]
	if m.Role != string(domain.RoleGuest) || m.HomeID == nil || m.ListID == nil || (m.ExpiresAt != nil && *m.ExpiresAt <= s.nowMs()) {
		return domain.Scope{}, "", domain.ErrNotFound
	}
	s.Touch(ctx, c.ID, c.PersonID)
	return domain.Scope{HouseholdID: m.HouseholdID, PersonID: c.PersonID, Role: domain.RoleGuest, HomeID: *m.HomeID, ListID: *m.ListID}, c.ID, nil
}

// MissingItem is a staple at the guest's home that is not there.
type MissingItem struct {
	ItemName string
	State    string // out, low or unknown
	// SetAt is when the flag was set, zero for unknown-without-a-flag.
	SetAt int64
}

// GuestEntry is one row of the guest's list.
type GuestEntry struct {
	ID        string
	ItemName  string
	Qty       *float64
	Unit      string
	Note      string
	Checked   bool
	CheckedBy string
}

// GuestView is what the guest page shows.
type GuestView struct {
	HomeName string
	ListName string
	Missing  []MissingItem
	Entries  []GuestEntry
	// AnyOut switches the favicon to the alert tile.
	AnyOut bool
}

// GuestView reads the guest's home and list.
func (s *Service) GuestView(ctx context.Context, sc domain.Scope) (*GuestView, error) {
	if !sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	var v GuestView
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		h, err := q.GetHousehold(ctx, sc.HouseholdID)
		if err != nil {
			return notFound(err)
		}
		home, err := q.GetHome(ctx, db.GetHomeParams{HouseholdID: sc.HouseholdID, ID: sc.HomeID})
		if err != nil {
			return notFound(err)
		}
		list, err := q.GetList(ctx, db.GetListParams{HouseholdID: sc.HouseholdID, ID: sc.ListID})
		if err != nil {
			return notFound(err)
		}
		v.HomeName, v.ListName = home.Name, list.Name
		tables, err := foldsql.New(ctx, q, sc.HouseholdID).Tables()
		if err != nil {
			return err
		}
		names := map[string]string{}
		for _, it := range tables.Items {
			names[it.ID] = it.Name
		}
		persons := map[string]string{}
		staleness := time.Duration(s.StalenessDays(ptr(household(h)))) * 24 * time.Hour
		flags := map[string]fold.Flag{}
		for _, f := range tables.Flags {
			if f.HomeID == sc.HomeID {
				flags[f.ItemID] = f
			}
		}
		for _, st := range tables.Staples {
			if st.HomeID != sc.HomeID || !st.Present() {
				continue
			}
			state, setAt := "unknown", int64(0)
			if f, ok := flags[st.ItemID]; ok {
				if s.now().Sub(f.SetHLC.Time()) < staleness {
					state = f.State
				}
				setAt = f.SetHLC.Wall
			}
			if state == "have" {
				continue
			}
			if state == "out" {
				v.AnyOut = true
			}
			v.Missing = append(v.Missing, MissingItem{ItemName: nameOf(names, st.ItemID), State: state, SetAt: setAt})
		}
		sort.Slice(v.Missing, func(i, j int) bool {
			if v.Missing[i].State != v.Missing[j].State {
				return rank(v.Missing[i].State) < rank(v.Missing[j].State)
			}
			return v.Missing[i].ItemName < v.Missing[j].ItemName
		})
		var open []fold.Entry
		for _, e := range tables.Entries {
			if e.ListID == sc.ListID && e.ClearedHLC == nil {
				open = append(open, e)
			}
		}
		sort.Slice(open, func(i, j int) bool {
			ci, cj := open[i].CheckedHLC != nil, open[j].CheckedHLC != nil
			if ci != cj {
				return !ci
			}
			if ci && cj {
				return open[j].CheckedHLC.Less(*open[i].CheckedHLC)
			}
			return open[i].Sort < open[j].Sort
		})
		for _, e := range open {
			ge := GuestEntry{ID: e.ID, ItemName: nameOf(names, e.ItemID), Qty: e.Qty, Note: e.Note, Checked: e.CheckedHLC != nil}
			if e.Unit != nil {
				ge.Unit = *e.Unit
			}
			if e.CheckedBy != nil {
				if _, ok := persons[*e.CheckedBy]; !ok {
					if p, err := q.GetPerson(ctx, *e.CheckedBy); err == nil {
						persons[*e.CheckedBy] = p.DisplayName
					}
				}
				ge.CheckedBy = persons[*e.CheckedBy]
			}
			v.Entries = append(v.Entries, ge)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &v, nil
}

func rank(state string) int {
	switch state {
	case "out":
		return 0
	case "low":
		return 1
	}
	return 2
}

func nameOf(names map[string]string, id string) string {
	if n, ok := names[id]; ok {
		return n
	}
	return id
}

// guestEvent is an event the server appends on a guest's behalf.
func (s *Service) guestEvent(sc domain.Scope, kind string, payload map[string]any) fold.Event {
	e := s.systemEvent(kind, payload)
	e.PersonID = sc.PersonID
	return e
}

// GuestAdd adds a typed line to the guest's list through the same item
// matching as the app: an existing item by normalised name, else a new one.
func (s *Service) GuestAdd(ctx context.Context, sc domain.Scope, credentialID, text string) error {
	if !sc.IsGuest() {
		return domain.ErrForbidden
	}
	parsed := domain.ParseEntry(text)
	if parsed.Name == "" || len(parsed.Name) > 200 {
		return domain.Invalid("text", "type what to get")
	}
	norm := domain.NormName(parsed.Name)
	return s.db.Tx(ctx, func(q *db.Queries) error {
		items, err := q.ListItems(ctx, sc.HouseholdID)
		if err != nil {
			return err
		}
		itemID := ""
		for _, it := range items {
			if it.MergedInto == nil && it.NormName != nil && *it.NormName == norm {
				itemID = it.ID
				break
			}
		}
		if itemID == "" {
			aliases, err := q.ListAliases(ctx, sc.HouseholdID)
			if err != nil {
				return err
			}
			for _, a := range aliases {
				if a.NormName == norm {
					itemID = a.ItemID
					break
				}
			}
		}
		var evs []fold.Event
		if itemID == "" {
			itemID = domain.NewID()
			evs = append(evs, s.guestEvent(sc, "item.named", map[string]any{"item_id": itemID, "name": parsed.Name}))
		}
		payload := map[string]any{"list_id": sc.ListID, "item_id": itemID, "note": parsed.Note}
		if parsed.Qty != nil {
			payload["qty"] = *parsed.Qty
			payload["unit"] = parsed.Unit
		}
		evs = append(evs, s.guestEvent(sc, "entry.added", payload))
		return s.appendEvents(ctx, q, sc.HouseholdID, credentialID, evs)
	})
}

// GuestToggle strikes an open entry of the guest's list or restores it.
func (s *Service) GuestToggle(ctx context.Context, sc domain.Scope, credentialID, entryID string) error {
	if !sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.db.Tx(ctx, func(q *db.Queries) error {
		st := foldsql.New(ctx, q, sc.HouseholdID)
		rows, err := st.Entries(sc.ListID, nil)
		if err != nil {
			return err
		}
		for _, e := range rows {
			if e.ID != entryID || e.ClearedHLC != nil {
				continue
			}
			kind := "entry.checked"
			if e.CheckedHLC != nil {
				kind = "entry.unchecked"
			}
			ev := s.guestEvent(sc, kind, map[string]any{"list_id": sc.ListID, "item_id": e.ItemID})
			return s.appendEvents(ctx, q, sc.HouseholdID, credentialID, []fold.Event{ev})
		}
		return domain.ErrNotFound
	})
}

// GuestClear removes the struck entries of the guest's list.
func (s *Service) GuestClear(ctx context.Context, sc domain.Scope, credentialID string) error {
	if !sc.IsGuest() {
		return domain.ErrForbidden
	}
	return s.db.Tx(ctx, func(q *db.Queries) error {
		ev := s.guestEvent(sc, "entry.cleared", map[string]any{"list_id": sc.ListID, "before_hlc": s.clock.Next().String()})
		return s.appendEvents(ctx, q, sc.HouseholdID, credentialID, []fold.Event{ev})
	})
}

var _ = fmt.Sprint
