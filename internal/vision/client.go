// Package vision asks a vision model what a photo of a spot shows of the
// home's staples and turns the answer into flag proposals for a member to
// accept or decline. It is the second place in doma that opens an outbound
// connection, after APNs: to the endpoint in vision.url, only when
// vision.enabled is true, and the client is built only then. Two wire
// formats are spoken, chosen by vision.provider: OpenAI's chat completions
// (Client) and Anthropic's Messages API (Anthropic).
package vision

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// DialContext is how the client opens its connections; the one dial in the
// package, replaceable so a test can prove nothing goes out.
var DialContext = (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext

// Config names the model: an OpenAI-compatible chat completions endpoint,
// self-hosted (Ollama, LM Studio, vLLM) or not, or Anthropic's API, which is
// the operator's call.
type Config struct {
	// Provider is the wire format: "openai" (the default) or "anthropic".
	Provider string
	// URL is the API's base, such as http://ollama:11434/v1; the OpenAI client
	// posts to URL + /chat/completions, the Anthropic one to URL + /v1/messages
	// and takes https://api.anthropic.com when URL is empty.
	URL    string
	Model  string
	APIKey string
	// Timeout bounds one call; a photo and a small model take a few seconds,
	// a laptop CPU a minute.
	Timeout time.Duration
}

// Seen is one item the model judged in the picture.
type Seen struct {
	Name       string  `json:"name"`
	State      string  `json:"state"`
	Confidence float64 `json:"confidence"`
}

// Client speaks to the model.
type Client struct {
	cfg  Config
	http *http.Client
}

// NewLooker builds the client for cfg.Provider: the OpenAI-compatible one
// unless it says "anthropic". Nothing dials until Look is called.
func NewLooker(cfg Config) Looker {
	if cfg.Provider == "anthropic" {
		return NewAnthropic(cfg)
	}
	return NewClient(cfg)
}

// NewClient builds the OpenAI-compatible client; nothing dials until Look is
// called.
func NewClient(cfg Config) *Client {
	cfg.Timeout = timeout(cfg.Timeout)
	return &Client{cfg: cfg, http: newHTTP(cfg.Timeout)}
}

func timeout(d time.Duration) time.Duration {
	if d <= 0 {
		return 60 * time.Second
	}
	return d
}

// newHTTP is the one http.Client both providers use, over DialContext.
func newHTTP(d time.Duration) *http.Client {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return DialContext(ctx, network, addr)
		},
		ForceAttemptHTTP2: true,
	}
	return &http.Client{Transport: transport, Timeout: d}
}

// systemPrompt and userPrompt are the same words for both providers.
const systemPrompt = "You look at one photo of a spot in a family's home and say how much of each listed item is there. You answer with JSON and nothing else."

func userPrompt(spot, home string, names []string) string {
	return fmt.Sprintf("This is a photo of the %q at the home %q. Judge these household items, and only these: %s. "+
		"For each one you can see or whose place you can see, give its state: \"have\" when there is plenty, \"low\" when little is left, \"out\" when its place is empty. "+
		"Leave out what the picture does not show. Answer with JSON only, in this shape: {\"items\":[{\"name\":\"melk\",\"state\":\"low\",\"confidence\":0.8}]}. "+
		"Use the names exactly as given; confidence is 0 to 1.", spot, home, strings.Join(names, ", "))
}

// Look sends the picture with the names of the spot's staples and returns
// what the model saw: a state per item it could judge, with its confidence.
func (c *Client) Look(ctx context.Context, jpeg []byte, spot, home string, names []string) ([]Seen, error) {
	body := map[string]any{
		"model":       c.cfg.Model,
		"temperature": 0,
		"messages": []any{
			map[string]any{"role": "system", "content": systemPrompt},
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": userPrompt(spot, home, names)},
				map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(jpeg)}},
			}},
		},
		"response_format": map[string]any{"type": "json_object"},
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.cfg.URL, "/")+"/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.cfg.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.cfg.APIKey)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = res.Body.Close() }()
	out, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if res.StatusCode/100 != 2 {
		return nil, fmt.Errorf("the model answered %d: %s", res.StatusCode, firstLine(out))
	}
	return parseAnswer(out)
}

// parseAnswer reads the chat completion and the JSON the model put in its
// message, tolerating prose or a code fence around it.
func parseAnswer(raw []byte) ([]Seen, error) {
	var env struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("the model's answer is not a chat completion: %w", err)
	}
	if len(env.Choices) == 0 {
		return nil, errors.New("the model answered with no choice")
	}
	return parseItems(env.Choices[0].Message.Content)
}

// parseItems reads the JSON the model put in its text, tolerating prose or a
// code fence around it, and keeps the judgements with a known state.
func parseItems(content string) ([]Seen, error) {
	start, end := strings.Index(content, "{"), strings.LastIndex(content, "}")
	if start < 0 || end <= start {
		return nil, fmt.Errorf("no JSON in the model's answer: %s", firstLine([]byte(content)))
	}
	var answer struct {
		Items []Seen `json:"items"`
	}
	if err := json.Unmarshal([]byte(content[start:end+1]), &answer); err != nil {
		return nil, fmt.Errorf("the model's JSON does not parse: %w", err)
	}
	var out []Seen
	for _, s := range answer.Items {
		s.State = strings.ToLower(strings.TrimSpace(s.State))
		if s.State == "have" || s.State == "low" || s.State == "out" {
			out = append(out, s)
		}
	}
	return out, nil
}

func firstLine(b []byte) string {
	s := strings.TrimSpace(string(b))
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}
