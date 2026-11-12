// Package fold applies events to the materialised tables. It is the only
// code that writes those tables from events, on the server and, as a Swift
// port under app/shared/Fold, on the phones; both are tested against
// docs/fixtures/fold.json.
//
// The fold is pure: it reads and writes through a Store and does no I/O of
// its own. Its rules are written so that any arrival order of the same
// events gives the same tables:
//
//   - single values (names, colours, flags) are last-writer-wins on the
//     event's hybrid logical clock stamp, kept next to the value;
//   - sets (staples) keep the latest add and the latest remove and derive
//     presence from the two;
//   - the catalog (items, which ids are one item, aliases) is derived by
//     replaying every item event in stamp order with the sequential rules of
//     the design document: a name goes to the item that took it first, a
//     later namesake is the same item, a rename into an existing name joins
//     it, a merge keeps the dropped name as an alias; when that changes which
//     item an id belongs to, the flags, staples and entries of the items
//     involved are re-derived from the log;
//   - entries, the one structure with eras (open, checked, cleared, re-added),
//     are derived per (list, item) by replaying that key's events in stamp
//     order, so a re-add after a clear lands in the right era whatever order
//     the events arrive in.
//
// Events are idempotent by id (the Store keeps the log, and a replay reads
// it) and an unknown kind is skipped, so an old app survives a new server.
package fold

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/w4jnl/doma/internal/domain"
)

// Event is one log entry as the fold sees it: the client's fields and the
// person the server (or the app, for its own events) attributes it to.
type Event struct {
	ID       string          `json:"id"`
	PersonID string          `json:"person_id"`
	HLC      domain.HLC      `json:"hlc"`
	Kind     string          `json:"kind"`
	Payload  json.RawMessage `json:"payload"`
}

// Row types mirror the materialised tables.

type Item struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	NormName   *string    `json:"norm_name"`
	Category   *string    `json:"category"`
	LastUsedAt *int64     `json:"last_used_at"`
	UseCount   int64      `json:"use_count"`
	ArchivedAt *int64     `json:"archived_at"`
	MergedInto *string    `json:"merged_into"`
	CreatedHLC domain.HLC `json:"created_hlc"`
	UpdatedHLC domain.HLC `json:"updated_hlc"`
}

type Alias struct {
	ItemID   string `json:"item_id"`
	NormName string `json:"norm_name"`
}

type List struct {
	ID            string      `json:"id"`
	Name          string      `json:"name"`
	Colour        string      `json:"colour"`
	OwnerPersonID *string     `json:"owner_person_id"`
	Sort          int64       `json:"sort"`
	IsDefault     bool        `json:"is_default"`
	ArchivedAt    *int64      `json:"archived_at"`
	UpdatedHLC    *domain.HLC `json:"updated_hlc"`
	// Kind is "" for a shopping list and "tasks" for things to do; set by list.created.
	Kind string `json:"kind,omitempty"`
}

type Entry struct {
	ID         string      `json:"id"`
	ListID     string      `json:"list_id"`
	ItemID     string      `json:"item_id"`
	Note       string      `json:"note"`
	Qty        *float64    `json:"qty"`
	Unit       *string     `json:"unit"`
	ForHomeID  *string     `json:"for_home_id"`
	Sort       float64     `json:"sort"`
	AddedHLC   domain.HLC  `json:"added_hlc"`
	AddedBy    string      `json:"added_by"`
	CheckedHLC *domain.HLC `json:"checked_hlc"`
	CheckedBy  *string     `json:"checked_by"`
	ClearedHLC *domain.HLC `json:"cleared_hlc"`
}

type Flag struct {
	HomeID string     `json:"home_id"`
	ItemID string     `json:"item_id"`
	State  string     `json:"state"`
	SetHLC domain.HLC `json:"set_hlc"`
	SetBy  string     `json:"set_by"`
	Note   string     `json:"note"`
}

type Staple struct {
	HomeID string `json:"home_id"`
	ItemID string `json:"item_id"`
	Sort   int64  `json:"sort"`
	// Section names the group the staple is shown under, "" for none.
	Section string `json:"section"`
	// SectionHLC is the latest add that named a section, nil when none has.
	SectionHLC *domain.HLC `json:"section_hlc"`
	// AddedHLC is the latest add, nil when only a remove has been seen.
	AddedHLC   *domain.HLC `json:"added_hlc"`
	RemovedHLC *domain.HLC `json:"removed_hlc"`
}

// Present reports whether the staple is on the home's list: the latest add
// is newer than the latest remove.
func (s Staple) Present() bool {
	return s.AddedHLC != nil && (s.RemovedHLC == nil || s.RemovedHLC.Less(*s.AddedHLC))
}

type Home struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Sort       int64       `json:"sort"`
	ArchivedAt *int64      `json:"archived_at"`
	UpdatedHLC *domain.HLC `json:"updated_hlc"`
}

type Spot struct {
	ID         string      `json:"id"`
	HomeID     string      `json:"home_id"`
	Name       string      `json:"name"`
	Sort       int64       `json:"sort"`
	ArchivedAt *int64      `json:"archived_at"`
	UpdatedHLC *domain.HLC `json:"updated_hlc"`
}

type Photo struct {
	ID      string     `json:"id"`
	SpotID  string     `json:"spot_id"`
	TakenAt domain.HLC `json:"taken_hlc"`
	TakenBy string     `json:"taken_by"`
	Bytes   int64      `json:"bytes"`
	Width   int64      `json:"width"`
	Height  int64      `json:"height"`
}

// Card is a loyalty card: the household's (OwnerPersonID nil) or one
// person's, with its barcode and, once the server fetched it, its logo.
// LogoHLC is the stamp of the card.logo that brought the logo: logos are
// last-writer-wins among themselves, apart from the card's edits.
type Card struct {
	ID            string      `json:"id"`
	Name          string      `json:"name"`
	Colour        string      `json:"colour"`
	OwnerPersonID *string     `json:"owner_person_id"`
	Format        string      `json:"format"`
	Value         string      `json:"value"`
	Domain        *string     `json:"domain"`
	LogoID        *string     `json:"logo_id"`
	UpdatedHLC    *domain.HLC `json:"updated_hlc"`
	ArchivedAt    *int64      `json:"archived_at"`
	LogoHLC       *domain.HLC `json:"logo_hlc"`
}

// Trip is a planned trip (trip.planned, last-writer-wins on UpdatedHLC for
// from, to, date, list and planner), arrived (ArrivedAt), cancelled
// (CancelledAt), or arrived without a plan (the arrival's wall as its date).
type Trip struct {
	ID          string      `json:"id"`
	FromHomeID  string      `json:"from_home_id"`
	ToHomeID    string      `json:"to_home_id"`
	Date        int64       `json:"date"`
	CreatedBy   string      `json:"created_by"`
	ListID      *string     `json:"list_id"`
	UpdatedHLC  *domain.HLC `json:"updated_hlc"`
	ArrivedAt   *int64      `json:"arrived_at"`
	CancelledAt *int64      `json:"cancelled_at"`
}

// Store is the fold's view of one household's tables and log. Get methods
// return nil, nil when there is no row. Put methods upsert. Event methods
// return events in stamp order.
type Store interface {
	Item(id string) (*Item, error)
	Items() ([]Item, error)
	PutItem(Item) error
	// ReplaceAliases replaces the whole alias table.
	ReplaceAliases([]Alias) error
	// MergedIDs returns id and every item id merged into it, transitively.
	MergedIDs(id string) ([]string, error)
	// RecountItemUsage sets use_count and last_used_at from the entries table.
	RecountItemUsage(id string) error
	// ItemEvents returns every item.* event.
	ItemEvents() ([]Event, error)
	// ItemEventsFor returns the flag.set, staple.added, staple.removed and
	// trip.arrived events that name one of the ids.
	ItemEventsFor(itemIDs []string) ([]Event, error)

	List(id string) (*List, error)
	PutList(List) error
	DefaultListID() (string, error)

	// EntryEvents returns every event the key's replay needs: entry events
	// for the list and any of the item ids, clears of the list, and, when
	// the list is the default list, out flags and trip arrivals that name
	// one of the item ids. A nil itemIDs means any item.
	EntryEvents(listID string, itemIDs []string, isDefault bool) ([]Event, error)
	// EntryListIDs returns the lists with entry events naming any of the
	// ids, from the log.
	EntryListIDs(itemIDs []string) ([]string, error)
	// Entries returns the rows for the list and the item ids.
	Entries(listID string, itemIDs []string) ([]Entry, error)
	// ReplaceEntries deletes the rows for the list and the item ids and
	// inserts rows.
	ReplaceEntries(listID string, itemIDs []string, rows []Entry) error
	// ClearedEntriesForHome returns the cleared rows of the item ids that
	// were for the home, on any list.
	ClearedEntriesForHome(itemIDs []string, homeID string) ([]Entry, error)

	Flag(homeID, itemID string) (*Flag, error)
	PutFlag(Flag) error
	DeleteFlag(homeID, itemID string) error
	DeleteFlagsForItems(itemIDs []string) error

	// ReplaceProposals deletes the proposals of the home for the item ids
	// and inserts rows.
	ReplaceProposals(homeID string, itemIDs []string, rows []Proposal) error
	DeleteProposalsForItems(itemIDs []string) error

	Staple(homeID, itemID string) (*Staple, error)
	PutStaple(Staple) error
	DeleteStaplesForItems(itemIDs []string) error

	Home(id string) (*Home, error)
	PutHome(Home) error
	Spot(id string) (*Spot, error)
	PutSpot(Spot) error
	PutPhoto(Photo) error
	Trip(id string) (*Trip, error)
	PutTrip(Trip) error

	Card(id string) (*Card, error)
	PutCard(Card) error
}

// Kinds is every event kind the fold knows, in the order of the design
// document's table.
var Kinds = []string{
	"item.named", "item.renamed", "item.merged", "item.archived",
	"list.created", "list.renamed", "list.archived",
	"entry.added", "entry.edited", "entry.checked", "entry.unchecked", "entry.cleared", "entry.moved", "entry.removed",
	"flag.set", "flag.proposed", "proposal.declined",
	"staple.added", "staple.removed",
	"home.created", "home.renamed", "home.archived",
	"spot.created", "spot.renamed", "spot.archived",
	"photo.added",
	"trip.planned", "trip.cancelled", "trip.arrived",
	"card.added", "card.edited", "card.archived", "card.logo",
	"member.removed", "device.revoked",
}

// ErrPayload is a payload the fold cannot use. The service validates
// payloads against docs/event-schema.json before append, so this is a bug.
var ErrPayload = errors.New("fold: bad payload")

// Apply folds one event into the store. The caller has already appended
// the event to the log the store reads for replays.
func Apply(s Store, e Event) error {
	switch e.Kind {
	case "item.named", "item.renamed", "item.merged", "item.archived":
		return replayCatalog(s)
	case "list.created", "list.renamed", "list.archived":
		return applyList(s, e)
	case "entry.added", "entry.edited", "entry.checked", "entry.unchecked", "entry.moved", "entry.removed":
		return applyEntryEvent(s, e)
	case "entry.cleared":
		return applyEntryCleared(s, e)
	case "flag.set":
		return applyFlagSet(s, e)
	case "flag.proposed", "proposal.declined":
		return applyProposalEvent(s, e)
	case "staple.added", "staple.removed":
		return applyStaple(s, e)
	case "home.created", "home.renamed", "home.archived":
		return applyHome(s, e)
	case "spot.created", "spot.renamed", "spot.archived":
		return applySpot(s, e)
	case "photo.added":
		return applyPhotoAdded(s, e)
	case "trip.planned":
		return applyTripPlanned(s, e)
	case "trip.cancelled":
		return applyTripCancelled(s, e)
	case "trip.arrived":
		return applyTripArrived(s, e)
	case "card.added", "card.edited", "card.archived", "card.logo":
		return applyCard(s, e)
	case "member.removed", "device.revoked":
		// server-originated: memberships and credentials are REST-managed
		// and already changed; the apps act on these in their sync layer
		return nil
	}
	return nil
}

func decode(e Event, into any) error {
	if err := json.Unmarshal(e.Payload, into); err != nil {
		return fmt.Errorf("%w: %s %s: %w", ErrPayload, e.Kind, e.ID, err)
	}
	return nil
}

func need(e Event, field, value string) error {
	if value == "" {
		return fmt.Errorf("%w: %s %s: %s is empty", ErrPayload, e.Kind, e.ID, field)
	}
	return nil
}

func ptr[T any](v T) *T { return &v }

// resolveItem follows merged_into to the owning item. A missing id is
// returned as is: events may name an item whose item.named has not arrived.
func resolveItem(s Store, id string) (string, error) {
	seen := 0
	for {
		it, err := s.Item(id)
		if err != nil {
			return "", err
		}
		if it == nil || it.MergedInto == nil {
			return id, nil
		}
		id = *it.MergedInto
		if seen++; seen > 64 {
			return "", errors.New("fold: merged_into cycle")
		}
	}
}
