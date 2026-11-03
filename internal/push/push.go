// Package push sends one silent APNs push per device when a household's
// log grows, coalesced to one per device per 30 seconds, behind
// push.enabled. It is the only package that opens an outbound connection,
// and it builds its client only when enabled.
package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

// Sender delivers one push: silent, or an alert the person sees, to the
// gateway the device's token belongs to.
type Sender interface {
	Send(ctx context.Context, deviceToken string, payload []byte, alert, sandbox bool) error
}

// Registry is what the pusher needs from the service.
type Registry interface {
	PushTargets(ctx context.Context, householdID string, notBefore int64) ([]Target, error)
	RecordPush(ctx context.Context, householdID, credentialID string, seq int64) error
	ClearPushToken(ctx context.Context, credentialID string) error
	// Changes says what happened after a seq, for the words of an alert.
	Changes(ctx context.Context, householdID string, after, upTo int64) ([]Change, error)
	// Unseen counts what others added after a moment, for the badge.
	Unseen(ctx context.Context, householdID, personID string, sinceMs int64) (int, error)
}

// Sound is the file in the app's bundle a spoken push plays: a soft two-note chime.
const Sound = "chime.caf"

// Target is a device with a token, whose it is, and the seq it last heard.
type Target struct {
	CredentialID string
	Token        string
	PersonID     string
	LastSeq      int64
	LastUsedAt   int64
	Sandbox      bool
}

// Change is one add or clear with its names; the service fills it.
type Change struct {
	PersonID string
	Person   string
	ListID   string
	List     string
	Item     string
	Cleared  bool
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
	silent, _ := json.Marshal(map[string]any{
		"aps":       map[string]any{"content-available": 1},
		"server":    p.baseURL,
		"household": c.HouseholdID,
		"seq":       c.Seq,
	})
	changes := map[int64][]Change{}
	for _, t := range targets {
		// recorded first: a failure still counts as this device's push for
		// the window, so a broken token is not retried every second
		if err := p.reg.RecordPush(ctx, c.HouseholdID, t.CredentialID, c.Seq); err != nil {
			p.log.Error("record push", "err", err)
			continue
		}
		// what the device missed, minus what its own person did: that is the
		// alert; nothing left means a silent push, as before
		payload, alert := silent, false
		if _, ok := changes[t.LastSeq]; !ok {
			ch, err := p.reg.Changes(ctx, c.HouseholdID, t.LastSeq, c.Seq)
			if err != nil {
				p.log.Error("push changes", "err", err, "household", c.HouseholdID)
			}
			changes[t.LastSeq] = ch
		}
		if title, body, thread := Compose(changes[t.LastSeq], t.PersonID); body != "" {
			aps := map[string]any{
				"alert":             map[string]string{"title": title, "body": body},
				"sound":             Sound,
				"thread-id":         thread,
				"content-available": 1,
			}
			// the number on the icon while the app is away: what others added since the
			// device last spoke to us; the app counts for itself once it is open
			if n, err := p.reg.Unseen(ctx, c.HouseholdID, t.PersonID, t.LastUsedAt); err == nil && n > 0 {
				aps["badge"] = n
			}
			payload, _ = json.Marshal(map[string]any{
				"aps":       aps,
				"server":    p.baseURL,
				"household": c.HouseholdID,
				"seq":       c.Seq,
			})
			alert = true
		}
		p.Sent++
		err := p.send.Send(ctx, t.Token, payload, alert, t.Sandbox)
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

// Compose turns the changes since a device last heard into the words of one
// notification for the person who holds it, leaving out what they did
// themselves: "Sam added melk and brood" under the list's name, or "Sam
// cleared Shopping". Nothing to say gives an empty body. The thread is the
// list, so a phone stacks one list's notifications together.
func Compose(changes []Change, forPerson string) (title, body, thread string) {
	var mine []Change
	for _, c := range changes {
		if c.PersonID != forPerson {
			mine = append(mine, c)
		}
	}
	if len(mine) == 0 {
		return "", "", ""
	}
	lists := map[string]bool{}
	people := map[string]bool{}
	var items []string
	seen := map[string]bool{}
	cleared := false
	for _, c := range mine {
		lists[c.ListID] = true
		people[c.Person] = true
		if c.Cleared {
			cleared = true
		} else if c.Item != "" && !seen[c.Item] {
			seen[c.Item] = true
			items = append(items, c.Item)
		}
	}
	who := "The family"
	if len(people) == 1 {
		for name := range people {
			if name != "" {
				who = name
			}
		}
	}
	title = mine[0].List
	thread = mine[0].ListID
	if len(lists) > 1 {
		title = "Lists"
		thread = "lists"
	}
	switch {
	case len(items) == 0 && cleared:
		body = who + " cleared " + mine[0].List
	case len(items) == 1:
		body = who + " added " + items[0]
	case len(items) == 2:
		body = who + " added " + items[0] + " and " + items[1]
	case len(items) == 3:
		body = who + " added " + items[0] + ", " + items[1] + " and " + items[2]
	default:
		body = fmt.Sprintf("%s added %s, %s and %d more", who, items[0], items[1], len(items)-2)
	}
	if cleared && len(items) > 0 {
		body += ", and cleared " + mine[0].List
	}
	return title, body, thread
}
