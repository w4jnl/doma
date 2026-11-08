package logos

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"
)

// Card is what the worker needs to know about a card.
type Card struct {
	Name     string
	Domain   string
	LogoID   string
	Archived bool
}

// Registry is what the worker needs from the service.
type Registry interface {
	// CardForLogo loads the card's name, website and current logo.
	CardForLogo(ctx context.Context, householdID, cardID string) (*Card, error)
	// StoreLogo keeps the PNG for the card, tells the phones with a
	// card.logo event unless the card already shows this picture, and
	// returns the logo id.
	StoreLogo(ctx context.Context, householdID, cardID string, png []byte) (string, error)
}

// Fetcher is logo.dev: the Client, or a stand-in in tests.
type Fetcher interface {
	Fetch(ctx context.Context, domain, name string) (*Logo, error)
}

// Retries is how often a brand still being indexed is asked about again.
const Retries = 2

type job struct {
	householdID, cardID string
	attempt             int
}

// Worker fetches logos for cards as they are added or edited, one at a
// time, off the request path.
type Worker struct {
	reg   Registry
	fetch Fetcher
	log   *slog.Logger
	jobs  chan job
	mu    sync.Mutex
	last  string
	// after schedules a retry; tests shorten it
	after func(time.Duration, func()) *time.Timer
}

// New builds the worker; Run drains its queue.
func New(reg Registry, fetch Fetcher, log *slog.Logger) *Worker {
	return &Worker{reg: reg, fetch: fetch, log: log, jobs: make(chan job, 64), after: time.AfterFunc}
}

// Enqueue asks for the logo of a card that was just added or edited; it
// never blocks, and a full queue drops the request with a line in the log.
func (w *Worker) Enqueue(householdID, cardID string) {
	w.enqueue(job{householdID: householdID, cardID: cardID})
}

func (w *Worker) enqueue(j job) {
	select {
	case w.jobs <- j:
	default:
		w.log.Warn("logo queue full, card skipped", "household", j.householdID, "card", j.cardID)
	}
}

// LastError is the newest failure, for the admin's server page; empty when
// the last fetch went well.
func (w *Worker) LastError() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.last
}

func (w *Worker) setLast(err error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if err != nil {
		w.last = err.Error()
	} else {
		w.last = ""
	}
}

// Run takes jobs until ctx ends.
func (w *Worker) Run(ctx context.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case j := <-w.jobs:
			err := w.Handle(ctx, j.householdID, j.cardID)
			var pending *PendingError
			if errors.As(err, &pending) && j.attempt < Retries {
				j.attempt++
				w.after(pending.After, func() {
					if ctx.Err() == nil {
						w.enqueue(j)
					}
				})
				continue
			}
			w.setLast(err)
			if err != nil && !errors.Is(err, context.Canceled) {
				w.log.Warn("logo", "household", j.householdID, "card", j.cardID, "err", err)
			}
		}
	}
}

// Handle fetches one card's logo and stores it. A shop logo.dev does not
// know is no error: the card keeps its initials.
func (w *Worker) Handle(ctx context.Context, householdID, cardID string) error {
	c, err := w.reg.CardForLogo(ctx, householdID, cardID)
	if err != nil {
		return err
	}
	if c.Archived {
		return nil
	}
	logo, err := w.fetch.Fetch(ctx, c.Domain, c.Name)
	if errors.Is(err, ErrNoLogo) {
		w.log.Info("no logo", "household", householdID, "card", cardID, "domain", c.Domain)
		return nil
	}
	if err != nil {
		return err
	}
	id, err := w.reg.StoreLogo(ctx, householdID, cardID, logo.PNG)
	if err != nil {
		return err
	}
	w.log.Info("logo fetched", "household", householdID, "card", cardID, "domain", c.Domain, "logo", id, "changed", id != c.LogoID)
	return nil
}
