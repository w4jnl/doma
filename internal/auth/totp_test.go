package auth

import (
	"testing"
	"time"
)

func TestTOTPVector(t *testing.T) {
	// RFC 6238 appendix B, SHA-1, secret "12345678901234567890", 8 digits
	// truncated here to the last 6: at 59 s the code is 94287082.
	secret := "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	code, err := TOTPCode(secret, time.Unix(59, 0))
	if err != nil {
		t.Fatal(err)
	}
	if code != "287082" {
		t.Errorf("code %q, want 287082", code)
	}
	if !VerifyTOTP(secret, "287082", time.Unix(59, 0)) || !VerifyTOTP(secret, "287082", time.Unix(59+30, 0)) || VerifyTOTP(secret, "287082", time.Unix(59+90, 0)) || VerifyTOTP(secret, "000000", time.Unix(59, 0)) {
		t.Error("verify window")
	}
	s, err := NewTOTPSecret()
	if err != nil || len(s) != 32 {
		t.Errorf("secret %q %v", s, err)
	}
	if u := TOTPURL(s, "admin"); u != "otpauth://totp/doma:admin?secret="+s+"&issuer=doma&digits=6&period=30" {
		t.Errorf("url %s", u)
	}
}
