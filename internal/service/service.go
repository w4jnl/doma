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
	"net/url"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/w4jnl/doma/internal/bus"
	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
	"github.com/w4jnl/doma/internal/metrics"
	"github.com/w4jnl/doma/internal/secrets"
)

// Config is what the service needs from doma.toml.
type Config struct {
	// BaseURL builds invite and guest links.
	BaseURL          string
	InviteDays       int
	GuestDays        int
	StalenessDays    int
	MaxEventsPerSync int
	ReplayLimit      int
	// SnapshotsDir holds the nightly snapshots; EventsDays and
	// SnapshotsKept drive retention.
	SnapshotsDir  string
	EventsDays    int
	SnapshotsKept int
	// PhotosDir holds the photos; MaxUploadBytes caps one upload and
	// PhotosPerSpot is how many a spot keeps.
	PhotosDir      string
	MaxUploadBytes int64
	PhotosPerSpot  int
}

// Service is the one service layer.
type Service struct {
	db      *db.DB
	cfg     Config
	log     *slog.Logger
	now     func() time.Time
	clock   *domain.Clock
	bus     *bus.Bus
	metrics *metrics.Metrics
	trace   bool
	keyring *secrets.Keyring
	snapMu  sync.Mutex
	lastRun time.Time
	// touched is when each credential was last written as seen, so the
	// bookkeeping of a device that syncs every few seconds is one write a
	// minute, not one per request on the single writer.
	touchMu sync.Mutex
	touched map[string]int64
	// linkKeyBytes signs photo links, derived from the keyring on first use.
	linkMu       sync.Mutex
	linkKeyBytes []byte
	// vouches are browsers waiting for a phone to name who sits at them.
	vouches vouches
	// webauthn is the relying party for passkeys, nil without a base URL.
	webauthn *webauthn.WebAuthn
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
	if cfg.ReplayLimit <= 0 {
		cfg.ReplayLimit = 5000
	}
	if cfg.EventsDays <= 0 {
		cfg.EventsDays = 365
	}
	if cfg.SnapshotsKept <= 0 {
		cfg.SnapshotsKept = 2
	}
	if cfg.MaxUploadBytes <= 0 {
		cfg.MaxUploadBytes = 8 << 20
	}
	if cfg.PhotosPerSpot <= 0 {
		cfg.PhotosPerSpot = 5
	}
	s := &Service{db: d, cfg: cfg, log: log, now: func() time.Time { return time.Now().UTC() }}
	s.clock, _ = domain.NewClock(domain.SystemPerson, s.now)
	if u, err := url.Parse(cfg.BaseURL); err == nil && u.Hostname() != "" {
		// the relying party is the server's host; a browser only offers a passkey to the origin
		// it was made for, so the base URL must be the one the family opens
		s.webauthn, err = webauthn.New(&webauthn.Config{RPID: u.Hostname(), RPDisplayName: "doma", RPOrigins: []string{u.Scheme + "://" + u.Host}})
		if err != nil {
			log.Warn("passkeys off", "err", err)
		}
	}
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
// transaction and returns the last seq, for changed() once the transaction
// has committed.
func (s *Service) appendEvents(ctx context.Context, q *db.Queries, householdID, credentialID string, evs []fold.Event) (int64, error) {
	st := foldsql.New(ctx, q, householdID)
	var last int64
	for _, e := range evs {
		seq, _, err := st.Append(e, credentialID, s.nowMs())
		if err != nil {
			return 0, fmt.Errorf("append %s: %w", e.Kind, err)
		}
		if seq > last {
			last = seq
		}
	}
	return last, nil
}

// changed tells the push side that a household's log grew, up to seq. It is
// called after the transaction that grew it, never inside, so a push never
// reads ahead of a commit. Every writer calls it: the sync exchange, the
// guest page and the server's own events.
func (s *Service) changed(householdID string, seq int64) {
	if seq > 0 && s.bus != nil {
		s.bus.Publish(bus.HouseholdChanged{HouseholdID: householdID, Seq: seq})
	}
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
