package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/logos"
)

// The logo job's view of the service: the card it fetches for, the PNG it
// stores next to the photos under <household>/cards/, and the card.logo
// event it appends as the server so every phone learns of the picture.

// Logoer is told about each card added or edited; the logo worker when
// logos.enabled is on, nothing otherwise.
type Logoer interface {
	Enqueue(householdID, cardID string)
}

// SetLogos hands new and edited cards to the logo worker.
func (s *Service) SetLogos(l Logoer) { s.logos = l }

var logoIDPattern = regexp.MustCompile(`^[0-9a-f]{16}$`)

// logoID names a logo by its bytes, so the same picture fetched twice is
// one logo and the phones download each one once.
func logoID(png []byte) string {
	sum := sha256.Sum256(png)
	return hex.EncodeToString(sum[:8])
}

func logoRel(householdID, cardID, id string) string {
	return householdID + "/cards/" + cardID + "-" + id + ".png"
}

// CardForLogo loads what the worker needs to fetch a card's logo.
func (s *Service) CardForLogo(ctx context.Context, householdID, cardID string) (*logos.Card, error) {
	row, err := s.db.Read().GetCard(ctx, db.GetCardParams{HouseholdID: householdID, ID: cardID})
	if err != nil {
		return nil, notFound(err)
	}
	c := &logos.Card{Name: row.Name, Archived: row.ArchivedAt != nil}
	if row.Domain != nil {
		c.Domain = *row.Domain
	}
	if row.LogoID != nil {
		c.LogoID = *row.LogoID
	}
	return c, nil
}

// StoreLogo keeps the PNG for the card and appends one card.logo as the
// server, with the card's owner so the sync filter keeps a personal card's
// logo with its person. The same picture again changes nothing.
func (s *Service) StoreLogo(ctx context.Context, householdID, cardID string, png []byte) (string, error) {
	if s.cfg.PhotosDir == "" {
		return "", errors.New("no photos directory")
	}
	row, err := s.db.Read().GetCard(ctx, db.GetCardParams{HouseholdID: householdID, ID: cardID})
	if err != nil {
		return "", notFound(err)
	}
	id := logoID(png)
	if row.LogoID != nil && *row.LogoID == id {
		return id, nil
	}
	dir := filepath.Join(s.cfg.PhotosDir, householdID, "cards")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return "", err
	}
	path := s.photoFile(logoRel(householdID, cardID, id))
	if err := writeFile(path, png); err != nil {
		return "", err
	}
	var last int64
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		ev := s.systemEvent("card.logo", map[string]any{"card_id": cardID, "owner_person_id": row.OwnerPersonID, "logo_id": id})
		seq, err := s.appendEvents(ctx, q, householdID, domain.SystemPerson, []fold.Event{ev})
		last = seq
		return err
	})
	if err != nil {
		_ = os.Remove(path)
		return "", err
	}
	// the card's older logos go; a phone still asking for one gets a 404 and the new event
	if old, err := filepath.Glob(filepath.Join(dir, cardID+"-*.png")); err == nil {
		for _, p := range old {
			if p != path {
				_ = os.Remove(p)
			}
		}
	}
	s.changed(householdID, last)
	return id, nil
}

// OpenCardLogo opens a card's current logo for a member; another person's
// personal card, an old logo id or a card without a logo is not found. The
// caller closes it.
func (s *Service) OpenCardLogo(ctx context.Context, sc domain.Scope, cardID, id string) (*os.File, error) {
	if err := requireMember(sc); err != nil {
		return nil, err
	}
	if !logoIDPattern.MatchString(id) {
		return nil, domain.ErrNotFound
	}
	row, err := s.db.Read().GetCard(ctx, db.GetCardParams{HouseholdID: sc.HouseholdID, ID: cardID})
	if err != nil {
		return nil, notFound(err)
	}
	if row.OwnerPersonID != nil && *row.OwnerPersonID != sc.PersonID {
		return nil, domain.ErrNotFound
	}
	if row.LogoID == nil || *row.LogoID != id {
		return nil, domain.ErrNotFound
	}
	f, err := os.OpenInRoot(s.cfg.PhotosDir, filepath.FromSlash(logoRel(sc.HouseholdID, cardID, id)))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, domain.ErrNotFound
	}
	return f, err
}

// logoFiles names the logo files the cards table stands behind and sums
// their size, for the nightly reconcile: they count with the photos and
// a file no card names is swept with the rest.
func (s *Service) logoFiles(ctx context.Context, householdID string, named map[string]bool) (int64, error) {
	cards, err := s.db.Read().ListCards(ctx, householdID)
	if err != nil {
		return 0, err
	}
	var used int64
	for _, c := range cards {
		if c.LogoID == nil {
			continue
		}
		rel := logoRel(householdID, c.ID, *c.LogoID)
		if st, err := os.Stat(s.photoFile(rel)); err == nil {
			named[rel] = true
			used += st.Size()
		}
	}
	return used, nil
}
