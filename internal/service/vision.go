package service

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/vision"
)

// The vision job's view of the service: the picture with its spot, its home
// and the home's staples as they stand, and the proposals it writes back as
// the server's own events.

// Proposer is told about each photo that landed; the vision worker, when
// vision.enabled is on, nothing otherwise.
type Proposer interface {
	Enqueue(householdID, photoID string)
}

// SetVision hands new photos to the vision worker.
func (s *Service) SetVision(p Proposer) { s.vision = p }

// PhotoForVision loads a stored photo with what the model needs to judge it.
func (s *Service) PhotoForVision(ctx context.Context, householdID, photoID string) (*vision.Photo, error) {
	var out vision.Photo
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		row, err := q.GetPhoto(ctx, db.GetPhotoParams{HouseholdID: householdID, ID: photoID})
		if err != nil {
			return notFound(err)
		}
		if row.Path == nil {
			return domain.ErrNotFound
		}
		f, err := os.OpenInRoot(s.cfg.PhotosDir, filepath.FromSlash(*row.Path))
		if errors.Is(err, fs.ErrNotExist) {
			return domain.ErrNotFound
		}
		if err != nil {
			return err
		}
		defer func() { _ = f.Close() }()
		if out.JPEG, err = io.ReadAll(f); err != nil {
			return err
		}
		spot, err := q.GetSpot(ctx, db.GetSpotParams{HouseholdID: householdID, ID: row.SpotID})
		if err != nil {
			return notFound(err)
		}
		home, err := q.GetHome(ctx, db.GetHomeParams{HouseholdID: householdID, ID: spot.HomeID})
		if err != nil {
			return notFound(err)
		}
		out.Spot, out.Home, out.HomeID = spot.Name, home.Name, home.ID
		h, err := s.readHousehold(ctx, q, householdID)
		if err != nil {
			return err
		}
		staples, _ := s.flagRows(h, home.ID)
		for _, r := range staples {
			out.Staples = append(out.Staples, vision.Staple{ItemID: r.ItemID, Name: r.Name, State: r.State})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// ProposeFlags appends one flag.proposed per proposal, as the server, and
// tells the phones.
func (s *Service) ProposeFlags(ctx context.Context, householdID, homeID, photoID string, props []vision.Proposal) error {
	var last int64
	err := s.db.Tx(ctx, func(q *db.Queries) error {
		var evs []fold.Event
		for _, p := range props {
			evs = append(evs, s.systemEvent("flag.proposed", map[string]any{"home_id": homeID, "item_id": p.ItemID, "state": p.State, "photo_id": photoID}))
		}
		seq, err := s.appendEvents(ctx, q, householdID, domain.SystemPerson, evs)
		last = seq
		return err
	})
	if err != nil {
		return err
	}
	s.changed(householdID, last)
	return nil
}
