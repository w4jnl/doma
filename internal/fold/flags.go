package fold

import "fmt"

var flagStates = map[string]bool{"have": true, "low": true, "out": true}

// applyFlagSet is last-writer-wins on the stamp. An out flag also adds the
// item to the default list, through that list's replay.
func applyFlagSet(s Store, e Event) error {
	var p flagPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "home_id", p.HomeID); err != nil {
		return err
	}
	if err := need(e, "item_id", p.ItemID); err != nil {
		return err
	}
	if !flagStates[p.State] {
		return fmt.Errorf("%w: flag.set %s: state %q", ErrPayload, e.ID, p.State)
	}
	item, err := resolveItem(s, p.ItemID)
	if err != nil {
		return err
	}
	if err := putFlagLWW(s, Flag{HomeID: p.HomeID, ItemID: item, State: p.State, SetHLC: e.HLC, SetBy: e.PersonID, Note: p.Note}); err != nil {
		return err
	}
	if err := recomputeProposals(s, p.HomeID, item); err != nil {
		return err
	}
	if p.State != "out" {
		return nil
	}
	def, err := s.DefaultListID()
	if err != nil || def == "" {
		return err
	}
	return replayEntries(s, def, item)
}

// recomputeFlag derives the flag of one (home, item) from every write that
// can reach it: flag.set events, trips through the home, and clears of
// entries for the home; the latest stamp wins, and no write leaves one.
func recomputeFlag(s Store, homeID, itemID string) error {
	ids, err := s.MergedIDs(itemID)
	if err != nil {
		return err
	}
	var best *Flag
	consider := func(f Flag) {
		if best == nil || best.SetHLC.Less(f.SetHLC) {
			best = &f
		}
	}
	events, err := s.ItemEventsFor(ids)
	if err != nil {
		return err
	}
	for _, ev := range events {
		switch ev.Kind {
		case "flag.set":
			var p flagPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			if p.HomeID == homeID && flagStates[p.State] {
				consider(Flag{HomeID: homeID, ItemID: itemID, State: p.State, SetHLC: ev.HLC, SetBy: ev.PersonID, Note: p.Note})
			}
		case "trip.arrived":
			var p tripPayload
			if err := decode(ev, &p); err != nil {
				return err
			}
			if p.FromHomeID == homeID {
				consider(Flag{HomeID: homeID, ItemID: itemID, State: "out", SetHLC: ev.HLC, SetBy: ev.PersonID})
			}
			if p.ToHomeID == homeID {
				consider(Flag{HomeID: homeID, ItemID: itemID, State: "have", SetHLC: ev.HLC, SetBy: ev.PersonID})
			}
		}
	}
	cleared, err := s.ClearedEntriesForHome(ids, homeID)
	if err != nil {
		return err
	}
	for _, e := range cleared {
		consider(Flag{HomeID: homeID, ItemID: itemID, State: "have", SetHLC: *e.ClearedHLC, SetBy: cleanedBy(e)})
	}
	if best == nil {
		if err := s.DeleteFlag(homeID, itemID); err != nil {
			return err
		}
	} else if err := s.PutFlag(*best); err != nil {
		return err
	}
	// a proposal closes with the flag written after it
	return recomputeProposals(s, homeID, itemID)
}

// putFlagLWW writes f unless the stored flag is newer.
func putFlagLWW(s Store, f Flag) error {
	cur, err := s.Flag(f.HomeID, f.ItemID)
	if err != nil {
		return err
	}
	if cur != nil && !cur.SetHLC.Less(f.SetHLC) {
		return nil
	}
	return s.PutFlag(f)
}

type staplePayload struct {
	HomeID string `json:"home_id"`
	ItemID string `json:"item_id"`
	Sort   *int64 `json:"sort"`
}

// applyStaple keeps the latest add and the latest remove; the staple is
// present when the add is newer.
func applyStaple(s Store, e Event) error {
	var p staplePayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "home_id", p.HomeID); err != nil {
		return err
	}
	if err := need(e, "item_id", p.ItemID); err != nil {
		return err
	}
	item, err := resolveItem(s, p.ItemID)
	if err != nil {
		return err
	}
	return putStaple(s, e, p, item)
}

func putStaple(s Store, e Event, p staplePayload, item string) error {
	cur, err := s.Staple(p.HomeID, item)
	if err != nil {
		return err
	}
	if cur == nil {
		cur = &Staple{HomeID: p.HomeID, ItemID: item}
	}
	switch e.Kind {
	case "staple.added":
		if cur.AddedHLC == nil || cur.AddedHLC.Less(e.HLC) {
			cur.AddedHLC = ptr(e.HLC)
			if p.Sort != nil {
				cur.Sort = *p.Sort
			}
		}
	case "staple.removed":
		if cur.RemovedHLC == nil || cur.RemovedHLC.Less(e.HLC) {
			cur.RemovedHLC = ptr(e.HLC)
		}
	}
	return s.PutStaple(*cur)
}

type photoPayload struct {
	PhotoID string `json:"photo_id"`
	SpotID  string `json:"spot_id"`
	Bytes   int64  `json:"bytes"`
	Width   int64  `json:"width"`
	Height  int64  `json:"height"`
}

// applyPhotoAdded appends; the newest stamp per spot is the current photo,
// computed at read time.
func applyPhotoAdded(s Store, e Event) error {
	var p photoPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "photo_id", p.PhotoID); err != nil {
		return err
	}
	if err := need(e, "spot_id", p.SpotID); err != nil {
		return err
	}
	return s.PutPhoto(Photo{ID: p.PhotoID, SpotID: p.SpotID, TakenAt: e.HLC, TakenBy: e.PersonID, Bytes: p.Bytes, Width: p.Width, Height: p.Height})
}

type tripPlanPayload struct {
	TripID     string `json:"trip_id"`
	FromHomeID string `json:"from_home_id"`
	ToHomeID   string `json:"to_home_id"`
	Date       int64  `json:"date"`
	ListID     string `json:"list_id"`
}

// applyTripPlanned keeps the latest plan: from, to, date, the list it shops
// on and who planned it are last-writer-wins on the stamp; an arrival or a
// cancel that came first stays on the row.
func applyTripPlanned(s Store, e Event) error {
	var p tripPlanPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "trip_id", p.TripID); err != nil {
		return err
	}
	if err := need(e, "from_home_id", p.FromHomeID); err != nil {
		return err
	}
	if err := need(e, "to_home_id", p.ToHomeID); err != nil {
		return err
	}
	cur, err := s.Trip(p.TripID)
	if err != nil {
		return err
	}
	if cur == nil {
		cur = &Trip{ID: p.TripID}
	}
	if cur.UpdatedHLC == nil || cur.UpdatedHLC.Less(e.HLC) {
		cur.FromHomeID, cur.ToHomeID, cur.Date, cur.CreatedBy = p.FromHomeID, p.ToHomeID, p.Date, e.PersonID
		cur.ListID = nil
		if p.ListID != "" {
			cur.ListID = ptr(p.ListID)
		}
		cur.UpdatedHLC = ptr(e.HLC)
	}
	return s.PutTrip(*cur)
}

// applyTripCancelled marks the trip cancelled at the earliest cancel; a
// cancel that lands before its plan makes the row the plan then fills.
func applyTripCancelled(s Store, e Event) error {
	var p tripPlanPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "trip_id", p.TripID); err != nil {
		return err
	}
	cur, err := s.Trip(p.TripID)
	if err != nil {
		return err
	}
	if cur == nil {
		cur = &Trip{ID: p.TripID}
	}
	if cur.CancelledAt == nil || e.HLC.Wall < *cur.CancelledAt {
		cur.CancelledAt = ptr(e.HLC.Wall)
	}
	return s.PutTrip(*cur)
}

// applyTripArrived records the arrival and moves every item: out at the
// from-home, have at the to-home, with the trip's stamp. The out flags add
// the items to the default list through its replay. A trip nobody planned
// takes the arrival's homes and wall; a planned one keeps its plan.
func applyTripArrived(s Store, e Event) error {
	var p tripPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "trip_id", p.TripID); err != nil {
		return err
	}
	if err := need(e, "from_home_id", p.FromHomeID); err != nil {
		return err
	}
	if err := need(e, "to_home_id", p.ToHomeID); err != nil {
		return err
	}
	cur, err := s.Trip(p.TripID)
	if err != nil {
		return err
	}
	if cur == nil {
		cur = &Trip{ID: p.TripID}
	}
	first := cur.ArrivedAt == nil || e.HLC.Wall < *cur.ArrivedAt
	if cur.UpdatedHLC == nil && first {
		// no plan: the earliest arrival names the homes and the date
		cur.FromHomeID, cur.ToHomeID, cur.Date, cur.CreatedBy = p.FromHomeID, p.ToHomeID, e.HLC.Wall, e.PersonID
	}
	if first {
		cur.ArrivedAt = ptr(e.HLC.Wall)
	}
	if err := s.PutTrip(*cur); err != nil {
		return err
	}
	def, err := s.DefaultListID()
	if err != nil {
		return err
	}
	for _, raw := range p.Moved {
		item, err := resolveItem(s, raw)
		if err != nil {
			return err
		}
		if err := tripFlags(s, e, p, item); err != nil {
			return err
		}
		if def != "" {
			if err := replayEntries(s, def, item); err != nil {
				return err
			}
		}
	}
	return nil
}

// tripFlags writes a trip's two flags for one moved item.
func tripFlags(s Store, e Event, p tripPayload, item string) error {
	if err := putFlagLWW(s, Flag{HomeID: p.FromHomeID, ItemID: item, State: "out", SetHLC: e.HLC, SetBy: e.PersonID}); err != nil {
		return err
	}
	if err := putFlagLWW(s, Flag{HomeID: p.ToHomeID, ItemID: item, State: "have", SetHLC: e.HLC, SetBy: e.PersonID}); err != nil {
		return err
	}
	for _, home := range []string{p.FromHomeID, p.ToHomeID} {
		if err := recomputeProposals(s, home, item); err != nil {
			return err
		}
	}
	return nil
}
