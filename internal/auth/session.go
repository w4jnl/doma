package auth

import (
	"crypto/subtle"
	"net/http"
	"sync"
	"time"
)

// The admin's browser session: one operator, so sessions live in memory
// and a restart signs the admin out, which is fine.
const (
	AdminCookie = "doma_admin"
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
	// doma's own sign-in.
	User string
}

// Sessions holds the admin's sessions.
type Sessions struct {
	mu     sync.Mutex
	byID   map[string]*Session
	secure bool
	Now    func() time.Time
}

// NewSessions returns an empty store; secure marks cookies Secure, which
// follows server.base_url's scheme.
func NewSessions(secure bool) *Sessions {
	return &Sessions{byID: map[string]*Session{}, secure: secure, Now: time.Now}
}

// Start creates a session and sets its cookie.
func (s *Sessions) Start(w http.ResponseWriter) (*Session, error) { return s.StartUser(w, "") }

// StartUser is Start for a session the proxy signed in as user.
func (s *Sessions) StartUser(w http.ResponseWriter, user string) (*Session, error) {
	id, err := NewToken()
	if err != nil {
		return nil, err
	}
	csrf, err := NewToken()
	if err != nil {
		return nil, err
	}
	sess := &Session{ID: id, CSRF: csrf, Expires: s.Now().Add(SessionTTL), User: user}
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
	c, err := r.Cookie(AdminCookie)
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
	sess.Expires = now.Add(SessionTTL)
	cp := *sess
	return &cp
}

// End drops the request's session and clears the cookie.
func (s *Sessions) End(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(AdminCookie); err == nil && c.Value != "" {
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
		Name: AdminCookie, Value: value, Path: "/", HttpOnly: true, Secure: s.secure, SameSite: http.SameSiteLaxMode, Expires: exp,
	}
	if value == "" {
		c.MaxAge = -1
	}
	http.SetCookie(w, c)
}
