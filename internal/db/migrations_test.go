package db

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
)

func TestMigrateIsIdempotentAndSchemaIsCurrent(t *testing.T) {
	ctx := context.Background()
	d, err := Open(ctx, filepath.Join(t.TempDir(), "doma.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	done, err := Migrate(ctx, d.Writer, quiet)
	if err != nil {
		t.Fatal(err)
	}
	if len(done) == 0 {
		t.Fatal("no migrations applied")
	}
	again, err := Migrate(ctx, d.Writer, quiet)
	if err != nil || len(again) != 0 {
		t.Fatalf("second run: %v %v", again, err)
	}
	list, err := ListMigrations(ctx, d.Reader)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range list {
		if !m.Applied {
			t.Errorf("%s not applied", m.Version)
		}
	}
	var fk string
	if err := d.Reader.QueryRowContext(ctx, "PRAGMA foreign_keys").Scan(&fk); err != nil || fk != "1" {
		t.Errorf("foreign_keys = %q, %v", fk, err)
	}
	var mode string
	if err := d.Reader.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&mode); err != nil || mode != "wal" {
		t.Errorf("journal_mode = %q, %v", mode, err)
	}
	// db/schema.sql is what sqlc reads; it must match the migrated database
	got, err := Dump(ctx, d.Reader)
	if err != nil {
		t.Fatal(err)
	}
	want, err := os.ReadFile(filepath.Join("..", "..", "db", "schema.sql"))
	if err != nil {
		t.Fatalf("db/schema.sql: %v (run make migrate)", err)
	}
	if string(got) != string(want) {
		t.Error("db/schema.sql is out of date: run make migrate")
	}
}

func TestUnknownVersionRefused(t *testing.T) {
	ctx := context.Background()
	d, err := Open(ctx, filepath.Join(t.TempDir(), "doma.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if _, err := Migrate(ctx, d.Writer, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Writer.ExecContext(ctx, `INSERT INTO schema_migrations (version) VALUES ('99991231000000')`); err != nil {
		t.Fatal(err)
	}
	if _, err := Migrate(ctx, d.Writer, nil); err == nil {
		t.Fatal("a newer database must be refused")
	}
}

func TestUniqueViolation(t *testing.T) {
	ctx := context.Background()
	d, err := Open(ctx, filepath.Join(t.TempDir(), "doma.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if _, err := Migrate(ctx, d.Writer, nil); err != nil {
		t.Fatal(err)
	}
	ins := `INSERT INTO persons (id, display_name, created_at) VALUES ('p1', 'J', 0)`
	if _, err := d.Writer.ExecContext(ctx, ins); err != nil {
		t.Fatal(err)
	}
	_, err = d.Writer.ExecContext(ctx, ins)
	if !IsUniqueViolation(err) {
		t.Errorf("IsUniqueViolation(%v) = false", err)
	}
}
