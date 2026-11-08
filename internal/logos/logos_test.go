package logos

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// The client asks logo.dev's logo endpoint with the secret key, downloads
// the temporary URL it answers with as a PNG and shrinks it; the worker
// stores what came back, lets a shop without a logo be, and asks again for
// a brand still being indexed.

func pngBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := range w {
		for y := range h {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 200, 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestClientFetchesAndShrinks(t *testing.T) {
	var asked, downloaded string
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v2/brands/logo":
			if r.Header.Get("Authorization") != "Bearer sk_test" {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			asked = r.URL.RawQuery
			switch r.URL.Query().Get("domain") + r.URL.Query().Get("name") {
			case "slow.example":
				w.Header().Set("Retry-After", "7")
				w.WriteHeader(http.StatusAccepted)
			case "nobody.example":
				http.Error(w, `{"error":{"code":"resource_missing"}}`, http.StatusNotFound)
			default:
				_, _ = io.WriteString(w, `{"data":{"object":"image","url":"`+srv.URL+`/asset/abc","etag":"e1"},"metadata":{}}`)
			}
		case "/asset/abc":
			downloaded = r.URL.RawQuery
			if r.Header.Get("Authorization") != "" {
				http.Error(w, "the download must not carry the key", http.StatusBadRequest)
				return
			}
			_, _ = w.Write(pngBytes(t, 600, 300))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	c := NewClient(Config{URL: srv.URL, APIKey: "sk_test", Timeout: 5 * time.Second})
	logo, err := c.Fetch(context.Background(), "ah.nl", "Albert Heijn")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(asked, "domain=ah.nl") || strings.Contains(asked, "name=") {
		t.Errorf("asked with %q, want the domain alone", asked)
	}
	if !strings.Contains(downloaded, "size=256") || !strings.Contains(downloaded, "format=png") {
		t.Errorf("downloaded with %q", downloaded)
	}
	img, err := png.Decode(bytes.NewReader(logo.PNG))
	if err != nil || img.Bounds().Dx() != 256 || img.Bounds().Dy() != 128 || logo.ETag != "e1" {
		t.Errorf("logo %v %v etag %q, want 256x128 e1", err, img.Bounds(), logo.ETag)
	}
	if _, err := c.Fetch(context.Background(), "", "Jumbo"); err != nil || !strings.Contains(asked, "name=Jumbo") {
		t.Errorf("by name: %v asked %q", err, asked)
	}
	var pending *PendingError
	if _, err := c.Fetch(context.Background(), "slow.example", ""); !errors.As(err, &pending) || pending.After != 7*time.Second {
		t.Errorf("a brand being indexed: %v", err)
	}
	if _, err := c.Fetch(context.Background(), "nobody.example", ""); !errors.Is(err, ErrNoLogo) {
		t.Errorf("no logo: %v", err)
	}
	if _, err := c.Fetch(context.Background(), "", ""); !errors.Is(err, ErrNoLogo) {
		t.Errorf("nothing to ask with: %v", err)
	}
	if _, err := NewClient(Config{URL: srv.URL, APIKey: "wrong"}).Fetch(context.Background(), "ah.nl", ""); err == nil || !strings.Contains(err.Error(), "refused the key") {
		t.Errorf("bad key: %v", err)
	}
}

type fakeRegistry struct {
	mu     sync.Mutex
	cards  map[string]*Card
	stored map[string][]byte
}

func (f *fakeRegistry) CardForLogo(_ context.Context, _, cardID string) (*Card, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if c, ok := f.cards[cardID]; ok {
		return c, nil
	}
	return nil, errors.New("no card")
}

func (f *fakeRegistry) StoreLogo(_ context.Context, _, cardID string, png []byte) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stored[cardID] = png
	return "id-" + cardID, nil
}

type fakeFetcher struct {
	mu    sync.Mutex
	calls []string
	fail  map[string]error
}

func (f *fakeFetcher) Fetch(_ context.Context, domain, name string) (*Logo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, domain+"|"+name)
	if err, ok := f.fail[domain+"|"+name]; ok {
		return nil, err
	}
	return &Logo{PNG: []byte("png:" + domain + name)}, nil
}

func TestWorkerStoresSkipsAndRetries(t *testing.T) {
	reg := &fakeRegistry{cards: map[string]*Card{
		"C1": {Name: "Albert Heijn", Domain: "ah.nl"},
		"C2": {Name: "Bieb"},
		"C3": {Name: "Gone", Domain: "gone.example", Archived: true},
		"C4": {Name: "Slow", Domain: "slow.example"},
	}, stored: map[string][]byte{}}
	fetch := &fakeFetcher{fail: map[string]error{"|Bieb": ErrNoLogo, "slow.example|Slow": &PendingError{After: time.Hour}}}
	w := New(reg, fetch, slog.New(slog.NewTextHandler(io.Discard, nil)))
	var retries []time.Duration
	w.after = func(d time.Duration, fn func()) *time.Timer {
		retries = append(retries, d)
		fn()
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- w.Run(ctx) }()
	for _, id := range []string{"C1", "C2", "C3", "C4"} {
		w.Enqueue("H", id)
	}
	deadline := time.After(5 * time.Second)
	for {
		fetch.mu.Lock()
		n := len(fetch.calls)
		fetch.mu.Unlock()
		if n >= 2+Retries+1 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("worker stalled after %d fetches", n)
		case <-time.After(10 * time.Millisecond):
		}
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Errorf("run: %v", err)
	}
	reg.mu.Lock()
	defer reg.mu.Unlock()
	if string(reg.stored["C1"]) != "png:ah.nlAlbert Heijn" || len(reg.stored) != 1 {
		t.Errorf("stored %v", reg.stored)
	}
	fetch.mu.Lock()
	defer fetch.mu.Unlock()
	joined := strings.Join(fetch.calls, ",")
	if strings.Contains(joined, "gone.example") {
		t.Error("an archived card was fetched for")
	}
	if strings.Count(joined, "slow.example|Slow") != 1+Retries || len(retries) != Retries {
		t.Errorf("a pending brand was asked %d times with %d retries: %s", strings.Count(joined, "slow.example|Slow"), len(retries), joined)
	}
	if w.LastError() == "" {
		t.Error("the pending brand that never came should be the last error")
	}
}

func TestEncodeRefusesWhatIsNotAPicture(t *testing.T) {
	if _, err := Encode([]byte("<svg/>")); err == nil {
		t.Error("an SVG is not decoded here")
	}
	out, err := Encode(pngBytes(t, 20, 20))
	if err != nil {
		t.Fatal(err)
	}
	if img, _ := png.Decode(bytes.NewReader(out)); img.Bounds().Dx() != 20 {
		t.Error("a small picture is kept as it is")
	}
}
