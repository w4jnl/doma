package fold

import (
	"sort"

	"github.com/w4jnl/doma/internal/domain"
)

// Proposals: what a vision model suggests after a photo, for a member to
// accept or decline. flag.proposed opens one; it closes when a flag is
// written for the item at the home at or after it, when it is declined, or
// when a newer proposal for the same item arrives. Derived per (home, item)
// from the key's events, so any order gives the same rows.

type Proposal struct {
	ID          string      `json:"id"`
	HomeID      string      `json:"home_id"`
	ItemID      string      `json:"item_id"`
	State       string      `json:"state"`
	PhotoID     string      `json:"photo_id"`
	ProposedHLC domain.HLC  `json:"proposed_hlc"`
	ClosedHLC   *domain.HLC `json:"closed_hlc"`
}

// Open reports whether the proposal still waits for an answer.
func (p Proposal) Open() bool { return p.ClosedHLC == nil }

type proposalPayload struct {
	ProposalID string `json:"proposal_id"`
	HomeID     string `json:"home_id"`
	ItemID     string `json:"item_id"`
	State      string `json:"state"`
	PhotoID    string `json:"photo_id"`
}

// applyProposalEvent handles flag.proposed and proposal.declined: both name
// the home and the item, and the key is derived again.
func applyProposalEvent(s Store, e Event) error {
	var p proposalPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "home_id", p.HomeID); err != nil {
		return err
	}
	if err := need(e, "item_id", p.ItemID); err != nil {
		return err
	}
	if e.Kind == "flag.proposed" && !flagStates[p.State] {
		return need(e, "state", "")
	}
	if e.Kind == "proposal.declined" {
		if err := need(e, "proposal_id", p.ProposalID); err != nil {
			return err
		}
	}
	item, err := resolveItem(s, p.ItemID)
	if err != nil {
		return err
	}
	return recomputeProposals(s, p.HomeID, item)
}

// recomputeProposals derives the proposals of one (home, item): every
// flag.proposed for it, closed by the flag as it stands when that is at or
// after the proposal, by a decline, or by a newer proposal.
func recomputeProposals(s Store, homeID, itemID string) error {
	ids, err := s.MergedIDs(itemID)
	if err != nil {
		return err
	}
	events, err := s.ItemEventsFor(ids)
	if err != nil {
		return err
	}
	flag, err := s.Flag(homeID, itemID)
	if err != nil {
		return err
	}
	declined := map[string]domain.HLC{}
	var rows []Proposal
	for _, ev := range events {
		if ev.Kind != "flag.proposed" && ev.Kind != "proposal.declined" {
			continue
		}
		var p proposalPayload
		if err := decode(ev, &p); err != nil {
			return err
		}
		if p.HomeID != homeID {
			continue
		}
		switch ev.Kind {
		case "proposal.declined":
			if cur, ok := declined[p.ProposalID]; !ok || ev.HLC.Less(cur) {
				declined[p.ProposalID] = ev.HLC
			}
		case "flag.proposed":
			if flagStates[p.State] {
				rows = append(rows, Proposal{ID: ev.ID, HomeID: homeID, ItemID: itemID, State: p.State, PhotoID: p.PhotoID, ProposedHLC: ev.HLC})
			}
		}
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].ProposedHLC.Less(rows[j].ProposedHLC) })
	for i := range rows {
		closeAt := func(h domain.HLC) {
			if rows[i].ClosedHLC == nil || h.Less(*rows[i].ClosedHLC) {
				rows[i].ClosedHLC = ptr(h)
			}
		}
		if h, ok := declined[rows[i].ID]; ok {
			closeAt(h)
		}
		if flag != nil && !flag.SetHLC.Less(rows[i].ProposedHLC) {
			closeAt(flag.SetHLC)
		}
		if i+1 < len(rows) {
			closeAt(rows[i+1].ProposedHLC)
		}
	}
	return s.ReplaceProposals(homeID, ids, rows)
}
