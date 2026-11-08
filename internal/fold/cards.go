package fold

// cardPayload is what the four card events carry; owner_person_id rides on
// every one of them for the sync filter, the fold fixes it at card.added.
type cardPayload struct {
	CardID        string  `json:"card_id"`
	OwnerPersonID *string `json:"owner_person_id"`
	Name          string  `json:"name"`
	Colour        string  `json:"colour"`
	Format        string  `json:"format"`
	Value         string  `json:"value"`
	Domain        *string `json:"domain"`
	LogoID        string  `json:"logo_id"`
}

// CardFormats are the barcode symbologies the apps draw and read.
var CardFormats = map[string]bool{
	"ean13": true, "ean8": true, "upca": true, "upce": true, "code128": true, "code39": true, "code93": true,
	"itf14": true, "codabar": true, "qr": true, "aztec": true, "pdf417": true, "datamatrix": true,
}

// applyCard: card.added is add-wins and fixes the owner; name, colour,
// format, value and domain are last-writer-wins on the stamp between an add
// and the edits; an archive sticks whatever arrives after it; card.logo,
// the server's, sets the logo id, last-writer-wins among logos.
func applyCard(s Store, e Event) error {
	var p cardPayload
	if err := decode(e, &p); err != nil {
		return err
	}
	if err := need(e, "card_id", p.CardID); err != nil {
		return err
	}
	c, err := s.Card(p.CardID)
	if err != nil {
		return err
	}
	if c == nil {
		c = &Card{ID: p.CardID}
	}
	switch e.Kind {
	case "card.added", "card.edited":
		if err := need(e, "name", p.Name); err != nil {
			return err
		}
		if err := need(e, "value", p.Value); err != nil {
			return err
		}
		if !CardFormats[p.Format] {
			return need(e, "format", "")
		}
		if e.Kind == "card.added" && c.OwnerPersonID == nil {
			c.OwnerPersonID = p.OwnerPersonID
		}
		if c.UpdatedHLC == nil || c.UpdatedHLC.Less(e.HLC) {
			c.Name, c.Colour, c.Format, c.Value, c.Domain = p.Name, p.Colour, p.Format, p.Value, p.Domain
			c.UpdatedHLC = ptr(e.HLC)
		}
	case "card.archived":
		if c.ArchivedAt == nil || e.HLC.Wall < *c.ArchivedAt {
			c.ArchivedAt = ptr(e.HLC.Wall)
		}
	case "card.logo":
		if err := need(e, "logo_id", p.LogoID); err != nil {
			return err
		}
		if c.LogoHLC == nil || c.LogoHLC.Less(e.HLC) {
			c.LogoID = ptr(p.LogoID)
			c.LogoHLC = ptr(e.HLC)
		}
	}
	return s.PutCard(*c)
}
