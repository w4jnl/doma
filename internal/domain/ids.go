// Package domain holds the types shared by every layer: ids, times, the
// hybrid logical clock, scopes and roles, and the sentinel errors. It
// depends on nothing inside the repository.
package domain

import (
	"time"

	"github.com/oklog/ulid/v2"
)

// NewID returns a new ULID string. ULIDs sort by creation time.
func NewID() string { return ulid.Make().String() }

// IsID reports whether s is a well-formed ULID.
func IsID(s string) bool {
	_, err := ulid.ParseStrict(s)
	return err == nil
}

// Millis converts a time to the Unix millisecond form stored in SQLite.
func Millis(t time.Time) int64 { return t.UnixMilli() }

// FromMillis converts a stored Unix millisecond value to a UTC time.
func FromMillis(ms int64) time.Time { return time.UnixMilli(ms).UTC() }
