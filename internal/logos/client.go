// Package logos fetches a shop's logo for a card from logo.dev, behind
// logos.enabled: one request to the Brand API's logo endpoint with the
// secret key, one download of the temporary URL it answers with, the
// picture re-encoded as a small PNG the server keeps and serves itself.
// logo.dev is sent the shop's website or name, never a card's number or a
// person's name. Off, nothing in the process dials it.
package logos

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/png"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"

	// the formats a logo download may come in
	_ "image/gif"
	_ "image/jpeg"

	"github.com/w4jnl/doma/internal/photo"
)

const (
	// MaxEdge is the long side of the PNG the server keeps.
	MaxEdge = 256
	// maxDownload bounds one logo download.
	maxDownload = 4 << 20
	// DefaultURL is logo.dev's API.
	DefaultURL = "https://api.logo.dev"
)

// Config names the API and the key.
type Config struct {
	// URL is the API's base; empty means DefaultURL.
	URL     string
	APIKey  string
	Timeout time.Duration
}

// Logo is a fetched logo: the PNG the server keeps and logo.dev's tag of
// the source picture.
type Logo struct {
	PNG  []byte
	ETag string
}

// ErrNoLogo is a shop logo.dev does not know, or knows without a logo.
var ErrNoLogo = errors.New("logo.dev has no logo for it")

// PendingError is logo.dev indexing a brand it meets for the first time:
// ask again after After.
type PendingError struct{ After time.Duration }

func (e *PendingError) Error() string {
	return fmt.Sprintf("logo.dev is still indexing the brand, retry in %s", e.After)
}

// Client speaks to logo.dev.
type Client struct {
	cfg  Config
	http *http.Client
}

// NewClient builds the client; the one place in doma that dials logo.dev.
func NewClient(cfg Config) *Client {
	if cfg.URL == "" {
		cfg.URL = DefaultURL
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 20 * time.Second
	}
	return &Client{cfg: cfg, http: &http.Client{Timeout: cfg.Timeout}}
}

// Fetch asks for the logo of the shop at domain, or by name when the
// domain is unknown, and returns it as a PNG of at most MaxEdge.
func (c *Client) Fetch(ctx context.Context, domain, name string) (*Logo, error) {
	q := url.Values{}
	switch {
	case domain != "":
		q.Set("domain", domain)
	case name != "":
		q.Set("name", name)
	default:
		return nil, ErrNoLogo
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.cfg.URL+"/v2/brands/logo?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.cfg.APIKey)
	req.Header.Set("Accept", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusAccepted:
		after := 30 * time.Second
		if n, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && n > 0 {
			after = time.Duration(n) * time.Second
		}
		return nil, &PendingError{After: after}
	case http.StatusNotFound:
		return nil, ErrNoLogo
	case http.StatusUnauthorized:
		return nil, errors.New("logo.dev refused the key")
	case http.StatusPaymentRequired:
		return nil, errors.New("logo.dev is out of credits for this month")
	default:
		return nil, fmt.Errorf("logo.dev answered %d", resp.StatusCode)
	}
	var out struct {
		Data struct {
			URL  string `json:"url"`
			ETag string `json:"etag"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &out); err != nil || out.Data.URL == "" {
		return nil, ErrNoLogo
	}
	pic, err := c.download(ctx, out.Data.URL)
	if err != nil {
		return nil, err
	}
	return &Logo{PNG: pic, ETag: out.Data.ETag}, nil
}

// download takes the temporary URL as a PNG at most MaxEdge wide and
// re-encodes it from the pixels, so nothing but a picture survives.
func (c *Client) download(ctx context.Context, raw string) ([]byte, error) {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return nil, errors.New("logo.dev gave no address to download")
	}
	q := u.Query()
	q.Set("size", strconv.Itoa(MaxEdge))
	q.Set("format", "png")
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the logo download answered %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxDownload+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxDownload {
		return nil, errors.New("the logo is larger than this server keeps")
	}
	return Encode(data)
}

// Encode decodes a picture and re-encodes it as a PNG of at most MaxEdge
// on its long side.
func Encode(data []byte) ([]byte, error) {
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("the logo is not a picture this server reads: %w", err)
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, photo.Fit(img, MaxEdge)); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
