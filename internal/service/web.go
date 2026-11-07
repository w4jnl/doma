package service

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/foldsql"
)

// The web client: what a family member reaches from a browser, signed in by
// a passkey or by their phone vouching for the browser. It reads the same
// tables the apps fold and writes events on the member's behalf with the
// server's clock, like the guest page; nothing here is offline.

// WebHousehold is a household a person may open in the browser.
type WebHousehold struct {
	ID   string
	Name string
	Role domain.Role
}

// WebHouseholds is every household the person is a member of, by name.
func (s *Service) WebHouseholds(ctx context.Context, personID string) ([]WebHousehold, error) {
	q := s.db.Read()
	ms, err := q.MembershipsForPerson(ctx, personID)
	if err != nil {
		return nil, err
	}
	var out []WebHousehold
	for _, m := range ms {
		if m.Role == string(domain.RoleGuest) {
			continue
		}
		h, err := q.GetHousehold(ctx, m.HouseholdID)
		if err != nil {
			continue
		}
		out = append(out, WebHousehold{ID: h.ID, Name: h.Name, Role: domain.Role(m.Role)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// MemberScope is the person's scope in the household, or ErrNotFound when
// they are not a member of it.
func (s *Service) MemberScope(ctx context.Context, personID, householdID string) (domain.Scope, error) {
	m, err := s.MembershipFor(ctx, personID, householdID)
	if err != nil {
		return domain.Scope{}, err
	}
	if m.Role == domain.RoleGuest {
		return domain.Scope{}, domain.ErrNotFound
	}
	return domain.Scope{HouseholdID: householdID, PersonID: personID, Role: m.Role}, nil
}

// WebList is a list row of the web client's overview.
type WebList struct {
	ID       string
	Name     string
	Colour   string
	Kind     string
	Personal bool
	Default  bool
	// Open is how many entries are neither struck nor cleared.
	Open int
}

// IsTasks reports whether the list is of things to do.
func (l WebList) IsTasks() bool { return l.Kind == "tasks" }

// WebLists is the household's lists and the person's own, in the app's order.
func (s *Service) WebLists(ctx context.Context, sc domain.Scope) ([]WebList, error) {
	if sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	var out []WebList
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		tables, err := foldsql.New(ctx, q, sc.HouseholdID).Tables()
		if err != nil {
			return err
		}
		open := map[string]int{}
		for _, e := range tables.Entries {
			if e.ClearedHLC == nil && e.CheckedHLC == nil {
				open[e.ListID]++
			}
		}
		for _, l := range tables.Lists {
			if !visibleList(l, sc.PersonID) {
				continue
			}
			out = append(out, WebList{ID: l.ID, Name: l.Name, Colour: l.Colour, Kind: l.Kind, Personal: l.OwnerPersonID != nil, Default: l.IsDefault, Open: open[l.ID]})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Personal != b.Personal {
			return !a.Personal
		}
		if a.Default != b.Default {
			return a.Default
		}
		return a.Name < b.Name
	})
	return out, nil
}

// visibleList is a list the person may see: not archived, shared or their own.
func visibleList(l fold.List, personID string) bool {
	return l.ArchivedAt == nil && (l.OwnerPersonID == nil || *l.OwnerPersonID == personID)
}

// WebListView is one list as the web client shows it.
type WebListView struct {
	List       WebList
	Entries    []GuestEntry
	AnyChecked bool
	Checked    int
	Open       int
}

// WebList reads one list with its rows; another person's list is ErrNotFound.
func (s *Service) WebList(ctx context.Context, sc domain.Scope, listID string) (*WebListView, error) {
	if sc.IsGuest() {
		return nil, domain.ErrForbidden
	}
	var v WebListView
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		tables, err := foldsql.New(ctx, q, sc.HouseholdID).Tables()
		if err != nil {
			return err
		}
		var found *fold.List
		for i := range tables.Lists {
			if tables.Lists[i].ID == listID && visibleList(tables.Lists[i], sc.PersonID) {
				found = &tables.Lists[i]
			}
		}
		if found == nil {
			return domain.ErrNotFound
		}
		v.List = WebList{ID: found.ID, Name: found.Name, Colour: found.Colour, Kind: found.Kind, Personal: found.OwnerPersonID != nil, Default: found.IsDefault}
		names := map[string]string{}
		for _, it := range tables.Items {
			names[it.ID] = it.Name
		}
		v.Entries = s.openEntries(ctx, q, tables, listID, names, map[string]string{})
		for _, e := range v.Entries {
			if e.Checked {
				v.Checked++
			} else {
				v.Open++
			}
		}
		v.AnyChecked = v.Checked > 0
		v.List.Open = v.Open
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &v, nil
}

// webList is the list check every write starts with, inside q.
func (s *Service) webList(ctx context.Context, q *db.Queries, sc domain.Scope, listID string) (db.List, error) {
	l, err := q.GetList(ctx, db.GetListParams{HouseholdID: sc.HouseholdID, ID: listID})
	if err != nil {
		return db.List{}, notFound(err)
	}
	if l.ArchivedAt != nil || (l.OwnerPersonID != nil && *l.OwnerPersonID != sc.PersonID) {
		return db.List{}, domain.ErrNotFound
	}
	return l, nil
}

// WebAdd adds a typed line to one of the person's lists.
func (s *Service) WebAdd(ctx context.Context, sc domain.Scope, credentialID, listID, text string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	if err := s.db.ReadTx(ctx, func(q *db.Queries) error { _, err := s.webList(ctx, q, sc, listID); return err }); err != nil {
		return err
	}
	return s.addLine(ctx, sc, credentialID, listID, text)
}

// WebToggle strikes an open entry or puts it back.
func (s *Service) WebToggle(ctx context.Context, sc domain.Scope, credentialID, listID, entryID string) error {
	return s.webEntryEvent(ctx, sc, credentialID, listID, entryID, func(e fold.Entry) string {
		if e.CheckedHLC != nil {
			return "entry.unchecked"
		}
		return "entry.checked"
	})
}

// WebRemove takes an open entry off the list as not needed.
func (s *Service) WebRemove(ctx context.Context, sc domain.Scope, credentialID, listID, entryID string) error {
	return s.webEntryEvent(ctx, sc, credentialID, listID, entryID, func(fold.Entry) string { return "entry.removed" })
}

func (s *Service) webEntryEvent(ctx context.Context, sc domain.Scope, credentialID, listID, entryID string, kind func(fold.Entry) string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	var last int64
	err := s.db.Tx(ctx, func(q *db.Queries) error {
		if _, err := s.webList(ctx, q, sc, listID); err != nil {
			return err
		}
		rows, err := foldsql.New(ctx, q, sc.HouseholdID).Entries(listID, nil)
		if err != nil {
			return err
		}
		for _, e := range rows {
			if e.ID != entryID || e.ClearedHLC != nil {
				continue
			}
			ev := s.guestEvent(sc, kind(e), map[string]any{"list_id": listID, "item_id": e.ItemID})
			seq, err := s.appendEvents(ctx, q, sc.HouseholdID, credentialID, []fold.Event{ev})
			last = seq
			return err
		}
		return domain.ErrNotFound
	})
	if err != nil {
		return err
	}
	s.changed(sc.HouseholdID, last)
	return nil
}

// WebClear removes the struck entries of the list.
func (s *Service) WebClear(ctx context.Context, sc domain.Scope, credentialID, listID string) error {
	if sc.IsGuest() {
		return domain.ErrForbidden
	}
	var last int64
	err := s.db.Tx(ctx, func(q *db.Queries) error {
		if _, err := s.webList(ctx, q, sc, listID); err != nil {
			return err
		}
		ev := s.guestEvent(sc, "entry.cleared", map[string]any{"list_id": listID, "before_hlc": s.clock.Next().String()})
		seq, err := s.appendEvents(ctx, q, sc.HouseholdID, credentialID, []fold.Event{ev})
		last = seq
		return err
	})
	if err != nil {
		return err
	}
	s.changed(sc.HouseholdID, last)
	return nil
}

// listColours are the six list colours of the design system, in order.
var listColours = []string{"list-1", "list-2", "list-3", "list-4", "list-5", "list-6"}

// WebCreateList makes a list, shared or the person's own, for shopping or
// tasks, in the first colour no visible list wears.
func (s *Service) WebCreateList(ctx context.Context, sc domain.Scope, credentialID, name string, personal, tasks bool) (string, error) {
	if sc.IsGuest() {
		return "", domain.ErrForbidden
	}
	if len(name) == 0 || len(name) > 200 {
		return "", domain.Invalid("name", "give the list a name")
	}
	lists, err := s.WebLists(ctx, sc)
	if err != nil {
		return "", err
	}
	worn := map[string]bool{}
	for _, l := range lists {
		worn[l.Colour] = true
	}
	colour := listColours[0]
	for _, c := range listColours {
		if !worn[c] {
			colour = c
			break
		}
	}
	id := domain.NewID()
	payload := map[string]any{"list_id": id, "name": name, "colour": colour}
	if personal {
		payload["owner_person_id"] = sc.PersonID
	}
	if tasks {
		payload["kind"] = "tasks"
	}
	var last int64
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		seq, err := s.appendEvents(ctx, q, sc.HouseholdID, credentialID, []fold.Event{s.guestEvent(sc, "list.created", payload)})
		last = seq
		return err
	})
	if err != nil {
		return "", err
	}
	s.changed(sc.HouseholdID, last)
	return id, nil
}

// Vouching: a browser shows a code, the member's phone scans it and tells
// the server who sits at that browser. Codes live five minutes, in memory.

const vouchTTL = 5 * time.Minute

type vouch struct {
	created      time.Time
	personID     string
	credentialID string
}

type vouches struct {
	mu   sync.Mutex
	byID map[string]*vouch
}

// NewVouch makes a code for a browser that waits to be signed in.
func (s *Service) NewVouch() (string, error) {
	token, err := auth.NewToken()
	if err != nil {
		return "", err
	}
	now := s.now()
	s.vouches.mu.Lock()
	defer s.vouches.mu.Unlock()
	if s.vouches.byID == nil {
		s.vouches.byID = map[string]*vouch{}
	}
	for k, v := range s.vouches.byID {
		if now.Sub(v.created) > vouchTTL {
			delete(s.vouches.byID, k)
		}
	}
	s.vouches.byID[token] = &vouch{created: now}
	return token, nil
}

// Vouch is the phone naming the person at the browser: ErrNotFound for a
// code the server does not know, has let expire, or has already been used.
func (s *Service) Vouch(token, personID, credentialID string) error {
	s.vouches.mu.Lock()
	defer s.vouches.mu.Unlock()
	v, ok := s.vouches.byID[token]
	if !ok || s.now().Sub(v.created) > vouchTTL || v.personID != "" {
		return domain.ErrNotFound
	}
	v.personID, v.credentialID = personID, credentialID
	return nil
}

// TakeVouch answers the waiting browser: the person and the credential once
// vouched, consuming the code; waiting is "" with ok; unknown is !ok.
func (s *Service) TakeVouch(token string) (personID, credentialID string, ok bool) {
	s.vouches.mu.Lock()
	defer s.vouches.mu.Unlock()
	v, found := s.vouches.byID[token]
	if !found || s.now().Sub(v.created) > vouchTTL {
		delete(s.vouches.byID, token)
		return "", "", false
	}
	if v.personID == "" {
		return "", "", true
	}
	delete(s.vouches.byID, token)
	return v.personID, v.credentialID, true
}

// Passkeys: a browser's credential, stored in the credentials table as kind
// passkey with the WebAuthn record as its public key and the hash of its id
// for the lookup a discoverable sign-in needs.

// ErrNoPasskeys is a server without a base URL, which WebAuthn needs for the
// relying party.
var ErrNoPasskeys = errors.New("passkeys need server.base_url")

// passkeyUser is the person as WebAuthn sees them.
type passkeyUser struct {
	id    string
	name  string
	creds []webauthn.Credential
}

func (u *passkeyUser) WebAuthnID() []byte                         { return []byte(u.id) }
func (u *passkeyUser) WebAuthnName() string                       { return u.name }
func (u *passkeyUser) WebAuthnDisplayName() string                { return u.name }
func (u *passkeyUser) WebAuthnCredentials() []webauthn.Credential { return u.creds }

func (s *Service) passkeyUser(ctx context.Context, q *db.Queries, personID string) (*passkeyUser, error) {
	p, err := q.GetPerson(ctx, personID)
	if err != nil {
		return nil, notFound(err)
	}
	creds, err := q.CredentialsForPerson(ctx, personID)
	if err != nil {
		return nil, err
	}
	u := &passkeyUser{id: p.ID, name: p.DisplayName}
	for _, c := range creds {
		if c.Kind != domain.KindPasskey || c.RevokedAt != nil || c.PublicKey == nil {
			continue
		}
		var wc webauthn.Credential
		if json.Unmarshal([]byte(*c.PublicKey), &wc) == nil {
			u.creds = append(u.creds, wc)
		}
	}
	return u, nil
}

// PasskeysEnabled reports whether the server can register and check passkeys.
func (s *Service) PasskeysEnabled() bool { return s.webauthn != nil }

func (s *Service) passkeys() (*webauthn.WebAuthn, error) {
	if s.webauthn == nil {
		return nil, ErrNoPasskeys
	}
	return s.webauthn, nil
}

// BeginPasskeyRegistration starts adding a passkey to the person's browser.
func (s *Service) BeginPasskeyRegistration(ctx context.Context, personID string) (*protocol.CredentialCreation, *webauthn.SessionData, error) {
	wa, err := s.passkeys()
	if err != nil {
		return nil, nil, err
	}
	u, err := s.passkeyUser(ctx, s.db.Read(), personID)
	if err != nil {
		return nil, nil, err
	}
	return wa.BeginRegistration(u,
		webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired),
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{ResidentKey: protocol.ResidentKeyRequirementRequired, UserVerification: protocol.VerificationPreferred}),
		webauthn.WithConveyancePreference(protocol.PreferNoAttestation),
	)
}

// FinishPasskeyRegistration checks the browser's answer and stores the
// passkey as a credential of the person, labelled after the browser.
func (s *Service) FinishPasskeyRegistration(ctx context.Context, personID, label string, sd webauthn.SessionData, r *http.Request) (string, error) {
	wa, err := s.passkeys()
	if err != nil {
		return "", err
	}
	u, err := s.passkeyUser(ctx, s.db.Read(), personID)
	if err != nil {
		return "", err
	}
	cred, err := wa.FinishRegistration(u, sd, r)
	if err != nil {
		return "", domain.Invalid("passkey", "%s", err.Error())
	}
	raw, err := json.Marshal(cred)
	if err != nil {
		return "", err
	}
	pk := string(raw)
	sum := sha256.Sum256(cred.ID)
	id := domain.NewID()
	if len(label) > 80 {
		label = label[:80]
	}
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		return q.InsertCredential(ctx, db.InsertCredentialParams{ID: id, PersonID: personID, Kind: domain.KindPasskey, PublicKey: &pk, Hash: sum[:], Label: label, Platform: "web", CreatedAt: s.nowMs()})
	})
	if err != nil {
		return "", err
	}
	return id, nil
}

// BeginPasskeyLogin starts a sign-in with any passkey of this server.
func (s *Service) BeginPasskeyLogin() (*protocol.CredentialAssertion, *webauthn.SessionData, error) {
	wa, err := s.passkeys()
	if err != nil {
		return nil, nil, err
	}
	return wa.BeginDiscoverableLogin(webauthn.WithUserVerification(protocol.VerificationPreferred))
}

// FinishPasskeyLogin checks the browser's assertion and names the person and
// the passkey that signed in; the passkey's record keeps its sign count.
func (s *Service) FinishPasskeyLogin(ctx context.Context, sd webauthn.SessionData, r *http.Request) (personID, credentialID string, err error) {
	wa, err := s.passkeys()
	if err != nil {
		return "", "", err
	}
	q := s.db.Read()
	var rowID string
	handler := func(rawID, userHandle []byte) (webauthn.User, error) {
		sum := sha256.Sum256(rawID)
		c, err := q.GetCredentialByHash(ctx, sum[:])
		if err != nil || c.Kind != domain.KindPasskey || c.RevokedAt != nil || c.PersonID != string(userHandle) {
			return nil, domain.ErrNotFound
		}
		rowID = c.ID
		return s.passkeyUser(ctx, q, c.PersonID)
	}
	user, cred, err := wa.FinishPasskeyLogin(handler, sd, r)
	if err != nil {
		return "", "", domain.ErrUnauthorized
	}
	if cred.Authenticator.CloneWarning {
		return "", "", domain.ErrUnauthorized
	}
	personID = string(user.WebAuthnID())
	raw, err := json.Marshal(cred)
	if err != nil {
		return "", "", err
	}
	pk := string(raw)
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		return q.UpdateCredentialPublicKey(ctx, db.UpdateCredentialPublicKeyParams{PublicKey: &pk, ID: rowID})
	})
	if err != nil {
		return "", "", err
	}
	s.Touch(ctx, rowID, personID)
	return personID, rowID, nil
}
