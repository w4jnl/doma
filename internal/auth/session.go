package auth

import (
	"crypto/subtle"
	"net/http"
	"sync"
	"time"
)

// Browser sessions live in memory: the admin's, and the family's in the
// web client. A restart signs them out; the admin types the password again
// and a member touches their passkey.
const (
	AdminCookie = "doma_admin"
	// MemberCookie is the web client's session, for a family member.
	MemberCookie = "doma_member"
	// MemberTTL is how long a member's browser stays signed in without a request.
	MemberTTL = 30 * 24 * time.Hour
	// CSRFField carries the double-submit token in forms, CSRFHeader on
	// htmx requests.
	CSRFField  = "_csrf"
	CSRFHeader = "X-CSRF-Token"
	// SessionTTL is how long a session lasts without a request.
	SessionTTL = 12 * time.Hour
)

// Session is one signed-in browser.
type Session struct {
	ID      string
	CSRF    string
	Expires time.Time
	// User is who the proxy named when it signed the admin in; empty for
	// doma's own sign-in. In the web client it is the member's person id.
	User string
	// Credential is the member's credential in the web client: the passkey
	// that signed in, or the phone that vouched for the browser.
	Credential string
}

// Sessions holds one cookie's sessions.
type Sessions struct {
	mu     sync.Mutex
	byID   map[string]*Session
	secure bool
	cookie string
	ttl    time.Duration
	Now    func() time.Time
}

// NewSessions returns an empty store; secure marks cookies Secure, which
// follows server.base_url's scheme.
func NewSessions(secure bool) *Sessions {
	return &Sessions{byID: map[string]*Session{}, secure: secure, cookie: AdminCookie, ttl: SessionTTL, Now: time.Now}
}

// NewMemberSessions is the web client's store: its own cookie, a month's
// sliding expiry.
func NewMemberSessions(secure bool) *Sessions {
	return &Sessions{byID: map[string]*Session{}, secure: secure, cookie: MemberCookie, ttl: MemberTTL, Now: time.Now}
}

// Start creates a session and sets its cookie.
func (s *Sessions) Start(w http.ResponseWriter) (*Session, error) { return s.StartUser(w, "") }

// StartUser is Start for a session the proxy signed in as user.
func (s *Sessions) StartUser(w http.ResponseWriter, user string) (*Session, error) {
	return s.StartMember(w, user, "")
}

// StartMember is Start for a family member's browser, with the credential
// that signed it in.
func (s *Sessions) StartMember(w http.ResponseWriter, personID, credentialID string) (*Session, error) {
	id, err := NewToken()
	if err != nil {
		return nil, err
	}
	csrf, err := NewToken()
	if err != nil {
		return nil, err
	}
	sess := &Session{ID: id, CSRF: csrf, Expires: s.Now().Add(s.ttl), User: personID, Credential: credentialID}
	s.mu.Lock()
	s.byID[id] = sess
	for k, v := range s.byID {
		if v.Expires.Before(s.Now()) {
			delete(s.byID, k)
		}
	}
	s.mu.Unlock()
	s.setCookie(w, id, sess.Expires)
	return sess, nil
}

// From returns the request's live session, or nil, and slides its expiry.
func (s *Sessions) From(r *http.Request) *Session {
	c, err := r.Cookie(s.cookie)
	if err != nil || c.Value == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.byID[c.Value]
	if !ok {
		return nil
	}
	now := s.Now()
	if sess.Expires.Before(now) {
		delete(s.byID, c.Value)
		return nil
	}
	sess.Expires = now.Add(s.ttl)
	cp := *sess
	return &cp
}

// End drops the request's session and clears the cookie.
func (s *Sessions) End(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(s.cookie); err == nil && c.Value != "" {
		s.mu.Lock()
		delete(s.byID, c.Value)
		s.mu.Unlock()
	}
	s.setCookie(w, "", time.Unix(0, 0))
}

// CheckCSRF validates the double-submit token of a form or htmx request.
func CheckCSRF(r *http.Request, sess *Session) bool {
	if sess == nil {
		return false
	}
	token := r.Header.Get(CSRFHeader)
	if token == "" {
		token = r.PostFormValue(CSRFField)
	}
	return token != "" && subtle.ConstantTimeCompare([]byte(token), []byte(sess.CSRF)) == 1
}

func (s *Sessions) setCookie(w http.ResponseWriter, value string, exp time.Time) {
	c := &http.Cookie{ //nolint:gosec // G124: Secure follows server.base_url's scheme; plain http is legitimate on a LAN install
		Name: s.cookie, Value: value, Path: "/", HttpOnly: true, Secure: s.secure, SameSite: http.SameSiteLaxMode, Expires: exp,
	}
	if value == "" {
		c.MaxAge = -1
	}
	http.SetCookie(w, c)
}
