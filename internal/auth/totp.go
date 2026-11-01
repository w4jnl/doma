package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1" //nolint:gosec // G505: TOTP is specified over HMAC-SHA1
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// TOTP per RFC 6238: SHA-1, six digits, thirty seconds, one step of drift.
const (
	totpDigits = 6
	totpStep   = 30 * time.Second
)

// NewTOTPSecret returns a fresh 20-byte secret in base32, the form
// authenticator apps take.
func NewTOTPSecret() (string, error) {
	b := make([]byte, 20)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b), nil
}

// TOTPURL is the otpauth link the setup QR encodes.
func TOTPURL(secret, account string) string {
	return "otpauth://totp/doma:" + url.PathEscape(account) + "?secret=" + secret + "&issuer=doma&digits=6&period=30"
}

// TOTPCode computes the code for secret at t.
func TOTPCode(secret string, t time.Time) (string, error) {
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(strings.TrimSpace(secret)))
	if err != nil {
		return "", fmt.Errorf("totp secret: %w", err)
	}
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], uint64(t.Unix()/int64(totpStep.Seconds())))
	mac := hmac.New(sha1.New, key)
	mac.Write(msg[:])
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	code := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff
	return fmt.Sprintf("%0*d", totpDigits, code%1_000_000), nil
}

// VerifyTOTP accepts the code for now, the step before and the step after.
func VerifyTOTP(secret, code string, now time.Time) bool {
	code = strings.ReplaceAll(strings.TrimSpace(code), " ", "")
	if len(code) != totpDigits {
		return false
	}
	ok := false
	for _, d := range []time.Duration{0, -totpStep, totpStep} {
		want, err := TOTPCode(secret, now.Add(d))
		if err != nil {
			return false
		}
		if subtle.ConstantTimeCompare([]byte(want), []byte(code)) == 1 {
			ok = true
		}
	}
	return ok
}
