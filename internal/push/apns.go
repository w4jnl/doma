package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"time"
)

// DialContext is how the APNs client opens its connections; the one dial
// in doma. The egress test replaces it to prove nothing goes out when push
// is off.
var DialContext = (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext

// APNs hosts.
const (
	HostProduction = "api.push.apple.com"
	HostSandbox    = "api.sandbox.push.apple.com"
)

// jwtLifetime is how long one provider token is reused: Apple wants a
// fresh one at least every hour and not more often than every 20 minutes.
const jwtLifetime = 50 * time.Minute

// APNs sends through Apple's HTTP/2 API with token-based auth.
type APNs struct {
	client *http.Client
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	topic  string
	now    func() time.Time

	mu       sync.Mutex
	token    string
	issuedAt time.Time
}

// ParseKey reads the .p8 file Apple issues: a PKCS#8 EC private key.
func ParseKey(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("apns key: not PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns key: %w", err)
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apns key: not an EC key")
	}
	return ec, nil
}

// NewAPNs builds the sender. This is the one place doma opens an outbound
// connection; it is only called when push.enabled is true.
func NewAPNs(key *ecdsa.PrivateKey, keyID, teamID, topic string) *APNs {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return DialContext(ctx, network, addr)
		},
		ForceAttemptHTTP2: true, MaxIdleConns: 2, IdleConnTimeout: 10 * time.Minute, TLSHandshakeTimeout: 10 * time.Second,
	}
	return &APNs{client: &http.Client{Transport: transport, Timeout: 15 * time.Second}, key: key, keyID: keyID, teamID: teamID, topic: topic, now: time.Now}
}

// Send posts one background push.
func (a *APNs) Send(ctx context.Context, deviceToken string, payload []byte, alert, sandbox bool) error {
	jwt, err := a.providerToken()
	if err != nil {
		return err
	}
	// the gateway is the token's: a development build's token lives on the sandbox host
	host := HostProduction
	if sandbox {
		host = HostSandbox
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+host+"/3/device/"+deviceToken, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", a.topic)
	if alert {
		req.Header.Set("apns-push-type", "alert")
		req.Header.Set("apns-priority", "10")
	} else {
		req.Header.Set("apns-push-type", "background")
		req.Header.Set("apns-priority", "5")
	}
	req.Header.Set("content-type", "application/json")
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var apple struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(body, &apple)
	if resp.StatusCode == http.StatusGone || apple.Reason == "BadDeviceToken" || apple.Reason == "Unregistered" || apple.Reason == "DeviceTokenNotForTopic" {
		return fmt.Errorf("%w: %s", ErrBadToken, apple.Reason)
	}
	return fmt.Errorf("apns %d: %s", resp.StatusCode, apple.Reason)
}

// providerToken returns the cached ES256 token, minting a new one when the
// old is past its lifetime.
func (a *APNs) providerToken() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	if a.token != "" && now.Sub(a.issuedAt) < jwtLifetime {
		return a.token, nil
	}
	tok, err := signJWT(a.key, a.keyID, a.teamID, now)
	if err != nil {
		return "", err
	}
	a.token, a.issuedAt = tok, now
	return tok, nil
}

// signJWT makes the provider token: ES256 over header.claims.
func signJWT(key *ecdsa.PrivateKey, keyID, teamID string, now time.Time) (string, error) {
	enc := base64.RawURLEncoding
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": keyID})
	claims, _ := json.Marshal(map[string]any{"iss": teamID, "iat": now.Unix()})
	signing := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, key, sum[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + enc.EncodeToString(sig), nil
}
