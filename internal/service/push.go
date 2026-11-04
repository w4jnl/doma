package service

import (
	"context"
	"encoding/json"

	"github.com/w4jnl/doma/internal/db"
)

// PushTarget is a device to push to: whose it is, and the seq it was last
// told about, so the next push can say what happened since.
type PushTarget struct {
	CredentialID string
	Token        string
	PersonID     string
	LastSeq      int64
	// LastUsedAt is when the device last spoke to the server; what others added
	// after it is the number on its icon until the app counts for itself.
	LastUsedAt int64
	// Sandbox: the token belongs to Apple's development gateway.
	Sandbox bool
	// What the device wants to hear, and when it last heard words and up to where.
	MutedLists   []string
	NotifyClears bool
	SpokenAt     int64
	SpokenSeq    int64
}

// Change is one thing a notification can say: who added which item to which
// list, or who cleared a list. Only entry.added and entry.cleared count; checks
// are too many and too small.
type Change struct {
	PersonID string
	Person   string
	ListID   string
	List     string
	Item     string
	Cleared  bool
}

// PushTargets returns the household's devices with a token that were not
// pushed since notBefore.
func (s *Service) PushTargets(ctx context.Context, householdID string, notBefore int64) ([]PushTarget, error) {
	rows, err := s.db.Read().PushTargets(ctx, db.PushTargetsParams{HouseholdID: householdID, SentAt: notBefore})
	if err != nil {
		return nil, err
	}
	out := make([]PushTarget, 0, len(rows))
	for _, r := range rows {
		if r.ApnsToken != nil {
			var last int64
			if r.LastSeq != nil {
				last = *r.LastSeq
			}
			var used int64
			if r.LastUsedAt != nil {
				used = *r.LastUsedAt
			}
			var spokenAt, spokenSeq int64
			if r.SpokenAt != nil {
				spokenAt = *r.SpokenAt
			}
			if r.SpokenSeq != nil {
				spokenSeq = *r.SpokenSeq
			}
			out = append(out, PushTarget{CredentialID: r.CredentialID, Token: *r.ApnsToken, PersonID: r.PersonID, LastSeq: last, LastUsedAt: used, Sandbox: r.ApnsSandbox != 0,
				MutedLists: mutedLists(r.MutedLists), NotifyClears: r.NotifyClears != 0, SpokenAt: spokenAt, SpokenSeq: spokenSeq})
		}
	}
	return out, nil
}

// RecordPush notes a push so the next one to the device waits 30 s.
func (s *Service) RecordPush(ctx context.Context, householdID, credentialID string, seq int64) error {
	return s.db.Write().RecordPush(ctx, db.RecordPushParams{HouseholdID: householdID, CredentialID: credentialID, SentAt: s.nowMs(), Seq: seq})
}

// RecordSpoken notes that a device heard words up to seq: the next spoken
// push waits two minutes and starts from here.
func (s *Service) RecordSpoken(ctx context.Context, householdID, credentialID string, seq int64) error {
	now := s.nowMs()
	return s.db.Write().RecordSpoken(ctx, db.RecordSpokenParams{SpokenAt: &now, SpokenSeq: &seq, HouseholdID: householdID, CredentialID: credentialID})
}

// ClearPushToken forgets a token Apple says is gone.
func (s *Service) ClearPushToken(ctx context.Context, credentialID string) error {
	return s.db.Write().ClearAPNSToken(ctx, credentialID)
}

// Changes lists what happened in the household after seq, up to and including
// upTo, as things a notification can say: adds and clears with the person's
// and the list's names. Names are looked up once each.
func (s *Service) Changes(ctx context.Context, householdID string, after, upTo int64) ([]Change, error) {
	q := s.db.Read()
	rows, err := q.EventsSince(ctx, db.EventsSinceParams{HouseholdID: householdID, Seq: after, Limit: 500})
	if err != nil {
		return nil, err
	}
	persons := map[string]string{}
	lists := map[string]string{}
	items := map[string]string{}
	var out []Change
	for _, e := range rows {
		if e.Seq > upTo {
			break
		}
		if e.Kind != "entry.added" && e.Kind != "entry.cleared" {
			continue
		}
		var p struct {
			ListID string `json:"list_id"`
			ItemID string `json:"item_id"`
		}
		if err := json.Unmarshal([]byte(e.Payload), &p); err != nil || p.ListID == "" {
			continue
		}
		c := Change{PersonID: e.PersonID, ListID: p.ListID, Cleared: e.Kind == "entry.cleared"}
		if name, ok := persons[e.PersonID]; ok {
			c.Person = name
		} else if pr, err := q.GetPerson(ctx, e.PersonID); err == nil {
			persons[e.PersonID] = pr.DisplayName
			c.Person = pr.DisplayName
		}
		if name, ok := lists[p.ListID]; ok {
			c.List = name
		} else if l, err := q.GetList(ctx, db.GetListParams{HouseholdID: householdID, ID: p.ListID}); err == nil {
			lists[p.ListID] = l.Name
			c.List = l.Name
		}
		if !c.Cleared && p.ItemID != "" {
			if name, ok := items[p.ItemID]; ok {
				c.Item = name
			} else if it, err := q.GetItem(ctx, db.GetItemParams{HouseholdID: householdID, ID: p.ItemID}); err == nil {
				items[p.ItemID] = it.Name
				c.Item = it.Name
			}
		}
		out = append(out, c)
	}
	return out, nil
}

// AddedByOthersSince counts the entries others added to the household after a
// moment: the badge a push carries for a device that was away since then.
func (s *Service) AddedByOthersSince(ctx context.Context, householdID, personID string, sinceMs int64) (int, error) {
	n, err := s.db.Read().CountAddedByOthersSince(ctx, db.CountAddedByOthersSinceParams{HouseholdID: householdID, PersonID: personID, ReceivedAt: sinceMs})
	return int(n), err
}
