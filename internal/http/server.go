// Package http assembles the HTTP surface: the health endpoints, the REST
// API and the invite accept, and the web pages, on one chain of middleware.
// The sync endpoint joins in a later step.
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
	"github.com/w4jnl/doma/internal/http/api"
	"github.com/w4jnl/doma/internal/http/middleware"
	"github.com/w4jnl/doma/internal/http/web"
	"github.com/w4jnl/doma/internal/logging"
	"github.com/w4jnl/doma/internal/service"
	"github.com/w4jnl/doma/internal/version"
)

// Deps is everything the handlers need.
type Deps struct {
	Cfg *config.Config
	Log *slog.Logger
	// Svc, when set, mounts the API and the pages; the health endpoint
	// alone needs nothing.
	Svc *service.Service
}

// Handler is the whole surface behind one chain: request id, client IP,
// request log, panic recovery and the security headers.
func Handler(d Deps) (http.Handler, error) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(w, "ok %s\n", version.Version)
	})
	if d.Svc != nil {
		mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
			if err := Ready(r.Context(), d.Svc); err != nil {
				d.Log.Warn("not ready", "err", err)
				http.Error(w, "not ready: "+err.Error(), http.StatusServiceUnavailable)
				return
			}
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = fmt.Fprintln(w, "ready")
		})
		api.New(d.Svc, logging.Sub(d.Log, "api")).Mount(mux)
		pages, err := web.New(d.Svc, logging.Sub(d.Log, "web"), isHTTPS(d.Cfg.Server.BaseURL))
		if err != nil {
			return nil, fmt.Errorf("web templates: %w", err)
		}
		pages.InviteDays = d.Cfg.Invites.DefaultDays
		pages.Mount(mux)
	}
	return middleware.Chain(mux,
		middleware.RequestID,
		middleware.RealIP(d.Cfg.Server.TrustedProxies),
		middleware.Logger(d.Log),
		middleware.Recover(d.Log),
		middleware.SecurityHeaders,
	), nil
}

func isHTTPS(baseURL string) bool { return len(baseURL) >= 8 && baseURL[:8] == "https://" }

// Ready reports whether the writer can take a lock within two seconds.
// The snapshot job's age joins the check with the sync step.
func Ready(ctx context.Context, svc *service.Service) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	conn, err := svc.DB().Writer.Conn(ctx)
	if err != nil {
		return fmt.Errorf("db: %w", err)
	}
	defer func() { _ = conn.Close() }()
	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return fmt.Errorf("db not writable: %w", err)
	}
	if _, err := conn.ExecContext(ctx, "ROLLBACK"); err != nil {
		return fmt.Errorf("db: %w", err)
	}
	return nil
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
