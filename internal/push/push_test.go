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
	changes []Change
	spoken  map[string]int64 // credential -> seq
}

func (f *fakeReg) RecordSpoken(_ context.Context, _, credentialID string, seq int64) error {
	if f.spoken == nil {
		f.spoken = map[string]int64{}
	}
	f.spoken[credentialID] = seq
	for i := range f.targets {
		if f.targets[i].CredentialID == credentialID {
			f.targets[i].SpokenAt = f.now().UnixMilli()
			f.targets[i].SpokenSeq = seq
		}
	}
	return nil
}

func (f *fakeReg) Changes(_ context.Context, _ string, _, _ int64) ([]Change, error) {
	return f.changes, nil
}

func (f *fakeReg) Unseen(_ context.Context, _, person string, _ int64) (int, error) {
	n := 0
	for _, c := range f.changes {
		if c.PersonID != person && !c.Cleared {
			n++
		}
	}
	return n, nil
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
	sent    []string
	alerts  int
	sandbox []string
	fail    map[string]error
}

func (s *fakeSender) Send(_ context.Context, token string, payload []byte, alert, sandbox bool) error {
	s.sent = append(s.sent, token+" "+string(payload))
	if alert {
		s.alerts++
	}
	if sandbox {
		s.sandbox = append(s.sandbox, token)
	}
	return s.fail[token]
}

func TestCoalescesAndClearsBadTokens(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	reg := &fakeReg{targets: []Target{{CredentialID: "c1", Token: "t1"}, {CredentialID: "c2", Token: "t2"}}, pushed: map[string]int64{}, now: func() time.Time { return now }}
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
	reg := &fakeReg{targets: []Target{{CredentialID: "c1", Token: "t1"}}, pushed: map[string]int64{}, now: time.Now}
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
	a := NewAPNs(key, "KEYID", "TEAMID", "nl.w4j.doma")
	now := time.Unix(1_800_000_000, 0)
	a.now = func() time.Time { return now }
	tok1, err := a.providerToken()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(tok1, ".") != 2 {
		t.Errorf("token %q", tok1)
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

// TestAlertsSayWhatOthersDid: the person who made the change gets the silent
// push; everyone else reads who added what, in family words.
func TestAlertsSayWhatOthersDid(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	reg := &fakeReg{
		targets: []Target{{CredentialID: "c1", Token: "t1", PersonID: "sam"}, {CredentialID: "c2", Token: "t2", PersonID: "jaro", Sandbox: true}},
		pushed:  map[string]int64{}, now: func() time.Time { return now },
		changes: []Change{
			{PersonID: "sam", Person: "Sam", ListID: "L1", List: "Shopping", Item: "melk"},
			{PersonID: "sam", Person: "Sam", ListID: "L1", List: "Shopping", Item: "brood"},
		},
	}
	snd := &fakeSender{}
	p := New(reg, snd, "https://doma.test", slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	p.SetClock(func() time.Time { return now })
	p.Handle(context.Background(), bus.HouseholdChanged{HouseholdID: "h", Seq: 7})
	if len(snd.sent) != 2 || snd.alerts != 1 {
		t.Fatalf("sent %v alerts %d", snd.sent, snd.alerts)
	}
	if strings.Contains(snd.sent[0], `"alert"`) || !strings.Contains(snd.sent[0], `"content-available":1`) {
		t.Errorf("sam's own change should be silent: %s", snd.sent[0])
	}
	if !strings.Contains(snd.sent[1], `"body":"Sam added melk and brood"`) || !strings.Contains(snd.sent[1], `"title":"Shopping"`) || !strings.Contains(snd.sent[1], `"thread-id":"L1"`) || !strings.Contains(snd.sent[1], `"seq":7`) {
		t.Errorf("jaro's alert: %s", snd.sent[1])
	}
	if !strings.Contains(snd.sent[1], `"badge":2`) || !strings.Contains(snd.sent[1], `"sound":"chime.caf"`) {
		t.Errorf("jaro's alert badge and sound: %s", snd.sent[1])
	}
	// each device's token goes to its own gateway
	if len(snd.sandbox) != 1 || snd.sandbox[0] != "t2" {
		t.Errorf("sandbox tokens: %v", snd.sandbox)
	}
}

func TestCompose(t *testing.T) {
	sam := func(item string) Change {
		return Change{PersonID: "sam", Person: "Sam", ListID: "L1", List: "Shopping", Item: item}
	}
	cases := []struct {
		name    string
		changes []Change
		want    string
	}{
		{"one", []Change{sam("melk")}, "Sam added melk"},
		{"three", []Change{sam("melk"), sam("brood"), sam("kaas")}, "Sam added melk, brood and kaas"},
		{"many", []Change{sam("a"), sam("b"), sam("c"), sam("d"), sam("e")}, "Sam added a, b and 3 more"},
		{"cleared", []Change{{PersonID: "sam", Person: "Sam", ListID: "L1", List: "Shopping", Cleared: true}}, "Sam cleared Shopping"},
		{"added then cleared", []Change{sam("melk"), {PersonID: "sam", Person: "Sam", ListID: "L1", List: "Shopping", Cleared: true}}, "Sam added melk, and cleared Shopping"},
		{"two people", []Change{sam("melk"), {PersonID: "ann", Person: "Ann", ListID: "L1", List: "Shopping", Item: "brood"}}, "The family added melk and brood"},
		{"only mine", []Change{{PersonID: "jaro", Person: "Jaro", ListID: "L1", List: "Shopping", Item: "melk"}}, ""},
		{"repeat item once", []Change{sam("melk"), sam("melk")}, "Sam added melk"},
	}
	for _, c := range cases {
		if _, body, _ := Compose(c.changes, "jaro"); body != c.want {
			t.Errorf("%s: %q, want %q", c.name, body, c.want)
		}
	}
	if title, _, thread := Compose([]Change{sam("melk"), {PersonID: "sam", Person: "Sam", ListID: "L2", List: "Weekend", Item: "wijn"}}, "jaro"); title != "Lists" || thread != "lists" {
		t.Errorf("two lists: %q %q", title, thread)
	}
}

// TestSpokenPushesWaitAndFilter: words at most every two minutes, nothing about a muted
// list, clears only when asked for.
func TestSpokenPushesWaitAndFilter(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	reg := &fakeReg{
		targets: []Target{{CredentialID: "c2", Token: "t2", PersonID: "jaro", MutedLists: []string{"L2"}, NotifyClears: false}},
		pushed:  map[string]int64{}, now: func() time.Time { return now },
		changes: []Change{
			{PersonID: "sam", Person: "Sam", ListID: "L1", List: "Shopping", Item: "melk"},
			{PersonID: "sam", Person: "Sam", ListID: "L2", List: "Weekend", Item: "wijn"},
			{PersonID: "sam", Person: "Sam", ListID: "L1", List: "Shopping", Cleared: true},
		},
	}
	snd := &fakeSender{}
	p := New(reg, snd, "https://doma.test", slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	p.SetClock(func() time.Time { return now })
	p.Handle(context.Background(), bus.HouseholdChanged{HouseholdID: "h", Seq: 7})
	if snd.alerts != 1 || !strings.Contains(snd.sent[0], `"body":"Sam added melk"`) || strings.Contains(snd.sent[0], "wijn") || strings.Contains(snd.sent[0], "cleared") {
		t.Fatalf("filtered words: %v", snd.sent)
	}
	if reg.spoken["c2"] != 7 {
		t.Errorf("spoken seq %v", reg.spoken)
	}
	// a minute on: more changes, but the words wait; the sync push still goes
	now = now.Add(time.Minute)
	p.Handle(context.Background(), bus.HouseholdChanged{HouseholdID: "h", Seq: 9})
	if len(snd.sent) != 2 || snd.alerts != 1 {
		t.Errorf("inside the spoken window: alerts %d sent %d", snd.alerts, len(snd.sent))
	}
	// two minutes on: words again
	now = now.Add(2 * time.Minute)
	p.Handle(context.Background(), bus.HouseholdChanged{HouseholdID: "h", Seq: 11})
	if snd.alerts != 2 {
		t.Errorf("after the spoken window: alerts %d", snd.alerts)
	}
}
