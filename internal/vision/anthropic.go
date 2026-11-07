package vision

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// anthropicURL is where the Anthropic client posts when vision.url is empty.
const anthropicURL = "https://api.anthropic.com"

// anthropicVersion is the API version the request names.
const anthropicVersion = "2026-10-21"

// Anthropic speaks the Messages API: the same prompt and picture, a different
// envelope. The picture goes as a base64 image block, the key in x-api-key.
type Anthropic struct {
	cfg  Config
	http *http.Client
}

// NewAnthropic builds the client; nothing dials until Look is called.
func NewAnthropic(cfg Config) *Anthropic {
	cfg.Timeout = timeout(cfg.Timeout)
	if cfg.URL == "" {
		cfg.URL = anthropicURL
	}
	return &Anthropic{cfg: cfg, http: newHTTP(cfg.Timeout)}
}

// Look sends the picture with the names of the spot's staples and returns
// what the model saw.
func (a *Anthropic) Look(ctx context.Context, jpeg []byte, spot, home string, names []string) ([]Seen, error) {
	body := map[string]any{
		"model":      a.cfg.Model,
		"max_tokens": 2048,
		"system":     systemPrompt,
		// a short judgement; the model needs no long think
		"output_config": map[string]any{"effort": "low"},
		"messages": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "image", "source": map[string]any{"type": "base64", "media_type": "image/jpeg", "data": base64.StdEncoding.EncodeToString(jpeg)}},
				map[string]any{"type": "text", "text": userPrompt(spot, home, names)},
			}},
		},
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(a.cfg.URL, "/")+"/v1/messages", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", a.cfg.APIKey)
	req.Header.Set("anthropic-version", anthropicVersion)
	res, err := a.http.Do(req)
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
	return parseMessage(out)
}

// parseMessage reads a Messages API response: the first text block carries
// the answer; thinking blocks before it are skipped, a refusal is an error.
func parseMessage(raw []byte) ([]Seen, error) {
	var env struct {
		StopReason string `json:"stop_reason"`
		Content    []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("the model's answer is not a message: %w", err)
	}
	if env.StopReason == "refusal" {
		return nil, errors.New("the model declined to look at the picture")
	}
	for _, c := range env.Content {
		if c.Type == "text" {
			return parseItems(c.Text)
		}
	}
	return nil, errors.New("the model answered with no text")
}
