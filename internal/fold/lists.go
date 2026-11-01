package fold

type listPayload struct {
	ListID        string  `json:"list_id"`
	Name          string  `json:"name"`
	Colour        string  `json:"colour"`
	OwnerPersonID *string `json:"owner_person_id"`
	Default       bool    `json:"default"`
}

// applyList: create is add-wins and carries the owner and the default
// mark, which never change; name and colour are last-writer-wins on the
// stamp; an archive sticks whatever arrives after it.
func applyList(s Store, e Event) error {
	var p listPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "list_id", p.ListID); err != nil {
		return err
	}
	l, err := s.List(p.ListID)
	if err != nil {
		return err
	}
	if l == nil {
		l = &List{ID: p.ListID}
	}
	switch e.Kind {
	case "list.created", "list.renamed":
		if e.Kind == "list.created" {
			if err := need(e, "name", p.Name); err != nil {
				return err
			}
			if l.OwnerPersonID == nil {
				l.OwnerPersonID = p.OwnerPersonID
			}
			l.IsDefault = l.IsDefault || p.Default
		}
		if l.UpdatedHLC == nil || l.UpdatedHLC.Less(e.HLC) {
			if p.Name != "" {
				l.Name = p.Name
			}
			l.Colour = p.Colour
			l.UpdatedHLC = ptr(e.HLC)
		}
	case "list.archived":
		if l.ArchivedAt == nil || e.HLC.Wall < *l.ArchivedAt {
			l.ArchivedAt = ptr(e.HLC.Wall)
		}
	}
	if err := s.PutList(*l); err != nil {
		return err
	}
	if e.Kind == "list.created" && l.IsDefault {
		// out flags and trips that arrived before the default list existed
		// now add their items to it
		items, err := listItemIDs(s, l.ID, true)
		if err != nil {
			return err
		}
		for _, item := range items {
			if err := replayEntries(s, l.ID, item); err != nil {
				return err
			}
		}
	}
	return nil
}

type homePayload struct {
	HomeID string `json:"home_id"`
	Name   string `json:"name"`
}

func applyHome(s Store, e Event) error {
	var p homePayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "home_id", p.HomeID); err != nil {
		return err
	}
	h, err := s.Home(p.HomeID)
	if err != nil {
		return err
	}
	if h == nil {
		h = &Home{ID: p.HomeID}
	}
	switch e.Kind {
	case "home.created", "home.renamed":
		if err := need(e, "name", p.Name); err != nil {
			return err
		}
		if h.UpdatedHLC == nil || h.UpdatedHLC.Less(e.HLC) {
			h.Name = p.Name
			h.UpdatedHLC = ptr(e.HLC)
		}
	case "home.archived":
		if h.ArchivedAt == nil || e.HLC.Wall < *h.ArchivedAt {
			h.ArchivedAt = ptr(e.HLC.Wall)
		}
	}
	return s.PutHome(*h)
}

type spotPayload struct {
	SpotID string `json:"spot_id"`
	HomeID string `json:"home_id"`
	Name   string `json:"name"`
}

func applySpot(s Store, e Event) error {
	var p spotPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "spot_id", p.SpotID); err != nil {
		return err
	}
	sp, err := s.Spot(p.SpotID)
	if err != nil {
		return err
	}
	if sp == nil {
		sp = &Spot{ID: p.SpotID}
	}
	if p.HomeID != "" {
		sp.HomeID = p.HomeID
	}
	switch e.Kind {
	case "spot.created", "spot.renamed":
		if err := need(e, "name", p.Name); err != nil {
			return err
		}
		if e.Kind == "spot.created" {
			if err := need(e, "home_id", p.HomeID); err != nil {
				return err
			}
		}
		if sp.UpdatedHLC == nil || sp.UpdatedHLC.Less(e.HLC) {
			sp.Name = p.Name
			sp.UpdatedHLC = ptr(e.HLC)
		}
	case "spot.archived":
		if sp.ArchivedAt == nil || e.HLC.Wall < *sp.ArchivedAt {
			sp.ArchivedAt = ptr(e.HLC.Wall)
		}
	}
	return s.PutSpot(*sp)
}
