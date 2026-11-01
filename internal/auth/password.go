// Package auth holds what identifies a caller: argon2id password hashing
// for the admin login, device-key signatures for the apps, invite and
// guest tokens, and the admin's browser session. It is pure: the handlers
// wire it to the service.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// argon2id parameters from the design document: t=2, m=64MB, p=1.
var (
	argonTime    uint32 = 2
	argonMemory  uint32 = 64 * 1024
	argonThreads uint8  = 1
	argonKeyLen  uint32 = 32
)

const saltLen = 16

// FastParamsForTests lowers the argon2 cost so test suites that create many
// admins stay quick. Hashes made this way are still valid PHC strings;
// VerifyPassword reads the parameters from the hash.
func FastParamsForTests() {
	argonTime, argonMemory = 1, 8*1024
}

// HashPassword returns a PHC-format argon2id hash.
func HashPassword(password string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=19$m=%d,t=%d,p=%d$%s$%s", argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(key)), nil
}

// VerifyPassword reports whether password matches the PHC hash. It takes
// the same time whether or not the hash exists, so callers can pass an
// empty hash for an unknown login.
func VerifyPassword(hash, password string) bool {
	parts := strings.Split(hash, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		argon2.IDKey([]byte(password), make([]byte, saltLen), argonTime, argonMemory, argonThreads, argonKeyLen)
		return false
	}
	var m, t uint32
	var p uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, t, m, p, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// NewToken returns 32 random bytes as base64url, the form of invite and
// guest links.
func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// HashToken is how an invite or guest token is stored: its SHA-256. The
// token has 256 bits of entropy, so a plain hash is enough, and the lookup
// is by the hash.
func HashToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}
