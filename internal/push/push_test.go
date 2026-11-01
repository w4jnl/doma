package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/bus"
)

type fakeReg struct {
	targets []Target
	pushed  map[string]int64 // credential -> sent_at
	cleared []string
	now     func() time.Time
}

func (f *fakeReg) PushTargets(_ context.Context, _ string, notBefore int64) ([]Target, error) {
	var out []Target
	for _, t := range f.targets {
		if at, ok := f.pushed[t.CredentialID]; !ok || at < notBefore {
			out = append(out, t)
		}
	}
	return out, nil
}

func (f *fakeReg) RecordPush(_ context.Context, _, credentialID string, _ int64) error {
	f.pushed[credentialID] = f.now().UnixMilli()
	return nil
}

func (f *fakeReg) ClearPushToken(_ context.Context, credentialID string) error {
	f.cleared = append(f.cleared, credentialID)
	return nil
}

type fakeSender struct {
	sent []string
	fail map[string]error
}

func (s *fakeSender) Send(_ context.Context, token string, payload []byte) error {
	s.sent = append(s.sent, token+" "+string(payload))
	return s.fail[token]
}

func TestCoalescesAndClearsBadTokens(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	reg := &fakeReg{targets: []Target{{"c1", "t1"}, {"c2", "t2"}}, pushed: map[string]int64{}, now: func() time.Time { return now }}
	snd := &fakeSender{fail: map[string]error{"t2": ErrBadToken}}
	p := New(reg, snd, "https://doma.test", slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	p.SetClock(func() time.Time { return now })
	p.Handle(context.Background(), bus.HouseholdChanged{HouseholdID: "h", Seq: 7})
	if len(snd.sent) != 2 || !strings.Contains(snd.sent[0], `"seq":7`) || !strings.Contains(snd.sent[0], `"content-available":1`) || !strings.Contains(snd.sent[0], `"server":"https://doma.test"`) {
		t.Fatalf("sent %v", snd.sent)
	}
	if len(reg.cleared) != 1 || reg.cleared[0] != "c2" {
		t.Errorf("cleared %v", reg.cleared)
	}
	// ten seconds on: nothing, the window holds
	now = now.Add(10 * time.Second)
	p.Handle(context.Background(), bus.HouseholdChanged{HouseholdID: "h", Seq: 8})
	if len(snd.sent) != 2 {
		t.Errorf("pushed inside the window: %v", snd.sent)
	}
	now = now.Add(25 * time.Second)
	p.Handle(context.Background(), bus.HouseholdChanged{HouseholdID: "h", Seq: 9})
	if len(snd.sent) != 4 {
		t.Errorf("not pushed after the window: %v", snd.sent)
	}
}

// TestDisabledNeverSends is the push side of the spec's promise: with no
// sender, which is what push.enabled = false gives, a change costs nothing
// and dials nothing.
func TestDisabledNeverSends(t *testing.T) {
	reg := &fakeReg{targets: []Target{{"c1", "t1"}}, pushed: map[string]int64{}, now: time.Now}
	p := New(reg, nil, "https://doma.test", slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	b := bus.New()
	ch := b.Subscribe()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx, ch) }()
	b.Publish(bus.HouseholdChanged{HouseholdID: "h", Seq: 1})
	time.Sleep(20 * time.Millisecond)
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Errorf("Run returned %v", err)
	}
	if p.Sent != 0 || len(reg.pushed) != 0 {
		t.Errorf("disabled pusher sent %d, recorded %v", p.Sent, reg.pushed)
	}
}

func TestParseKeyAndJWT(t *testing.T) {
	priv, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(priv)
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	key, err := ParseKey(pemBytes)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseKey([]byte("nope")); err == nil {
		t.Error("garbage parsed")
	}
	a := NewAPNs(key, "KEYID", "TEAMID", "nl.w4j.doma", true)
	now := time.Unix(1_800_000_000, 0)
	a.now = func() time.Time { return now }
	tok1, err := a.providerToken()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(tok1, ".") != 2 || a.host != HostSandbox {
		t.Errorf("token %q host %s", tok1, a.host)
	}
	now = now.Add(10 * time.Minute)
	tok2, _ := a.providerToken()
	if tok2 != tok1 {
		t.Error("token not reused inside its lifetime")
	}
	now = now.Add(time.Hour)
	tok3, _ := a.providerToken()
	if tok3 == tok1 {
		t.Error("token not refreshed after its lifetime")
	}
}
