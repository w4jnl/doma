package events_test

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/w4jnl/doma/internal/events"
	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/fold/foldtest"
)

func TestEmbeddedCopyMatchesDocs(t *testing.T) {
	docs, err := os.ReadFile("../../docs/event-schema.json")
	if err != nil {
		t.Fatal(err)
	}
	if string(docs) != string(events.Raw()) {
		t.Fatal("internal/events/event-schema.json differs from docs/event-schema.json: run make generate")
	}
}

func TestEveryFoldKindHasASchema(t *testing.T) {
	v, err := events.Default()
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range fold.Kinds {
		if !v.Known(k) {
			t.Errorf("no schema for %s", k)
		}
	}
}

func TestFixtureEventsValidate(t *testing.T) {
	v, err := events.Default()
	if err != nil {
		t.Fatal(err)
	}
	f := foldtest.Load(t)
	for _, c := range f.Cases {
		for _, e := range c.Events {
			raw, _ := json.Marshal(e)
			if err := v.Validate(raw); err != nil {
				t.Errorf("%s: %s %s: %v", c.Name, e.Kind, e.ID, err)
			}
		}
	}
}

func TestRejects(t *testing.T) {
	v, err := events.Default()
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"not json":           `{`,
		"no id":              `{"hlc": "1:0:a", "kind": "entry.added", "payload": {"list_id": "L", "item_id": "I"}}`,
		"bad hlc":            `{"id": "e1", "hlc": "yesterday", "kind": "entry.added", "payload": {"list_id": "L", "item_id": "I"}}`,
		"missing item":       `{"id": "e1", "hlc": "1:0:a", "kind": "entry.added", "payload": {"list_id": "L"}}`,
		"bad flag state":     `{"id": "e1", "hlc": "1:0:a", "kind": "flag.set", "payload": {"home_id": "H", "item_id": "I", "state": "gone"}}`,
		"negative qty":       `{"id": "e1", "hlc": "1:0:a", "kind": "entry.added", "payload": {"list_id": "L", "item_id": "I", "qty": -1}}`,
		"empty name":         `{"id": "e1", "hlc": "1:0:a", "kind": "item.named", "payload": {"item_id": "I", "name": ""}}`,
		"payload not object": `{"id": "e1", "hlc": "1:0:a", "kind": "item.named", "payload": "melk"}`,
		"moved not ids":      `{"id": "e1", "hlc": "1:0:a", "kind": "trip.arrived", "payload": {"trip_id": "T", "from_home_id": "H1", "to_home_id": "H2", "moved": [1]}}`,
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			err := v.Validate([]byte(raw))
			if !errors.Is(err, events.ErrInvalid) {
				t.Fatalf("accepted: %v", err)
			}
		})
	}
	// unknown kinds pass with a sound envelope
	if err := v.Validate([]byte(`{"id": "e1", "hlc": "1:0:a", "kind": "future.thing", "payload": {"x": 1}}`)); err != nil {
		t.Errorf("unknown kind refused: %v", err)
	}
	if err := v.ValidatePayload("entry.added", []byte(`{"list_id": "L", "item_id": "I", "note": "x"}`)); err != nil {
		t.Errorf("ValidatePayload: %v", err)
	}
	if err := v.ValidatePayload("entry.added", []byte(`{"list_id": "L"}`)); err == nil || !strings.Contains(err.Error(), "item_id") {
		t.Errorf("ValidatePayload missing item_id: %v", err)
	}
}
