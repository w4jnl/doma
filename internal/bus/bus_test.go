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

// A watch hears its own household and no other, folds a burst into one, and
// stops hearing when it is given back.
func TestWatchHearsItsHousehold(t *testing.T) {
	b := New()
	mine, done := b.Watch("A")
	other, doneOther := b.Watch("B")
	defer doneOther()
	b.Publish(HouseholdChanged{HouseholdID: "A", Seq: 1})
	b.Publish(HouseholdChanged{HouseholdID: "A", Seq: 2})
	select {
	case <-mine:
	default:
		t.Fatal("the watch heard nothing")
	}
	select {
	case <-mine:
		t.Error("a burst was not folded into one")
	default:
	}
	select {
	case <-other:
		t.Error("another household's watch heard it")
	default:
	}
	done()
	b.Publish(HouseholdChanged{HouseholdID: "A", Seq: 3})
	select {
	case <-mine:
		t.Error("a watch given back still hears")
	default:
	}
}
