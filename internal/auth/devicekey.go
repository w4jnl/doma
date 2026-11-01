package auth

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Header names of a signed app request.
const (
	HeaderCredential = "Doma-Credential" //nolint:gosec // G101: a header name, not a secret
	HeaderTimestamp  = "Doma-Timestamp"
	HeaderSignature  = "Doma-Signature"
	// MaxSkew is how far a request's timestamp may be from the server's clock.
	MaxSkew = 5 * time.Minute
)

// Algorithms a public key may carry.
const (
	AlgoEd25519 = "ed25519"
	AlgoP256    = "p256"
)

// ErrBadSignature covers every way a signed request fails.
var ErrBadSignature = errors.New("bad signature")

// PublicKey is a device's key, stored as "<algo>:<base64>": raw 32 bytes
// for Ed25519, the 64-byte X||Y or 65-byte uncompressed point for P-256.
type PublicKey struct {
	Algo string
	ed   ed25519.PublicKey
	ec   *ecdsa.PublicKey
	raw  string
}

// ParsePublicKey reads the stored form.
func ParsePublicKey(s string) (*PublicKey, error) {
	algo, b64, ok := strings.Cut(s, ":")
	if !ok {
		return nil, errors.New("public key must be <algo>:<base64>")
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("public key: %w", err)
	}
	switch algo {
	case AlgoEd25519:
		if len(raw) != ed25519.PublicKeySize {
			return nil, errors.New("ed25519 public key must be 32 bytes")
		}
		return &PublicKey{Algo: algo, ed: ed25519.PublicKey(raw), raw: s}, nil
	case AlgoP256:
		if len(raw) == 64 {
			raw = append([]byte{4}, raw...)
		}
		if len(raw) != 65 {
			return nil, errors.New("p256 public key must be 64 or 65 bytes")
		}
		pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), raw)
		if err != nil {
			return nil, fmt.Errorf("p256 public key: %w", err)
		}
		return &PublicKey{Algo: algo, ec: pub, raw: s}, nil
	}
	return nil, fmt.Errorf("unknown key algorithm %q", algo)
}

// String is the stored form.
func (k *PublicKey) String() string { return k.raw }

// Verify checks sig over message: Ed25519 over the message, or P-256 ECDSA
// over its SHA-256 with the 64-byte r||s signature.
func (k *PublicKey) Verify(message, sig []byte) bool {
	switch k.Algo {
	case AlgoEd25519:
		return len(sig) == ed25519.SignatureSize && ed25519.Verify(k.ed, message, sig)
	case AlgoP256:
		if len(sig) != 64 {
			return false
		}
		sum := sha256.Sum256(message)
		return ecdsa.Verify(k.ec, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
	}
	return false
}

// SigningString is what a device signs: method, path, timestamp and the
// hex SHA-256 of the body, newline-separated.
func SigningString(method, path, timestamp string, body []byte) []byte {
	sum := sha256.Sum256(body)
	return []byte(method + "\n" + path + "\n" + timestamp + "\n" + hex.EncodeToString(sum[:]))
}

// Signer is a device's private key, for the apps' Go test client, the e2e
// smoke and the tests here.
type Signer interface {
	Sign(message []byte) ([]byte, error)
	Public() string
}

type ed25519Signer struct {
	priv ed25519.PrivateKey
}

// NewEd25519Signer makes a fresh Ed25519 key.
func NewEd25519Signer() (Signer, error) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return &ed25519Signer{priv: priv}, nil
}

func (s *ed25519Signer) Sign(message []byte) ([]byte, error) {
	return ed25519.Sign(s.priv, message), nil
}

func (s *ed25519Signer) Public() string {
	return AlgoEd25519 + ":" + base64.StdEncoding.EncodeToString(s.priv.Public().(ed25519.PublicKey))
}

type p256Signer struct {
	priv *ecdsa.PrivateKey
}

// NewP256Signer makes a fresh P-256 key, as a Secure Enclave would.
func NewP256Signer() (Signer, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return &p256Signer{priv: priv}, nil
}

func (s *p256Signer) Sign(message []byte) ([]byte, error) {
	sum := sha256.Sum256(message)
	r, sv, err := ecdsa.Sign(rand.Reader, s.priv, sum[:])
	if err != nil {
		return nil, err
	}
	out := make([]byte, 64)
	r.FillBytes(out[:32])
	sv.FillBytes(out[32:])
	return out, nil
}

func (s *p256Signer) Public() string {
	// the 64-byte X||Y form CryptoKit calls rawRepresentation
	raw, _ := s.priv.PublicKey.Bytes()
	return AlgoP256 + ":" + base64.StdEncoding.EncodeToString(raw[1:])
}

// SignRequest sets the three headers on r for body, with the device's
// clock at now. The timestamp is Unix milliseconds: with a deterministic
// signature, two identical requests in one second would otherwise read as
// a replay.
func SignRequest(r *http.Request, credentialID string, s Signer, body []byte, now time.Time) error {
	ts := strconv.FormatInt(now.UnixMilli(), 10)
	sig, err := s.Sign(SigningString(r.Method, r.URL.Path, ts, body))
	if err != nil {
		return err
	}
	r.Header.Set(HeaderCredential, credentialID)
	r.Header.Set(HeaderTimestamp, ts)
	r.Header.Set(HeaderSignature, base64.StdEncoding.EncodeToString(sig))
	return nil
}

// Nonces remembers the signatures seen per credential inside the skew
// window, so a captured request cannot be replayed.
type Nonces struct {
	mu   sync.Mutex
	seen map[string]time.Time
	ops  int
}

// NewNonces returns an empty cache.
func NewNonces() *Nonces { return &Nonces{seen: map[string]time.Time{}} }

// Seen records credential+sig and reports whether it was already there.
func (n *Nonces) Seen(credentialID, sig string, now time.Time) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.ops++
	if n.ops%1000 == 0 {
		for k, t := range n.seen {
			if now.Sub(t) > MaxSkew {
				delete(n.seen, k)
			}
		}
	}
	key := credentialID + "\x00" + sig
	if t, ok := n.seen[key]; ok && now.Sub(t) <= MaxSkew {
		return true
	}
	n.seen[key] = now
	return false
}

// Signed is what a request carries once read.
type Signed struct {
	CredentialID string
	Timestamp    string
	Signature    []byte
	raw          string
}

// ReadSignature pulls the headers off r. A missing header is ErrBadSignature.
func ReadSignature(r *http.Request) (*Signed, error) {
	id := r.Header.Get(HeaderCredential)
	ts := r.Header.Get(HeaderTimestamp)
	raw := r.Header.Get(HeaderSignature)
	if id == "" || ts == "" || raw == "" {
		return nil, fmt.Errorf("%w: missing header", ErrBadSignature)
	}
	sig, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("%w: signature is not base64", ErrBadSignature)
	}
	return &Signed{CredentialID: id, Timestamp: ts, Signature: sig, raw: raw}, nil
}

// Check verifies s against key for the request's method, path and body at
// now: the timestamp within MaxSkew, the signature valid, and not seen
// before.
func (s *Signed) Check(key *PublicKey, nonces *Nonces, method, path string, body []byte, now time.Time) error {
	ts, err := strconv.ParseInt(s.Timestamp, 10, 64)
	if err != nil {
		return fmt.Errorf("%w: timestamp", ErrBadSignature)
	}
	if d := now.Sub(time.UnixMilli(ts)); d > MaxSkew || d < -MaxSkew {
		return fmt.Errorf("%w: timestamp is off by more than five minutes", ErrBadSignature)
	}
	if !key.Verify(SigningString(method, path, s.Timestamp, body), s.Signature) {
		return fmt.Errorf("%w: signature does not verify", ErrBadSignature)
	}
	if nonces.Seen(s.CredentialID, s.raw, now) {
		return fmt.Errorf("%w: replay", ErrBadSignature)
	}
	return nil
}
