// Package service owns the rules, the transactions and the fold. Every
// method on household data takes a domain.Scope first; handlers are thin
// and call one method each. Errors are domain sentinels, never sql.ErrNoRows.
package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
)

// Config is what the service needs from doma.toml.
type Config struct {
	// BaseURL builds invite and guest links.
	BaseURL          string
	InviteDays       int
	GuestDays        int
	StalenessDays    int
	MaxEventsPerSync int
}

// Service is the one service layer.
type Service struct {
	db    *db.DB
	cfg   Config
	log   *slog.Logger
	now   func() time.Time
	clock *domain.Clock
}

// New builds the service. The server's own events carry the device id
// "doma" on their stamps.
func New(d *db.DB, cfg Config, log *slog.Logger) *Service {
	if cfg.InviteDays <= 0 {
		cfg.InviteDays = 7
	}
	if cfg.GuestDays <= 0 {
		cfg.GuestDays = 7
	}
	if cfg.StalenessDays <= 0 {
		cfg.StalenessDays = 60
	}
	if cfg.MaxEventsPerSync <= 0 {
		cfg.MaxEventsPerSync = 500
	}
	s := &Service{db: d, cfg: cfg, log: log, now: func() time.Time { return time.Now().UTC() }}
	s.clock, _ = domain.NewClock(domain.SystemPerson, s.now)
	return s
}

// SetClock replaces the clock, for tests.
func (s *Service) SetClock(now func() time.Time) {
	s.now = now
	s.clock, _ = domain.NewClock(domain.SystemPerson, now)
}

// DB exposes the pools to the health check.
func (s *Service) DB() *db.DB { return s.db }

// BaseURL is the public address without a trailing slash.
func (s *Service) BaseURL() string { return s.cfg.BaseURL }

func (s *Service) nowMs() int64 { return domain.Millis(s.now()) }

// systemEvent makes a server-originated event.
func (s *Service) systemEvent(kind string, payload any) fold.Event {
	raw, _ := json.Marshal(payload)
	return fold.Event{ID: domain.NewID(), PersonID: domain.SystemPerson, HLC: s.clock.Next(), Kind: kind, Payload: raw}
}

// appendEvents appends and folds events for a household inside q's
// transaction.
func (s *Service) appendEvents(ctx context.Context, q *db.Queries, householdID, credentialID string, evs []fold.Event) error {
	st := foldsql.New(ctx, q, householdID)
	for _, e := range evs {
		if _, _, err := st.Append(e, credentialID, s.nowMs()); err != nil {
			return fmt.Errorf("append %s: %w", e.Kind, err)
		}
	}
	return nil
}

// notFound turns a missing row into ErrNotFound and keeps other errors.
func notFound(err error) error {
	if db.IsNotFound(err) {
		return domain.ErrNotFound
	}
	return err
}

// requireOwner is the role check every owner-only method starts with.
func requireOwner(sc domain.Scope) error {
	if sc.Role != domain.RoleOwner {
		return fmt.Errorf("%w: owners only", domain.ErrForbidden)
	}
	return nil
}

// requireMember refuses guests.
func requireMember(sc domain.Scope) error {
	if !sc.Role.AtLeast(domain.RoleMember) {
		return fmt.Errorf("%w: members only", domain.ErrForbidden)
	}
	return nil
}

var errNoHousehold = errors.New("scope has no household")
