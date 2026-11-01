// Package version holds the build metadata injected at link time and the
// ASCII lockup `doma serve` prints on start.
package version

import (
	"fmt"
	"io"
	"runtime"
)

// Set with -ldflags "-X github.com/w4jnl/doma/internal/version.Version=…".
var (
	Version = "dev"
	Commit  = "none"
	Date    = "unknown"
)

// Tagline is the product line under the wordmark.
const Tagline = "what to buy, what is there, what to bring"

// String returns the one-line version used in logs and User-Agent headers.
func String() string {
	return fmt.Sprintf("doma %s (%s, %s, %s)", Version, Commit, Date, runtime.Version())
}

// Lockup writes the ASCII lockup from the brand guide.
func Lockup(w io.Writer) error {
	_, err := fmt.Fprintf(w, "  ╭─────────╮\n  │    ⌂    │   doma %s\n  │         │   %s\n  ╰─────────╯   w4j.nl\n", Version, Tagline)
	return err
}
