package bus

import "testing"

func TestLatestWins(t *testing.T) {
	b := New()
	ch := b.Subscribe()
	b.Publish(HouseholdChanged{HouseholdID: "h", Seq: 1})
	b.Publish(HouseholdChanged{HouseholdID: "h", Seq: 2})
	got := <-ch
	if got.Seq != 2 {
		t.Errorf("got seq %d, want the latest", got.Seq)
	}
	select {
	case extra := <-ch:
		t.Errorf("unexpected second change %v", extra)
	default:
	}
}
