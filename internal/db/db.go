// Package db opens the SQLite database, applies migrations and hosts the
// sqlc-generated queries. One writer connection serialises writes; a second
// read-only pool serves reads.
package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"modernc.org/sqlite"
	_ "modernc.org/sqlite" // database/sql driver
)

// DB holds the writer and reader pools.
type DB struct {
	// Writer has exactly one connection and starts transactions as
	// BEGIN IMMEDIATE so a write transaction never has to upgrade a lock.
	Writer *sql.DB
	// Reader is a read-only pool for queries outside a write transaction.
	Reader *sql.DB
	Path   string
	// OnWrite, when set, is told how long each write transaction took.
	OnWrite func(time.Duration)
	// Slow, when set with SlowLog, logs statements slower than it.
	Slow    time.Duration
	SlowLog *slog.Logger
}

// wrap applies the slow-statement logger when configured.
func (d *DB) wrap(x DBTX) DBTX {
	if d.Slow > 0 && d.SlowLog != nil {
		return Timed(x, d.Slow, d.SlowLog)
	}
	return x
}

// Open opens (creating if needed) the database at path with WAL,
// synchronous=NORMAL, busy_timeout=5000 and foreign_keys=ON.
func Open(ctx context.Context, path string) (*DB, error) {
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o750); err != nil {
			return nil, fmt.Errorf("create db directory: %w", err)
		}
	}
	pragmas := "_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)"
	base := "file:" + url.PathEscape(path)

	writer, err := sql.Open("sqlite", base+"?"+pragmas+"&_txlock=immediate")
	if err != nil {
		return nil, fmt.Errorf("open writer: %w", err)
	}
	writer.SetMaxOpenConns(1)
	writer.SetMaxIdleConns(1)
	writer.SetConnMaxLifetime(0)
	if err := writer.PingContext(ctx); err != nil {
		_ = writer.Close()
		return nil, fmt.Errorf("open writer: %w", err)
	}

	reader, err := sql.Open("sqlite", base+"?"+pragmas+"&_pragma=query_only(1)")
	if err != nil {
		_ = writer.Close()
		return nil, fmt.Errorf("open reader: %w", err)
	}
	reader.SetMaxOpenConns(8)
	if err := reader.PingContext(ctx); err != nil {
		_ = writer.Close()
		_ = reader.Close()
		return nil, fmt.Errorf("open reader: %w", err)
	}
	return &DB{Writer: writer, Reader: reader, Path: path}, nil
}

// Close closes both pools.
func (d *DB) Close() error {
	return errors.Join(d.Reader.Close(), d.Writer.Close())
}

// Read returns queries bound to the reader pool.
func (d *DB) Read() *Queries { return New(d.wrap(d.Reader)) }

// Write returns queries bound to the writer, outside a transaction.
func (d *DB) Write() *Queries { return New(d.wrap(d.Writer)) }

// Tx runs fn inside a write transaction and commits when fn returns nil.
func (d *DB) Tx(ctx context.Context, fn func(q *Queries) error) error {
	start := time.Now()
	tx, err := d.Writer.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // rollback after commit is a no-op
	if err := fn(New(d.wrap(tx))); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	if d.OnWrite != nil {
		d.OnWrite(time.Since(start))
	}
	return nil
}

// ReadTx runs fn inside a read transaction on the reader pool, so several
// queries see one state of the database.
func (d *DB) ReadTx(ctx context.Context, fn func(q *Queries) error) error {
	tx, err := d.Reader.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return fmt.Errorf("begin read: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // a read transaction has nothing to commit
	return fn(New(d.wrap(tx)))
}

// IsUniqueViolation reports whether err is a UNIQUE or PRIMARY KEY conflict.
func IsUniqueViolation(err error) bool {
	var se *sqlite.Error
	if errors.As(err, &se) {
		// SQLITE_CONSTRAINT_UNIQUE = 2067, SQLITE_CONSTRAINT_PRIMARYKEY = 1555
		return se.Code() == 2067 || se.Code() == 1555
	}
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

// IsNotFound reports whether err is sql.ErrNoRows.
func IsNotFound(err error) bool { return errors.Is(err, sql.ErrNoRows) }
