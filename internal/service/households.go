package service

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
)

// DefaultListName is the name of the list every household starts with.
const DefaultListName = "Shopping"

func dbInsertAdmin(login, hash string, now int64) db.InsertAdminParams {
	return db.InsertAdminParams{Login: login, PasswordHash: hash, CreatedAt: now}
}

func household(r db.Household) domain.Household {
	return domain.Household{ID: r.ID, Slug: r.Slug, Name: r.Name, Timezone: r.Timezone, QuotaDevices: r.QuotaDevices, QuotaPhotoBytes: r.QuotaPhotoBytes, StalenessDays: r.StalenessDays, CreatedAt: r.CreatedAt}
}

var slugStrip = regexp.MustCompile(`[^a-z0-9]+`)

// slugify makes the export-path form of a name.
func slugify(name string) string {
	s := strings.Trim(slugStrip.ReplaceAllString(strings.ToLower(domain.NormName(name)), "-"), "-")
	if s == "" {
		s = "household"
	}
	if len(s) > 40 {
		s = strings.Trim(s[:40], "-")
	}
	return s
}

func validName(field, name string, max int) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", domain.Invalid(field, "give a name")
	}
	if len(name) > max {
		return "", domain.Invalid(field, "use at most %d characters", max)
	}
	return name, nil
}

func validTimezone(tz string) (string, error) {
	tz = strings.TrimSpace(tz)
	if tz == "" {
		return "", domain.Invalid("timezone", "give a time zone such as Europe/Amsterdam")
	}
	if _, err := time.LoadLocation(tz); err != nil {
		return "", domain.Invalid("timezone", "%q is not a time zone name", tz)
	}
	return tz, nil
}

// CreateHousehold makes a household with its default list and its first
// home, both as events the server appends, so every client folds them the
// same way. The admin and, later, an owner from the app call it.
func (s *Service) CreateHousehold(ctx context.Context, name, timezone, firstHome string) (*domain.Household, error) {
	name, err := validName("name", name, 100)
	if err != nil {
		return nil, err
	}
	timezone, err = validTimezone(timezone)
	if err != nil {
		return nil, err
	}
	firstHome, err = validName("home", firstHome, 100)
	if err != nil {
		return nil, err
	}
	h := domain.Household{ID: domain.NewID(), Name: name, Timezone: timezone, CreatedAt: s.nowMs()}
	base := slugify(name)
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		for n := 1; ; n++ {
			h.Slug = base
			if n > 1 {
				h.Slug = fmt.Sprintf("%s-%d", base, n)
			}
			err := q.InsertHousehold(ctx, db.InsertHouseholdParams{ID: h.ID, Slug: h.Slug, Name: h.Name, Timezone: h.Timezone, CreatedAt: h.CreatedAt})
			if err == nil {
				break
			}
			if !db.IsUniqueViolation(err) || n > 50 {
				return err
			}
		}
		evs := []fold.Event{
			s.systemEvent("list.created", map[string]any{"list_id": domain.NewID(), "name": DefaultListName, "colour": "", "owner_person_id": nil, "default": true}),
			s.systemEvent("home.created", map[string]any{"home_id": domain.NewID(), "name": firstHome}),
		}
		_, err := s.appendEvents(ctx, q, h.ID, domain.SystemPerson, evs)
		return err
	})
	if err != nil {
		return nil, err
	}
	s.log.Info("household created", "household", h.ID, "slug", h.Slug)
	return &h, nil
}

// Household returns the scope's household.
func (s *Service) Household(ctx context.Context, sc domain.Scope) (*domain.Household, error) {
	if sc.HouseholdID == "" {
		return nil, errNoHousehold
	}
	return s.HouseholdByID(ctx, sc.HouseholdID)
}

// HouseholdByID is for the admin pages and the invite flow; callers with a
// scope use Household.
func (s *Service) HouseholdByID(ctx context.Context, id string) (*domain.Household, error) {
	r, err := s.db.Read().GetHousehold(ctx, id)
	if err != nil {
		return nil, notFound(err)
	}
	h := household(r)
	return &h, nil
}

// Households lists every household, for the admin.
func (s *Service) Households(ctx context.Context) ([]domain.Household, error) {
	rows, err := s.db.Read().ListHouseholds(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]domain.Household, 0, len(rows))
	for _, r := range rows {
		out = append(out, household(r))
	}
	return out, nil
}

// HouseholdUpdate is what an owner may change.
type HouseholdUpdate struct {
	Name          string
	Timezone      string
	StalenessDays *int64
}

// UpdateHousehold renames the household and sets its time zone and
// staleness; owners only.
func (s *Service) UpdateHousehold(ctx context.Context, sc domain.Scope, u HouseholdUpdate) (*domain.Household, error) {
	if err := requireOwner(sc); err != nil {
		return nil, err
	}
	name, err := validName("name", u.Name, 100)
	if err != nil {
		return nil, err
	}
	tz, err := validTimezone(u.Timezone)
	if err != nil {
		return nil, err
	}
	if u.StalenessDays != nil && (*u.StalenessDays < 14 || *u.StalenessDays > 365) {
		return nil, domain.Invalid("staleness_days", "use between 14 and 365 days")
	}
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		if _, err := q.GetHousehold(ctx, sc.HouseholdID); err != nil {
			return notFound(err)
		}
		return q.UpdateHousehold(ctx, db.UpdateHouseholdParams{Name: name, Timezone: tz, StalenessDays: u.StalenessDays, ID: sc.HouseholdID})
	})
	if err != nil {
		return nil, err
	}
	return s.HouseholdByID(ctx, sc.HouseholdID)
}

// DeleteHousehold removes a household, members or not; the admin only,
// asked twice on the page. Rows cascade, the photo directory goes with
// them, and so does every person left with no household. A member's
// phone is told nothing: its next sync of that household is refused and
// Leave this household removes it there.
func (s *Service) DeleteHousehold(ctx context.Context, id string) error {
	err := s.db.Tx(ctx, func(q *db.Queries) error {
		if _, err := q.GetHousehold(ctx, id); err != nil {
			return notFound(err)
		}
		if err := q.DeleteHousehold(ctx, id); err != nil {
			return err
		}
		// members who belonged nowhere else go with it, their devices and device invites
		// through the cascade; a member of another household keeps their person and devices
		return q.DeleteOrphanPersons(ctx)
	})
	if err == nil {
		s.removePhotoDir(id)
	}
	return err
}

// StalenessDays is the household's threshold, or the server default.
func (s *Service) StalenessDays(h *domain.Household) int {
	if h != nil && h.StalenessDays != nil {
		return int(*h.StalenessDays)
	}
	return s.cfg.StalenessDays
}
