package domain

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

// HLC is a hybrid logical clock stamp: wall_ms:counter:device. Stamps are
// compared by wall time, then counter, then device id; the string form is
// zero-padded so SQLite's ORDER BY hlc and HLC.Less agree.
type HLC struct {
	Wall    int64
	Counter int
	Device  string
}

const (
	hlcWallDigits    = 13
	hlcCounterDigits = 4
	hlcMaxCounter    = 9999
)

// ParseHLC parses the string form. The device id must be non-empty and
// free of colons.
func ParseHLC(s string) (HLC, error) {
	parts := strings.SplitN(s, ":", 3)
	if len(parts) != 3 || parts[2] == "" || strings.Contains(parts[2], ":") {
		return HLC{}, fmt.Errorf("invalid hlc %q", s)
	}
	wall, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || wall < 0 {
		return HLC{}, fmt.Errorf("invalid hlc %q: wall", s)
	}
	counter, err := strconv.Atoi(parts[1])
	if err != nil || counter < 0 || counter > hlcMaxCounter {
		return HLC{}, fmt.Errorf("invalid hlc %q: counter", s)
	}
	return HLC{Wall: wall, Counter: counter, Device: parts[2]}, nil
}

// MustHLC parses s or panics. For fixtures and tests.
func MustHLC(s string) HLC {
	h, err := ParseHLC(s)
	if err != nil {
		panic(err)
	}
	return h
}

// String renders the zero-padded form.
func (h HLC) String() string {
	return fmt.Sprintf("%0*d:%0*d:%s", hlcWallDigits, h.Wall, hlcCounterDigits, h.Counter, h.Device)
}

// IsZero reports whether h is the zero stamp.
func (h HLC) IsZero() bool { return h.Wall == 0 && h.Counter == 0 && h.Device == "" }

// Compare returns -1, 0 or 1.
func (h HLC) Compare(o HLC) int {
	switch {
	case h.Wall != o.Wall:
		if h.Wall < o.Wall {
			return -1
		}
		return 1
	case h.Counter != o.Counter:
		if h.Counter < o.Counter {
			return -1
		}
		return 1
	}
	return strings.Compare(h.Device, o.Device)
}

// Less reports whether h is before o.
func (h HLC) Less(o HLC) bool { return h.Compare(o) < 0 }

// Time is the wall part as a UTC time.
func (h HLC) Time() time.Time { return FromMillis(h.Wall) }

// MarshalText implements encoding.TextMarshaler.
func (h HLC) MarshalText() ([]byte, error) { return []byte(h.String()), nil }

// UnmarshalText implements encoding.TextUnmarshaler.
func (h *HLC) UnmarshalText(b []byte) error {
	p, err := ParseHLC(string(b))
	if err != nil {
		return err
	}
	*h = p
	return nil
}

// Clock mints stamps for one device: never behind the wall clock, never
// behind a stamp it has observed, strictly increasing.
type Clock struct {
	mu     sync.Mutex
	device string
	now    func() time.Time
	last   HLC
}

// NewClock returns a clock for device. now defaults to time.Now.
func NewClock(device string, now func() time.Time) (*Clock, error) {
	if device == "" || strings.Contains(device, ":") {
		return nil, errors.New("hlc device id must be non-empty and free of colons")
	}
	if now == nil {
		now = time.Now
	}
	return &Clock{device: device, now: now}, nil
}

// Next returns a stamp after every stamp this clock has minted or observed.
func (c *Clock) Next() HLC {
	c.mu.Lock()
	defer c.mu.Unlock()
	wall := Millis(c.now())
	next := HLC{Wall: wall, Device: c.device}
	if wall <= c.last.Wall {
		next.Wall = c.last.Wall
		next.Counter = c.last.Counter + 1
		if next.Counter > hlcMaxCounter {
			next.Wall++
			next.Counter = 0
		}
	}
	c.last = next
	return next
}

// Observe moves the clock past a stamp received from elsewhere.
func (c *Clock) Observe(h HLC) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.last.Less(h) {
		c.last = HLC{Wall: h.Wall, Counter: h.Counter, Device: c.device}
	}
}
