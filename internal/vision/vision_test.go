package vision

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The client speaks OpenAI's chat completions with the picture inline, reads
// the JSON out of the model's prose, and the worker proposes only what is
// confident and differs from the flags.

func TestClientAsksAndReadsTheAnswer(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer k" {
			http.Error(w, "wrong call", http.StatusNotFound)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &got)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"Sure. {\"items\":[{\"name\":\"melk\",\"state\":\"Low\",\"confidence\":0.9},{\"name\":\"kaas\",\"state\":\"plenty\",\"confidence\":0.9}]}"}}]}`))
	}))
	defer srv.Close()
	c := NewClient(Config{URL: srv.URL + "/v1", Model: "m", APIKey: "k", Timeout: 5 * time.Second})
	seen, err := c.Look(context.Background(), []byte("jpeg"), "Fridge", "Gouda", []string{"melk", "kaas"})
	if err != nil {
		t.Fatal(err)
	}
	if len(seen) != 1 || seen[0].Name != "melk" || seen[0].State != "low" {
		t.Errorf("seen %+v, want melk low and the strange state dropped", seen)
	}
	if got["model"] != "m" {
		t.Errorf("model %v", got["model"])
	}
	msgs, _ := got["messages"].([]any)
	if len(msgs) != 2 {
		t.Fatalf("messages %v", got["messages"])
	}
	user, _ := msgs[1].(map[string]any)
	parts, _ := user["content"].([]any)
	if len(parts) != 2 {
		t.Fatalf("the user message carries the text and the picture: %v", user["content"])
	}
	text, _ := parts[0].(map[string]any)
	if !strings.Contains(text["text"].(string), "melk, kaas") || !strings.Contains(text["text"].(string), `"Fridge"`) {
		t.Errorf("prompt lacks the names or the spot: %v", text["text"])
	}
	img, _ := parts[1].(map[string]any)
	url, _ := img["image_url"].(map[string]any)
	if !strings.HasPrefix(url["url"].(string), "data:image/jpeg;base64,") {
		t.Errorf("the picture is not inline: %v", url)
	}
}

func TestClientRefusalsAndBadAnswers(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{"server error", 500, "boom", "answered 500"},
		{"no choice", 200, `{"choices":[]}`, "no choice"},
		{"no json", 200, `{"choices":[{"message":{"content":"I cannot tell."}}]}`, "no JSON"},
		{"not completion", 200, `nope`, "not a chat completion"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(c.status)
				_, _ = w.Write([]byte(c.body))
			}))
			defer srv.Close()
			_, err := NewClient(Config{URL: srv.URL, Model: "m"}).Look(context.Background(), nil, "s", "h", []string{"x"})
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("err %v, want %q", err, c.want)
			}
		})
	}
}

type fakeRegistry struct {
	photo    *Photo
	proposed []Proposal
	homeID   string
}

func (f *fakeRegistry) PhotoForVision(context.Context, string, string) (*Photo, error) {
	if f.photo == nil {
		return nil, errors.New("no photo")
	}
	return f.photo, nil
}

func (f *fakeRegistry) ProposeFlags(_ context.Context, _, homeID, _ string, props []Proposal) error {
	f.homeID, f.proposed = homeID, props
	return nil
}

type fakeLooker struct {
	seen  []Seen
	names []string
}

func (f *fakeLooker) Look(_ context.Context, _ []byte, _, _ string, names []string) ([]Seen, error) {
	f.names = names
	return f.seen, nil
}

func TestWorkerProposesWhatIsConfidentAndDifferent(t *testing.T) {
	reg := &fakeRegistry{photo: &Photo{JPEG: []byte("x"), Spot: "Fridge", Home: "Gouda", HomeID: "G", Staples: []Staple{
		{ItemID: "I1", Name: "Melk", State: "have"},
		{ItemID: "I2", Name: "kaas", State: "low"},
		{ItemID: "I3", Name: "boter", State: "unknown"},
		{ItemID: "I4", Name: "eieren", State: "have"},
	}}}
	look := &fakeLooker{seen: []Seen{
		{Name: "melk", State: "low", Confidence: 0.9},   // differs, confident: proposed, name matched loosely
		{Name: "kaas", State: "low", Confidence: 0.9},   // the same as the flag: nothing to say
		{Name: "boter", State: "have", Confidence: 0.8}, // unknown counts as different: proposed
		{Name: "eieren", State: "out", Confidence: 0.3}, // not confident enough
		{Name: "wijn", State: "out", Confidence: 0.9},   // not a staple here
		{Name: "melk", State: "out", Confidence: 0.95},  // a second word on melk: the first stands
	}}
	w := New(reg, look, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := w.Handle(context.Background(), "H", "P"); err != nil {
		t.Fatal(err)
	}
	if strings.Join(look.names, ",") != "Melk,kaas,boter,eieren" {
		t.Errorf("the model was asked about %v", look.names)
	}
	want := []Proposal{{ItemID: "I1", State: "low"}, {ItemID: "I3", State: "have"}}
	if reg.homeID != "G" || len(reg.proposed) != len(want) {
		t.Fatalf("proposed %+v at %q, want %+v at G", reg.proposed, reg.homeID, want)
	}
	for i := range want {
		if reg.proposed[i] != want[i] {
			t.Errorf("proposal %d: %+v, want %+v", i, reg.proposed[i], want[i])
		}
	}
	// nothing differs: nothing is written
	look.seen = []Seen{{Name: "melk", State: "have", Confidence: 1}}
	reg.proposed = nil
	if err := w.Handle(context.Background(), "H", "P"); err != nil || reg.proposed != nil {
		t.Errorf("a photo that agrees with the flags: %v %+v", err, reg.proposed)
	}
	// a failed look is the last error, a good one clears it
	w.setLast(errors.New("the model answered 500"))
	if w.LastError() == "" {
		t.Error("no last error")
	}
	w.setLast(nil)
	if w.LastError() != "" {
		t.Error("last error not cleared")
	}
}
