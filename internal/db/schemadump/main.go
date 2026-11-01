// Command schemadump migrates a temporary database and writes db/schema.sql,
// sqlc's schema input. It is a development tool run by `make migrate`, not
// part of doma.
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/w4jnl/doma/internal/db"
)

func main() {
	out := "db/schema.sql"
	if len(os.Args) > 1 {
		out = os.Args[1]
	}
	if err := run(out); err != nil {
		fmt.Fprintln(os.Stderr, "schemadump:", err)
		os.Exit(1)
	}
}

func run(out string) error {
	dir, err := os.MkdirTemp("", "doma-schema")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	ctx := context.Background()
	d, err := db.Open(ctx, filepath.Join(dir, "doma.db"))
	if err != nil {
		return err
	}
	defer func() { _ = d.Close() }()
	if _, err := db.Migrate(ctx, d.Writer, slog.New(slog.NewTextHandler(io.Discard, nil))); err != nil {
		return err
	}
	schema, err := db.Dump(ctx, d.Reader)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o750); err != nil { //nolint:gosec // G703: the output path is this tool's own argument
		return err
	}
	return os.WriteFile(out, schema, 0o600) //nolint:gosec // G703: as above
}
