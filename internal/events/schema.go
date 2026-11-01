// Package events validates events against docs/event-schema.json before
// the service appends them. The embedded copy is kept equal to the file
// under docs by `make generate` and a test.
package events

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

//go:embed event-schema.json
var schemaJSON []byte

// Raw is the schema file, for the test that checks the docs copy.
func Raw() []byte { return bytes.Clone(schemaJSON) }

// ErrInvalid is what Validate wraps; handlers answer 422 to it.
var ErrInvalid = errors.New("invalid event")

// Validator checks envelopes and payloads.
type Validator struct {
	envelope *jsonschema.Schema
	kinds    map[string]*jsonschema.Schema
}

var (
	once    sync.Once
	shared  *Validator
	initErr error
)

// Default returns the validator for the embedded schema.
func Default() (*Validator, error) {
	once.Do(func() { shared, initErr = New(schemaJSON) })
	return shared, initErr
}

// New compiles a schema file of doma's shape: $defs, an envelope and a
// payload schema per kind.
func New(raw []byte) (*Validator, error) {
	var file struct {
		Defs     json.RawMessage            `json:"$defs"`
		Envelope json.RawMessage            `json:"envelope"`
		Kinds    map[string]json.RawMessage `json:"kinds"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, fmt.Errorf("event schema: %w", err)
	}
	compile := func(name string, body json.RawMessage) (*jsonschema.Schema, error) {
		// each schema gets the shared $defs so its $refs resolve
		var doc map[string]any
		if err := json.Unmarshal(body, &doc); err != nil {
			return nil, err
		}
		var defs any
		if err := json.Unmarshal(file.Defs, &defs); err != nil {
			return nil, err
		}
		doc["$defs"] = defs
		c := jsonschema.NewCompiler()
		url := "doma://events/" + name
		if err := c.AddResource(url, doc); err != nil {
			return nil, err
		}
		return c.Compile(url)
	}
	env, err := compile("envelope", file.Envelope)
	if err != nil {
		return nil, fmt.Errorf("event schema: envelope: %w", err)
	}
	v := &Validator{envelope: env, kinds: make(map[string]*jsonschema.Schema, len(file.Kinds))}
	for kind, body := range file.Kinds {
		s, err := compile(kind, body)
		if err != nil {
			return nil, fmt.Errorf("event schema: %s: %w", kind, err)
		}
		v.kinds[kind] = s
	}
	return v, nil
}

// Known reports whether the fold has a rule for kind.
func (v *Validator) Known(kind string) bool {
	_, ok := v.kinds[kind]
	return ok
}

// Validate checks one event as the client sent it. An unknown kind passes
// with its envelope checked, so an old server stores a new app's events.
func (v *Validator) Validate(raw []byte) error {
	var doc any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return fmt.Errorf("%w: not JSON: %w", ErrInvalid, err)
	}
	if err := v.envelope.Validate(doc); err != nil {
		return fmt.Errorf("%w: %s", ErrInvalid, short(err))
	}
	obj := doc.(map[string]any)
	kind, _ := obj["kind"].(string)
	s, ok := v.kinds[kind]
	if !ok {
		return nil
	}
	if err := s.Validate(obj["payload"]); err != nil {
		return fmt.Errorf("%w: %s payload: %s", ErrInvalid, kind, short(err))
	}
	return nil
}

// ValidatePayload checks a payload for a known kind, for callers that
// already hold the envelope apart.
func (v *Validator) ValidatePayload(kind string, payload json.RawMessage) error {
	s, ok := v.kinds[kind]
	if !ok {
		return nil
	}
	var doc any
	if err := json.Unmarshal(payload, &doc); err != nil {
		return fmt.Errorf("%w: payload not JSON: %w", ErrInvalid, err)
	}
	if err := s.Validate(doc); err != nil {
		return fmt.Errorf("%w: %s payload: %s", ErrInvalid, kind, short(err))
	}
	return nil
}

// short flattens the library's multi-line message, which names the
// location and the rule that failed, into one line.
func short(err error) string {
	msg := strings.Join(strings.Fields(err.Error()), " ")
	msg = strings.TrimPrefix(msg, "jsonschema validation failed with 'doma://events/")
	if i := strings.Index(msg, "' - "); i >= 0 {
		msg = msg[i+4:]
	}
	if len(msg) > 300 {
		msg = msg[:300]
	}
	return msg
}
