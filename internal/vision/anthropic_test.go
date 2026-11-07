package vision

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The Anthropic client speaks the Messages API: the picture as an image
// block, the key in x-api-key, the answer in the first text block after any
// thinking, and a refusal is an error rather than an empty judgement.

func TestAnthropicAsksAndReadsTheAnswer(t *testing.T) {
	var got map[string]any
	var hdr http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/messages" {
			http.Error(w, "wrong call", http.StatusNotFound)
			return
		}
		hdr = r.Header.Clone()
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &got)
		_, _ = w.Write([]byte(`{"type":"message","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"items\":[{\"name\":\"melk\",\"state\":\"out\",\"confidence\":0.7},{\"name\":\"kaas\",\"state\":\"maybe\",\"confidence\":0.9}]}"}]}`))
	}))
	defer srv.Close()
	c := NewLooker(Config{Provider: "anthropic", URL: srv.URL, Model: "claude-opus-5-5", APIKey: "k", Timeout: 5 * time.Second})
	if _, ok := c.(*Anthropic); !ok {
		t.Fatalf("provider anthropic built %T", c)
	}
	seen, err := c.Look(context.Background(), []byte("jpeg"), "Fridge", "Gouda", []string{"melk", "kaas"})
	if err != nil {
		t.Fatal(err)
	}
	if len(seen) != 1 || seen[0].Name != "melk" || seen[0].State != "out" {
		t.Errorf("seen %+v, want melk out and the strange state dropped", seen)
	}
	if hdr.Get("x-api-key") != "k" || hdr.Get("anthropic-version") == "" || hdr.Get("Authorization") != "" {
		t.Errorf("headers %v", hdr)
	}
	if got["model"] != "claude-opus-5-5" || got["system"] != systemPrompt {
		t.Errorf("model %v system %v", got["model"], got["system"])
	}
	msgs, _ := got["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("messages %v", got["messages"])
	}
	user, _ := msgs[0].(map[string]any)
	parts, _ := user["content"].([]any)
	if len(parts) != 2 {
		t.Fatalf("the user message carries the picture and the text: %v", user["content"])
	}
	img, _ := parts[0].(map[string]any)
	src, _ := img["source"].(map[string]any)
	if img["type"] != "image" || src["type"] != "base64" || src["media_type"] != "image/jpeg" || src["data"] != "anBlZw==" {
		t.Errorf("the picture block is wrong: %v", img)
	}
	text, _ := parts[1].(map[string]any)
	if !strings.Contains(text["text"].(string), "melk, kaas") {
		t.Errorf("prompt lacks the names: %v", text["text"])
	}
}

func TestAnthropicRefusalsAndBadAnswers(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{"server error", 401, `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`, "answered 401"},
		{"refusal", 200, `{"stop_reason":"refusal","content":[]}`, "declined"},
		{"no text", 200, `{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""}]}`, "no text"},
		{"no json", 200, `{"stop_reason":"end_turn","content":[{"type":"text","text":"I cannot tell."}]}`, "no JSON"},
		{"not a message", 200, `nope`, "not a message"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(c.status)
				_, _ = w.Write([]byte(c.body))
			}))
			defer srv.Close()
			_, err := NewAnthropic(Config{URL: srv.URL, Model: "m", APIKey: "k"}).Look(context.Background(), nil, "s", "h", []string{"x"})
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("err %v, want %q", err, c.want)
			}
		})
	}
}

func TestAnthropicDefaultsToTheirAPI(t *testing.T) {
	if a := NewAnthropic(Config{}); a.cfg.URL != "https://api.anthropic.com" {
		t.Errorf("url %q", a.cfg.URL)
	}
	if _, ok := NewLooker(Config{}).(*Client); !ok {
		t.Error("an empty provider is the OpenAI-compatible client")
	}
}
