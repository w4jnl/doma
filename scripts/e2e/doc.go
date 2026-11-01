// Package e2e is the end-to-end smoke behind the e2e build tag: it builds
// doma, starts it on a free port with a temporary data directory, and
// walks a household from the setup page to a committed trip with the Go
// client. `make e2e` runs it.
package e2e
