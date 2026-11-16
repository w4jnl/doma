// Package bus is the in-process event bus: the service publishes
// HouseholdChanged after a sync commits, the push subsystem subscribes.
package bus

import "sync"

// HouseholdChanged says a household's log grew to Seq.
type HouseholdChanged struct {
	HouseholdID string
	Seq         int64
}

// Bus fans HouseholdChanged out to subscribers without blocking the
// publisher: each subscriber has a buffer of one and keeps only the latest
// change, which is all a push needs.
type Bus struct {
	mu   sync.Mutex
	subs []chan HouseholdChanged
	// watchers are the open pages of each household, told that something
	// changed and nothing more.
	watchers map[string]map[chan struct{}]struct{}
}

// New returns an empty bus.
func New() *Bus { return &Bus{} }

// Subscribe returns a channel that receives changes. A slow subscriber
// misses intermediate changes, never the last one.
func (b *Bus) Subscribe() <-chan HouseholdChanged {
	ch := make(chan HouseholdChanged, 1)
	b.mu.Lock()
	b.subs = append(b.subs, ch)
	b.mu.Unlock()
	return ch
}

// Publish delivers c to every subscriber, replacing an unread change.
func (b *Bus) Publish(c HouseholdChanged) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.watchers[c.HouseholdID] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
	for _, ch := range b.subs {
		select {
		case ch <- c:
		default:
			select {
			case <-ch:
			default:
			}
			ch <- c
		}
	}
}

// Watch returns a channel that says when the household changed, and the
// function that ends the watch. Changes while the watcher is busy fold into
// one: the watcher reads the household again, so one is enough.
func (b *Bus) Watch(householdID string) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	b.mu.Lock()
	if b.watchers == nil {
		b.watchers = map[string]map[chan struct{}]struct{}{}
	}
	if b.watchers[householdID] == nil {
		b.watchers[householdID] = map[chan struct{}]struct{}{}
	}
	b.watchers[householdID][ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		delete(b.watchers[householdID], ch)
		if len(b.watchers[householdID]) == 0 {
			delete(b.watchers, householdID)
		}
		b.mu.Unlock()
	}
}
