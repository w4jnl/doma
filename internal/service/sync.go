package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/w4jnl/doma/internal/bus"
	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/events"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
	"github.com/w4jnl/doma/internal/metrics"
)

// MaxEventsPerRequest is the cap on one sync request's outbox.
const MaxEventsPerRequest = 2000

// SyncHousehold is one household's part of a request.
type SyncHousehold struct {
	ID     string            `json:"id"`
	Since  int64             `json:"since"`
	Events []json.RawMessage `json:"events"`
}

// SyncRequest is the body of POST /sync/v1.
type SyncRequest struct {
	Households []SyncHousehold `json:"households"`
}

// Rejected names an event the server refused and why; the client drops it.
type Rejected struct {
	ID     string `json:"id"`
	Reason string `json:"reason"`
}

// SyncEvent is an event as the server returns it, with its seq.
type SyncEvent struct {
	Seq      int64           `json:"seq"`
	ID       string          `json:"id"`
	PersonID string          `json:"person_id"`
	HLC      string          `json:"hlc"`
	Kind     string          `json:"kind"`
	Payload  json.RawMessage `json:"payload"`
}

// SyncHouseholdResult is one household's part of the answer.
type SyncHouseholdResult struct {
	ID       string      `json:"id"`
	Accepted []string    `json:"accepted"`
	Rejected []Rejected  `json:"rejected"`
	Events   []SyncEvent `json:"events"`
	Next     int64       `json:"next"`
	// Snapshot is a URL when the cursor is too far behind to replay.
	Snapshot *string `json:"snapshot"`
}

// SyncResponse is the body of the answer.
type SyncResponse struct {
	Households []SyncHouseholdResult `json:"households"`
}

// SetBus connects the bus the push subsystem listens on.
func (s *Service) SetBus(b *bus.Bus) { s.bus = b }

// SetMetrics connects the collectors.
func (s *Service) SetMetrics(m *metrics.Metrics) {
	s.metrics = m
	s.db.OnWrite = m.ObserveWrite
}

// SetTrace turns the fold trace on; `doma serve -d` does.
func (s *Service) SetTrace(on bool) { s.trace = on }

// incoming is one client event after the envelope is read.
type incoming struct {
	ID      string          `json:"id"`
	HLC     string          `json:"hlc"`
	Kind    string          `json:"kind"`
	Payload json.RawMessage `json:"payload"`
}

// Sync is the event exchange for one device: every household in the
// request must be the person's, or the whole request is a 404.
func (s *Service) Sync(ctx context.Context, personID, credentialID string, req SyncRequest) (*SyncResponse, error) {
	start := time.Now()
	v, err := events.Default()
	if err != nil {
		return nil, err
	}
	resp := &SyncResponse{Households: make([]SyncHouseholdResult, 0, len(req.Households))}
	for _, hh := range req.Households {
		if len(hh.Events) > MaxEventsPerRequest {
			return nil, domain.Invalid("events", "at most %d events per request", MaxEventsPerRequest)
		}
		m, err := s.MembershipFor(ctx, personID, hh.ID)
		if err != nil {
			s.count("not_found")
			return nil, err
		}
		if m.Role == domain.RoleGuest {
			s.count("not_found")
			return nil, domain.ErrNotFound
		}
		res, err := s.syncHousehold(ctx, v, personID, credentialID, hh)
		if err != nil {
			s.count("error")
			return nil, err
		}
		resp.Households = append(resp.Households, *res)
	}
	s.count("ok")
	if s.metrics != nil {
		s.metrics.SyncDuration.Observe(time.Since(start).Seconds())
	}
	return resp, nil
}

func (s *Service) count(result string) {
	if s.metrics != nil {
		s.metrics.SyncRequests.WithLabelValues(result).Inc()
	}
}

// listOwners maps list id to owner person id for the household's personal
// lists; shared lists are absent.
func listOwners(ctx context.Context, q *db.Queries, householdID string) (map[string]string, error) {
	lists, err := q.ListLists(ctx, householdID)
	if err != nil {
		return nil, err
	}
	owners := map[string]string{}
	for _, l := range lists {
		if l.OwnerPersonID != nil {
			owners[l.ID] = *l.OwnerPersonID
		}
	}
	return owners, nil
}

// visible reports whether an event may be seen by person: everything but
// another person's personal-list events.
func visible(kind string, payload []byte, owners map[string]string, personID string) bool {
	var p struct {
		ListID        string  `json:"list_id"`
		OwnerPersonID *string `json:"owner_person_id"`
	}
	if err := json.Unmarshal(payload, &p); err != nil {
		return true
	}
	if kind == "list.created" && p.OwnerPersonID != nil && *p.OwnerPersonID != personID {
		return false
	}
	if p.ListID != "" {
		if owner, ok := owners[p.ListID]; ok && owner != personID {
			return false
		}
	}
	return true
}

func (s *Service) syncHousehold(ctx context.Context, v *events.Validator, personID, credentialID string, hh SyncHousehold) (*SyncHouseholdResult, error) {
	res := &SyncHouseholdResult{ID: hh.ID, Accepted: []string{}, Rejected: []Rejected{}, Events: []SyncEvent{}, Next: hh.Since}
	var lastSeq int64
	exchange := func(q *db.Queries) error {
		owners, err := listOwners(ctx, q, hh.ID)
		if err != nil {
			return err
		}
		var store fold.Store = foldsql.New(ctx, q, hh.ID)
		if s.trace {
			store = fold.Traced(store, func(format string, args ...any) { s.log.Debug(fmt.Sprintf(format, args...), "household", hh.ID) })
		}
		fs := foldsql.New(ctx, q, hh.ID)
		for _, raw := range hh.Events {
			var in incoming
			if err := json.Unmarshal(raw, &in); err != nil || in.ID == "" {
				res.Rejected = append(res.Rejected, Rejected{ID: in.ID, Reason: "not an event"})
				continue
			}
			if err := v.Validate(raw); err != nil {
				res.Rejected = append(res.Rejected, Rejected{ID: in.ID, Reason: err.Error()})
				continue
			}
			h, err := domain.ParseHLC(in.HLC)
			if err != nil {
				res.Rejected = append(res.Rejected, Rejected{ID: in.ID, Reason: err.Error()})
				continue
			}
			if !visible(in.Kind, in.Payload, owners, personID) {
				res.Rejected = append(res.Rejected, Rejected{ID: in.ID, Reason: "not your list"})
				continue
			}
			if in.Kind == "member.removed" || in.Kind == "device.revoked" {
				res.Rejected = append(res.Rejected, Rejected{ID: in.ID, Reason: "server-originated kind"})
				continue
			}
			ev := fold.Event{ID: in.ID, PersonID: personID, HLC: h, Kind: in.Kind, Payload: in.Payload}
			seq, applied, err := fs.AppendWith(store, ev, credentialID, s.nowMs())
			if err != nil {
				if errors.Is(err, fold.ErrPayload) {
					res.Rejected = append(res.Rejected, Rejected{ID: in.ID, Reason: err.Error()})
					continue
				}
				return err
			}
			res.Accepted = append(res.Accepted, in.ID)
			if applied {
				lastSeq = seq
				if s.metrics != nil {
					s.metrics.Events.WithLabelValues(hh.ID, in.Kind).Inc()
				}
				if in.Kind == "list.created" {
					// a personal list created in this batch filters the rest of it
					var p struct {
						ListID        string  `json:"list_id"`
						OwnerPersonID *string `json:"owner_person_id"`
					}
					if json.Unmarshal(in.Payload, &p) == nil && p.OwnerPersonID != nil {
						owners[p.ListID] = *p.OwnerPersonID
					}
				}
			}
		}
		// the cursor: a snapshot when too far behind, otherwise the events after it
		if snap, err := q.NewestSnapshot(ctx, hh.ID); err == nil && snap.Seq-hh.Since > int64(s.cfg.ReplayLimit) {
			url := s.cfg.BaseURL + "/sync/v1/snapshot/" + hh.ID + "/" + strconv.FormatInt(snap.Seq, 10)
			res.Snapshot = &url
			res.Next = snap.Seq
			return nil
		}
		rows, err := q.EventsSince(ctx, db.EventsSinceParams{HouseholdID: hh.ID, Seq: hh.Since, Limit: int64(s.cfg.MaxEventsPerSync)})
		if err != nil {
			return err
		}
		for _, r := range rows {
			res.Next = r.Seq
			if !visible(r.Kind, []byte(r.Payload), owners, personID) {
				continue
			}
			res.Events = append(res.Events, SyncEvent{Seq: r.Seq, ID: r.ID, PersonID: r.PersonID, HLC: r.Hlc, Kind: r.Kind, Payload: json.RawMessage(r.Payload)})
		}
		return nil
	}
	// a device with nothing to send only reads: on the reader pool, not queued behind every
	// other device on the one writer, which is where a sync's slow tail came from
	var err error
	if len(hh.Events) == 0 {
		err = s.db.ReadTx(ctx, exchange)
	} else {
		err = s.db.Tx(ctx, exchange)
	}
	if err != nil {
		return nil, err
	}
	s.log.LogAttrs(ctx, slog.LevelInfo, "sync", slog.String("household", hh.ID), slog.Int("accepted", len(res.Accepted)), slog.Int("rejected", len(res.Rejected)), slog.Int("returned", len(res.Events)), slog.Int64("next", res.Next))
	s.changed(hh.ID, lastSeq)
	return res, nil
}
