package vision

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"

	"github.com/w4jnl/doma/internal/domain"
)

// Threshold is the least confidence a judgement needs to become a proposal.
const Threshold = 0.6

// Staple is one of the home's staples with the flag as it stands, after
// staleness: have, low, out or unknown.
type Staple struct {
	ItemID string
	Name   string
	State  string
}

// Photo is what the worker needs to look at one picture.
type Photo struct {
	JPEG    []byte
	Spot    string
	Home    string
	HomeID  string
	Staples []Staple
}

// Proposal is a flag change the model suggests for a member to confirm.
type Proposal struct {
	ItemID string
	State  string
}

// Registry is what the worker needs from the service.
type Registry interface {
	// PhotoForVision loads the picture, its spot and home, and the home's
	// staples; ErrNotFound when the photo has no file.
	PhotoForVision(ctx context.Context, householdID, photoID string) (*Photo, error)
	// ProposeFlags appends one flag.proposed per proposal, as the server.
	ProposeFlags(ctx context.Context, householdID, homeID, photoID string, props []Proposal) error
}

// Looker is the model: the Client, or a stand-in in tests.
type Looker interface {
	Look(ctx context.Context, jpeg []byte, spot, home string, names []string) ([]Seen, error)
}

type job struct{ householdID, photoID string }

// Worker looks at photos as they land, one at a time, off the request path.
type Worker struct {
	reg  Registry
	look Looker
	log  *slog.Logger
	jobs chan job
	mu   sync.Mutex
	last string
}

// New builds the worker; Run drains its queue.
func New(reg Registry, look Looker, log *slog.Logger) *Worker {
	return &Worker{reg: reg, look: look, log: log, jobs: make(chan job, 64)}
}

// Enqueue asks for a look at a photo that just landed; it never blocks, and
// a full queue drops the request with a line in the log.
func (w *Worker) Enqueue(householdID, photoID string) {
	select {
	case w.jobs <- job{householdID, photoID}:
	default:
		w.log.Warn("vision queue full, photo skipped", "household", householdID, "photo", photoID)
	}
}

// LastError is the newest failure, for the admin's server page; empty when
// the last look went well.
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
			err := w.Handle(ctx, j.householdID, j.photoID)
			w.setLast(err)
			if err != nil && !errors.Is(err, context.Canceled) {
				w.log.Warn("vision", "household", j.householdID, "photo", j.photoID, "err", err)
			}
		}
	}
}

// Handle looks at one photo and proposes what differs from the flags.
func (w *Worker) Handle(ctx context.Context, householdID, photoID string) error {
	p, err := w.reg.PhotoForVision(ctx, householdID, photoID)
	if err != nil {
		return err
	}
	if len(p.Staples) == 0 {
		return nil
	}
	names := make([]string, 0, len(p.Staples))
	byNorm := map[string]Staple{}
	for _, st := range p.Staples {
		names = append(names, st.Name)
		byNorm[domain.NormName(st.Name)] = st
	}
	seen, err := w.look.Look(ctx, p.JPEG, p.Spot, p.Home, names)
	if err != nil {
		return err
	}
	var props []Proposal
	done := map[string]bool{}
	for _, s := range seen {
		st, ok := byNorm[domain.NormName(strings.TrimSpace(s.Name))]
		if !ok || s.Confidence < Threshold || done[st.ItemID] || s.State == st.State {
			continue
		}
		done[st.ItemID] = true
		props = append(props, Proposal{ItemID: st.ItemID, State: s.State})
	}
	w.log.Info("vision looked", "household", householdID, "photo", photoID, "spot", p.Spot, "judged", len(seen), "proposed", len(props))
	if len(props) == 0 {
		return nil
	}
	return w.reg.ProposeFlags(ctx, householdID, p.HomeID, photoID, props)
}
