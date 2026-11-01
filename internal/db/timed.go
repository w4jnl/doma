package db

import (
	"context"
	"database/sql"
	"log/slog"
	"time"
)

// Timed wraps a DBTX so every statement slower than slow is logged at
// debug level: what `doma serve -d` prints.
func Timed(inner DBTX, slow time.Duration, log *slog.Logger) DBTX {
	return &timed{inner: inner, slow: slow, log: log}
}

type timed struct {
	inner DBTX
	slow  time.Duration
	log   *slog.Logger
}

func (t *timed) observe(ctx context.Context, start time.Time, query string) {
	if d := time.Since(start); d >= t.slow {
		if len(query) > 120 {
			query = query[:120] + "…"
		}
		t.log.DebugContext(ctx, "slow sql", "ms", d.Milliseconds(), "sql", query)
	}
}

func (t *timed) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	defer t.observe(ctx, time.Now(), query)
	return t.inner.ExecContext(ctx, query, args...)
}

func (t *timed) PrepareContext(ctx context.Context, query string) (*sql.Stmt, error) {
	return t.inner.PrepareContext(ctx, query)
}

func (t *timed) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	defer t.observe(ctx, time.Now(), query)
	return t.inner.QueryContext(ctx, query, args...) //nolint:sqlclosecheck // the caller closes the rows, as with the inner DBTX
}

func (t *timed) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	defer t.observe(ctx, time.Now(), query)
	return t.inner.QueryRowContext(ctx, query, args...)
}
