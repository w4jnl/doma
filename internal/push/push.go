// Package push sends one silent APNs push per device when a household's
// log grows, coalesced to one per device per 30 seconds, behind
// push.enabled. It is the only package that opens an outbound connection,
// and it builds its client only when enabled.
package push

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/w4jnl/doma/internal/bus"
	"github.com/w4jnl/doma/internal/metrics"
)

// Coalesce is the least time between two pushes to one device.
const Coalesce = 30 * time.Second

// ErrBadToken is what a Sender returns when Apple says the device token
// is gone; the token is then forgotten.
var ErrBadToken = errors.New("bad device token")

// Sender delivers one silent push.
type Sender interface {
	Send(ctx context.Context, deviceToken string, payload []byte) error
}

// Registry is what the pusher needs from the service.
type Registry interface {
	PushTargets(ctx context.Context, householdID string, notBefore int64) ([]Target, error)
	RecordPush(ctx context.Context, householdID, credentialID string, seq int64) error
	ClearPushToken(ctx context.Context, credentialID string) error
}

// Target is a device with a token.
type Target struct {
	CredentialID string
	Token        string
}

// Pusher listens on the bus and sends.
type Pusher struct {
	reg     Registry
	send    Sender
	baseURL string
	log     *slog.Logger
	metrics *metrics.Metrics
	now     func() time.Time
	// Sent counts pushes handed to the sender, for tests.
	Sent int

	mu      sync.Mutex
	lastErr string
}

// LastError is the most recent failure, "" when the last push went through.
func (p *Pusher) LastError() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.lastErr
}

func (p *Pusher) setErr(err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if err == nil {
		p.lastErr = ""
		return
	}
	p.lastErr = p.now().UTC().Format(time.RFC3339) + " " + err.Error()
}

// New builds a pusher. With a nil sender, which is what push.enabled =
// false gives, Run drains the bus and never sends.
func New(reg Registry, send Sender, baseURL string, log *slog.Logger, m *metrics.Metrics) *Pusher {
	return &Pusher{reg: reg, send: send, baseURL: baseURL, log: log, metrics: m, now: time.Now}
}

// SetClock replaces the clock, for tests.
func (p *Pusher) SetClock(now func() time.Time) { p.now = now }

// Run handles changes until ctx ends.
func (p *Pusher) Run(ctx context.Context, changes <-chan bus.HouseholdChanged) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case c := <-changes:
			p.Handle(ctx, c)
		}
	}
}

// Handle pushes one change to every device of the household that was not
// pushed in the last 30 seconds.
func (p *Pusher) Handle(ctx context.Context, c bus.HouseholdChanged) {
	if p.send == nil {
		return
	}
	notBefore := p.now().Add(-Coalesce).UnixMilli()
	targets, err := p.reg.PushTargets(ctx, c.HouseholdID, notBefore)
	if err != nil {
		p.log.Error("push targets", "err", err, "household", c.HouseholdID)
		return
	}
	payload, _ := json.Marshal(map[string]any{
		"aps":       map[string]any{"content-available": 1},
		"server":    p.baseURL,
		"household": c.HouseholdID,
		"seq":       c.Seq,
	})
	for _, t := range targets {
		// recorded first: a failure still counts as this device's push for
		// the window, so a broken token is not retried every second
		if err := p.reg.RecordPush(ctx, c.HouseholdID, t.CredentialID, c.Seq); err != nil {
			p.log.Error("record push", "err", err)
			continue
		}
		p.Sent++
		err := p.send.Send(ctx, t.Token, payload)
		result := "ok"
		switch {
		case err == nil:
		case errors.Is(err, ErrBadToken):
			result = "bad_token"
			if cerr := p.reg.ClearPushToken(ctx, t.CredentialID); cerr != nil {
				p.log.Error("clear push token", "err", cerr)
			}
		default:
			result = "error"
		}
		if p.metrics != nil {
			p.metrics.Push.WithLabelValues(result).Inc()
		}
		p.setErr(err)
		if err != nil {
			p.log.Warn("push", "result", result, "err", err, "household", c.HouseholdID, "credential", t.CredentialID)
		} else {
			p.log.Info("push", "household", c.HouseholdID, "credential", t.CredentialID, "seq", c.Seq)
		}
	}
}
