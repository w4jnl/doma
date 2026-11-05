// Package client is the Go client of a doma server: it accepts invites and
// signs sync and REST requests with a device key. The tests and the e2e
// smoke use it; the apps do the same in Swift.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/auth"
)

// Client talks to one server as one device.
type Client struct {
	BaseURL      string
	HTTP         *http.Client
	Signer       auth.Signer
	CredentialID string
	PersonID     string
	Now          func() time.Time
}

// New returns a client with a fresh Ed25519 key and no credential yet.
func New(baseURL string, httpClient *http.Client) (*Client, error) {
	signer, err := auth.NewEd25519Signer()
	if err != nil {
		return nil, err
	}
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}
	return &Client{BaseURL: strings.TrimRight(baseURL, "/"), HTTP: httpClient, Signer: signer, Now: time.Now}, nil
}

// Problem is the server's error document.
type Problem struct {
	Status int    `json:"status"`
	Type   string `json:"type"`
	Title  string `json:"title"`
	Detail string `json:"detail"`
	Field  string `json:"field"`
}

func (p *Problem) Error() string {
	if p.Field != "" {
		return fmt.Sprintf("%d %s: %s: %s", p.Status, p.Title, p.Field, p.Detail)
	}
	return fmt.Sprintf("%d %s: %s", p.Status, p.Title, p.Detail)
}

// Accepted is the answer to an invite.
type Accepted struct {
	Server       string `json:"server"`
	PersonID     string `json:"person_id"`
	CredentialID string `json:"credential_id"`
	Household    struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"household"`
	Role string `json:"role"`
}

// Accept redeems an invite token with this client's key and remembers the
// credential.
func (c *Client) Accept(ctx context.Context, token, displayName, label string) (*Accepted, error) {
	var out Accepted
	body := map[string]string{"public_key": c.Signer.Public(), "platform": "go", "label": label, "display_name": displayName}
	if err := c.do(ctx, http.MethodPost, "/i/"+token, body, &out, false); err != nil {
		return nil, err
	}
	c.CredentialID, c.PersonID = out.CredentialID, out.PersonID
	return &out, nil
}

// Sync sends the outbox and cursors and returns the server's answer.
func (c *Client) Sync(ctx context.Context, req any, out any) error {
	return c.do(ctx, http.MethodPost, "/sync/v1", req, out, true)
}

// Get performs a signed GET of a JSON resource.
func (c *Client) Get(ctx context.Context, path string, out any) error {
	return c.do(ctx, http.MethodGet, path, nil, out, true)
}

// Do performs a signed request with a JSON body.
func (c *Client) Do(ctx context.Context, method, path string, body, out any) error {
	return c.do(ctx, method, path, body, out, true)
}

// Upload performs a signed POST of raw bytes, as a photo upload, and
// decodes the JSON answer into out when out is not nil.
func (c *Client) Upload(ctx context.Context, path string, body []byte, contentType string, out any) error {
	if c.CredentialID == "" {
		return errors.New("client has no credential: accept an invite first")
	}
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	r.Header.Set("Content-Type", contentType)
	if err := auth.SignRequest(r, c.CredentialID, c.Signer, body, c.Now()); err != nil {
		return err
	}
	resp, err := c.HTTP.Do(r)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode >= 400 {
		return problemOf(resp, raw)
	}
	if out != nil && len(raw) > 0 {
		return json.Unmarshal(raw, out)
	}
	return nil
}

// Download performs a signed GET and returns the raw body.
func (c *Client) Download(ctx context.Context, path string) ([]byte, string, error) {
	resp, err := c.send(ctx, http.MethodGet, path, nil, true)
	if err != nil {
		return nil, "", err
	}
	defer func() { _ = resp.Body.Close() }()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", err
	}
	if resp.StatusCode >= 400 {
		return nil, "", problemOf(resp, raw)
	}
	return raw, resp.Header.Get("Content-Type"), nil
}

func (c *Client) send(ctx context.Context, method, path string, body any, signed bool) (*http.Response, error) {
	var raw []byte
	if body != nil {
		var err error
		if raw, err = json.Marshal(body); err != nil {
			return nil, err
		}
	}
	r, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	if body != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	if signed {
		if c.CredentialID == "" {
			return nil, errors.New("client has no credential: accept an invite first")
		}
		if err := auth.SignRequest(r, c.CredentialID, c.Signer, raw, c.Now()); err != nil {
			return nil, err
		}
	}
	return c.HTTP.Do(r)
}

func (c *Client) do(ctx context.Context, method, path string, body, out any, signed bool) error {
	resp, err := c.send(ctx, method, path, body, signed)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode >= 400 {
		return problemOf(resp, raw)
	}
	if out != nil && len(raw) > 0 {
		return json.Unmarshal(raw, out)
	}
	return nil
}

func problemOf(resp *http.Response, raw []byte) error {
	p := &Problem{Status: resp.StatusCode, Title: http.StatusText(resp.StatusCode)}
	_ = json.Unmarshal(raw, p)
	p.Status = resp.StatusCode
	return p
}
