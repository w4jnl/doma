// Package secrets is the key file under secrets.key_file: 32 bytes made
// on first run, which encrypt the APNs key and the admin's TOTP secret at
// rest with XChaCha20-Poly1305. Back it up with the database.
package secrets

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/chacha20poly1305"
)

// Keyring holds the instance key.
type Keyring struct {
	key []byte
}

// Load reads the key file, creating it with a fresh key when it does not
// exist.
func Load(path string) (*Keyring, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		raw = make([]byte, chacha20poly1305.KeySize)
		if _, err := rand.Read(raw); err != nil {
			return nil, err
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
			return nil, fmt.Errorf("create key directory: %w", err)
		}
		if err := os.WriteFile(path, raw, 0o600); err != nil {
			return nil, fmt.Errorf("write key file: %w", err)
		}
		return &Keyring{key: raw}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read key file: %w", err)
	}
	if len(raw) != chacha20poly1305.KeySize {
		return nil, fmt.Errorf("key file %s must hold exactly %d bytes, has %d", path, chacha20poly1305.KeySize, len(raw))
	}
	return &Keyring{key: raw}, nil
}

// FromBytes wraps an existing key, for tests.
func FromBytes(key []byte) (*Keyring, error) {
	if len(key) != chacha20poly1305.KeySize {
		return nil, errors.New("key must be 32 bytes")
	}
	return &Keyring{key: append([]byte(nil), key...)}, nil
}

// Prefix marks a sealed value.
const Prefix = "v1:"

// Seal encrypts plain and returns "v1:" + base64.
func (k *Keyring) Seal(plain []byte) (string, error) {
	aead, err := chacha20poly1305.NewX(k.key)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, aead.NonceSize(), aead.NonceSize()+len(plain)+aead.Overhead())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	out := aead.Seal(nonce, nonce, plain, nil)
	return Prefix + base64.StdEncoding.EncodeToString(out), nil
}

// Open decrypts a value produced by Seal.
func (k *Keyring) Open(sealed string) ([]byte, error) {
	b64, ok := strings.CutPrefix(strings.TrimSpace(sealed), Prefix)
	if !ok {
		return nil, errors.New("not a sealed value")
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.NewX(k.key)
	if err != nil {
		return nil, err
	}
	if len(raw) < aead.NonceSize() {
		return nil, errors.New("sealed value too short")
	}
	return aead.Open(nil, raw[:aead.NonceSize()], raw[aead.NonceSize():], nil)
}

// IsSealed reports whether s is a value Seal made.
func IsSealed(s string) bool { return strings.HasPrefix(strings.TrimSpace(s), Prefix) }

// SealFile encrypts a file in place when it is still plain: the APNs key
// the operator dropped next to the database, after the first start.
func (k *Keyring) SealFile(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if IsSealed(string(raw)) {
		return nil
	}
	sealed, err := k.Seal(raw)
	if err != nil {
		return err
	}
	return os.WriteFile(path, []byte(sealed), 0o600) //nolint:gosec // G703: the path is the operator's push.key_file
}

// OpenFile reads a sealed file, or a plain one, and returns its contents.
func (k *Keyring) OpenFile(path string) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if !IsSealed(string(raw)) {
		return raw, nil
	}
	return k.Open(string(raw))
}
