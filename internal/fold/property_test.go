package fold_test

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"strconv"
	"testing"

	"github.com/w4jnl/doma/internal/fold"
	"github.com/w4jnl/doma/internal/fold/foldtest"
)

// TestRandomOrdersConverge generates a plausible household timeline on two
// devices and folds it in many arrival orders; every order must give the
// same tables. FOLD_N sets the timeline's length.
func TestRandomOrdersConverge(t *testing.T) {
	seeds := 60
	if testing.Short() {
		seeds = 10
	}
	n := 40
	if v, err := strconv.Atoi(os.Getenv("FOLD_N")); err == nil {
		n = v
	}
	for seed := range seeds {
		t.Run(fmt.Sprint(seed), func(t *testing.T) {
			rnd := rand.New(rand.NewPCG(uint64(seed), 99))
			events := foldtest.Generate(rnd, n)
			want := foldtest.Canonical(t, fold1(t, events))
			for range 8 {
				perm := rnd.Perm(len(events))
				if got := foldtest.Canonical(t, fold1(t, foldtest.Shuffle(events, perm))); got != want {
					t.Fatalf("seed %d diverged for order %v\n got %s\nwant %s\nevents %s", seed, perm, got, want, dump(events))
				}
			}
		})
	}
}

func dump(events []fold.Event) string {
	raw, _ := json.MarshalIndent(events, "", " ")
	return string(raw)
}
