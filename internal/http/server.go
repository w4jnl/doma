// Package http assembles the HTTP surface: the health endpoints now, and
// the sync endpoint, the REST API and the web pages as later steps add
// them, each on one chain of middleware.
package http

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/w4jnl/doma/internal/config"
	"github.com/w4jnl/doma/internal/http/middleware"
	"github.com/w4jnl/doma/internal/version"
)

// Deps is everything the handlers need.
type Deps struct {
	Cfg *config.Config
	Log *slog.Logger
}

// Handler is the whole surface behind one chain: request id, client IP,
// request log and panic recovery.
func Handler(d Deps) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(w, "ok %s\n", version.Version)
	})
	return middleware.Chain(mux,
		middleware.RequestID,
		middleware.RealIP(d.Cfg.Server.TrustedProxies),
		middleware.Logger(d.Log),
		middleware.Recover(d.Log),
	)
}

// Run serves h on listen until ctx is done, then drains for up to ten
// seconds.
func Run(ctx context.Context, log *slog.Logger, listen string, h http.Handler) error {
	srv := &http.Server{
		Addr: listen, Handler: h,
		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 60 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 120 * time.Second,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	ln, err := (&net.ListenConfig{}).Listen(ctx, "tcp", listen)
	if err != nil {
		return fmt.Errorf("listen %s: %w", listen, err)
	}
	log.Info("listening", "addr", ln.Addr().String())
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("shutdown: %w", err)
		}
		return nil
	}
}
