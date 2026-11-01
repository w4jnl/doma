package service

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
)

// Snapshot is the file the nightly job writes: the materialised tables of
// one household at one seq, as gzip JSON.
type Snapshot struct {
	HouseholdID string      `json:"household_id"`
	Seq         int64       `json:"seq"`
	CreatedAt   int64       `json:"created_at"`
	Tables      fold.Tables `json:"tables"`
}

// RunSnapshots writes a snapshot per household, applies retention and
// drops old snapshot files. The nightly job calls it; the admin page may
// too.
func (s *Service) RunSnapshots(ctx context.Context) error {
	s.snapMu.Lock()
	defer s.snapMu.Unlock()
	hs, err := s.Households(ctx)
	if err != nil {
		return err
	}
	var errs []error
	for _, h := range hs {
		if err := s.snapshotHousehold(ctx, h.ID); err != nil {
			errs = append(errs, fmt.Errorf("household %s: %w", h.ID, err))
			s.log.Error("snapshot", "household", h.ID, "err", err)
			continue
		}
	}
	s.lastRun = s.now()
	if s.metrics != nil {
		s.metrics.Households.Set(float64(len(hs)))
	}
	return errors.Join(errs...)
}

// LastSnapshotRun is when the job last completed, zero before the first.
func (s *Service) LastSnapshotRun() time.Time {
	s.snapMu.Lock()
	defer s.snapMu.Unlock()
	return s.lastRun
}

func (s *Service) snapshotPath(householdID string, seq int64) string {
	return filepath.Join(s.cfg.SnapshotsDir, householdID, strconv.FormatInt(seq, 10)+".json.gz")
}

func (s *Service) snapshotHousehold(ctx context.Context, householdID string) error {
	if s.cfg.SnapshotsDir == "" {
		return errors.New("no snapshots directory")
	}
	var snap Snapshot
	// read the tables and the seq in one read transaction, so they agree
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		seq, err := q.LastSeq(ctx, householdID)
		if err != nil {
			return err
		}
		tables, err := foldsql.New(ctx, q, householdID).Tables()
		if err != nil {
			return err
		}
		snap = Snapshot{HouseholdID: householdID, Seq: seq, CreatedAt: s.nowMs(), Tables: tables}
		return nil
	})
	if err != nil {
		return err
	}
	if newest, err := s.db.Read().NewestSnapshot(ctx, householdID); err == nil && newest.Seq == snap.Seq {
		s.log.Info("snapshot unchanged", "household", householdID, "seq", snap.Seq)
		return s.retention(ctx, householdID, newest.Seq)
	}
	path := s.snapshotPath(householdID, snap.Seq)
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	gz := gzip.NewWriter(f)
	if err := json.NewEncoder(gz).Encode(snap); err != nil {
		_ = f.Close()
		return err
	}
	if err := gz.Close(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		if err := q.InsertSnapshot(ctx, db.InsertSnapshotParams{HouseholdID: householdID, Seq: snap.Seq, BlobPath: path, CreatedAt: snap.CreatedAt}); err != nil {
			return err
		}
		old, err := q.ListSnapshots(ctx, householdID)
		if err != nil {
			return err
		}
		for i, o := range old {
			if i < s.cfg.SnapshotsKept {
				continue
			}
			if err := q.DeleteSnapshot(ctx, db.DeleteSnapshotParams{HouseholdID: householdID, Seq: o.Seq}); err != nil {
				return err
			}
			_ = os.Remove(o.BlobPath)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if s.metrics != nil {
		s.metrics.SnapshotAge.WithLabelValues(householdID).Set(0)
	}
	s.log.Info("snapshot written", "household", householdID, "seq", snap.Seq, "path", path)
	return s.retention(ctx, householdID, snap.Seq)
}

// retention deletes events older than events_days that a snapshot covers.
// Materialised rows are never pruned: cleared entries are the history.
func (s *Service) retention(ctx context.Context, householdID string, snapshotSeq int64) error {
	cutoff := domain.Millis(s.now().Add(-time.Duration(s.cfg.EventsDays) * 24 * time.Hour))
	n, err := s.db.Write().DeleteEventsBefore(ctx, db.DeleteEventsBeforeParams{HouseholdID: householdID, Seq: snapshotSeq, ReceivedAt: cutoff})
	if err != nil {
		return err
	}
	if n > 0 {
		s.log.Info("retention", "household", householdID, "deleted", n)
	}
	return nil
}

// SnapshotJob runs RunSnapshots every day at hour, server local time, until
// ctx ends. It also runs once at start when no snapshot exists yet.
func (s *Service) SnapshotJob(ctx context.Context, hour int) error {
	first := true
	for {
		next := nextRun(s.now(), hour)
		if first {
			first = false
			if hs, err := s.Households(ctx); err == nil {
				missing := false
				for _, h := range hs {
					if _, err := s.db.Read().NewestSnapshot(ctx, h.ID); err != nil {
						missing = true
					}
				}
				if missing {
					next = s.now()
				}
			}
		}
		timer := time.NewTimer(time.Until(next))
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
		if err := s.RunSnapshots(ctx); err != nil {
			s.log.Error("snapshot job", "err", err)
		}
	}
}

// nextRun is the next hour o'clock after now, in local time.
func nextRun(now time.Time, hour int) time.Time {
	local := now.Local()
	run := time.Date(local.Year(), local.Month(), local.Day(), hour, 0, 0, 0, local.Location())
	if !run.After(local) {
		run = run.Add(24 * time.Hour)
	}
	return run
}

// OpenSnapshot returns a household's snapshot for one person: the tables
// without other people's personal lists and their entries, as gzip JSON.
func (s *Service) OpenSnapshot(ctx context.Context, sc domain.Scope, seq int64) (io.ReadCloser, error) {
	if err := requireMember(sc); err != nil {
		return nil, err
	}
	row, err := s.db.Read().GetSnapshot(ctx, db.GetSnapshotParams{HouseholdID: sc.HouseholdID, Seq: seq})
	if err != nil {
		return nil, notFound(err)
	}
	f, err := os.Open(row.BlobPath)
	if err != nil {
		return nil, fmt.Errorf("snapshot file: %w", err)
	}
	defer func() { _ = f.Close() }()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return nil, err
	}
	var snap Snapshot
	if err := json.NewDecoder(gz).Decode(&snap); err != nil {
		return nil, err
	}
	hidden := map[string]bool{}
	lists := snap.Tables.Lists[:0]
	for _, l := range snap.Tables.Lists {
		if l.OwnerPersonID != nil && *l.OwnerPersonID != sc.PersonID {
			hidden[l.ID] = true
			continue
		}
		lists = append(lists, l)
	}
	snap.Tables.Lists = lists
	entries := snap.Tables.Entries[:0]
	for _, e := range snap.Tables.Entries {
		if !hidden[e.ListID] {
			entries = append(entries, e)
		}
	}
	snap.Tables.Entries = entries
	pr, pw := io.Pipe()
	go func() {
		w := gzip.NewWriter(pw)
		err := json.NewEncoder(w).Encode(snap)
		if cerr := w.Close(); err == nil {
			err = cerr
		}
		pw.CloseWithError(err)
	}()
	return pr, nil
}
