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
