package auth

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestSessions(t *testing.T) {
	now := time.Unix(1000, 0)
	s := NewSessions(true)
	s.Now = func() time.Time { return now }
	rec := httptest.NewRecorder()
	sess, err := s.Start(rec)
	if err != nil {
		t.Fatal(err)
	}
	cookie := rec.Result().Cookies()[0]
	if cookie.Name != AdminCookie || !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteLaxMode || cookie.Value != sess.ID {
		t.Errorf("cookie %+v", cookie)
	}
	r := httptest.NewRequest("GET", "/admin", nil)
	r.AddCookie(cookie)
	if got := s.From(r); got == nil || got.CSRF != sess.CSRF {
		t.Fatal("session not found")
	}
	form := httptest.NewRequest("POST", "/admin", strings.NewReader(url.Values{CSRFField: {sess.CSRF}}.Encode()))
	form.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if !CheckCSRF(form, sess) {
		t.Error("form token refused")
	}
	bad := httptest.NewRequest("POST", "/admin", strings.NewReader(url.Values{CSRFField: {"nope"}}.Encode()))
	bad.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if CheckCSRF(bad, sess) || CheckCSRF(bad, nil) {
		t.Error("wrong token accepted")
	}
	now = now.Add(SessionTTL + time.Second)
	if s.From(r) != nil {
		t.Error("expired session returned")
	}
	rec2 := httptest.NewRecorder()
	sess2, _ := s.Start(rec2)
	r2 := httptest.NewRequest("GET", "/admin", nil)
	r2.AddCookie(rec2.Result().Cookies()[0])
	end := httptest.NewRecorder()
	s.End(end, r2)
	if s.From(r2) != nil || end.Result().Cookies()[0].MaxAge != -1 || sess2 == nil {
		t.Error("End did not clear the session")
	}
}
