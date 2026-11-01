package auth

import (
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSignAndVerifyBothAlgorithms(t *testing.T) {
	for _, mk := range []func() (Signer, error){NewEd25519Signer, NewP256Signer} {
		s, err := mk()
		if err != nil {
			t.Fatal(err)
		}
		key, err := ParsePublicKey(s.Public())
		if err != nil {
			t.Fatalf("%s: %v", s.Public(), err)
		}
		now := time.Unix(1_700_000_000, 0)
		body := []byte(`{"households": []}`)
		r := httptest.NewRequest("POST", "/sync/v1", strings.NewReader(string(body)))
		if err := SignRequest(r, "cred1", s, body, now); err != nil {
			t.Fatal(err)
		}
		signed, err := ReadSignature(r)
		if err != nil {
			t.Fatal(err)
		}
		nonces := NewNonces()
		if err := signed.Check(key, nonces, "POST", "/sync/v1", body, now.Add(time.Minute)); err != nil {
			t.Fatalf("%s: valid request refused: %v", key.Algo, err)
		}
		if err := signed.Check(key, nonces, "POST", "/sync/v1", body, now.Add(time.Minute)); !errors.Is(err, ErrBadSignature) || !strings.Contains(err.Error(), "replay") {
			t.Errorf("%s: replay accepted: %v", key.Algo, err)
		}
		fresh := NewNonces()
		if err := signed.Check(key, fresh, "POST", "/sync/v1", []byte(`{}`), now); err == nil {
			t.Errorf("%s: changed body accepted", key.Algo)
		}
		if err := signed.Check(key, fresh, "POST", "/api/v1/me", body, now); err == nil {
			t.Errorf("%s: changed path accepted", key.Algo)
		}
		if err := signed.Check(key, fresh, "POST", "/sync/v1", body, now.Add(6*time.Minute)); err == nil || !strings.Contains(err.Error(), "five minutes") {
			t.Errorf("%s: stale timestamp accepted: %v", key.Algo, err)
		}
		other, _ := mk()
		otherKey, _ := ParsePublicKey(other.Public())
		if err := signed.Check(otherKey, fresh, "POST", "/sync/v1", body, now); err == nil {
			t.Errorf("%s: another key accepted", key.Algo)
		}
	}
}

func TestParsePublicKeyRejects(t *testing.T) {
	for _, bad := range []string{"", "ed25519", "ed25519:!!", "ed25519:AAAA", "rsa:AAAA", "p256:AAAA"} {
		if _, err := ParsePublicKey(bad); err == nil {
			t.Errorf("ParsePublicKey(%q) accepted", bad)
		}
	}
	// a 65-byte uncompressed point is accepted too
	s, _ := NewP256Signer()
	raw := s.Public()
	if _, err := ParsePublicKey(raw); err != nil {
		t.Fatal(err)
	}
}

func TestReadSignatureMissing(t *testing.T) {
	r := httptest.NewRequest("GET", "/api/v1/me", nil)
	if _, err := ReadSignature(r); !errors.Is(err, ErrBadSignature) {
		t.Errorf("missing headers: %v", err)
	}
	r.Header.Set(HeaderCredential, "c")
	r.Header.Set(HeaderTimestamp, "1")
	r.Header.Set(HeaderSignature, "not base64!")
	if _, err := ReadSignature(r); !errors.Is(err, ErrBadSignature) {
		t.Errorf("bad base64: %v", err)
	}
}

func TestPasswordAndTokens(t *testing.T) {
	FastParamsForTests()
	h, err := HashPassword("correct horse")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$") || !VerifyPassword(h, "correct horse") || VerifyPassword(h, "wrong") || VerifyPassword("", "x") {
		t.Error("password hashing")
	}
	tok, err := NewToken()
	if err != nil || len(tok) != 43 || strings.ContainsAny(tok, "+/=") {
		t.Errorf("token %q %v", tok, err)
	}
	if len(HashToken(tok)) != 32 || string(HashToken(tok)) == string(HashToken(tok+"x")) {
		t.Error("token hash")
	}
}
