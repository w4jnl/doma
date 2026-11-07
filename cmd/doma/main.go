// Command doma is the family's household app: one server with an event log
// per household, the sync endpoint for the apps and the guest and admin pages.
// It has one subcommand, serve; everything else happens in the browser.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	_ "time/tzdata" // the scratch image has no zoneinfo; households carry a time zone

	"github.com/w4jnl/doma/internal/bus"
	"github.com/w4jnl/doma/internal/config"
	"github.com/w4jnl/doma/internal/db"
	dhttp "github.com/w4jnl/doma/internal/http"
	"github.com/w4jnl/doma/internal/http/web"
	"github.com/w4jnl/doma/internal/logging"
	"github.com/w4jnl/doma/internal/metrics"
	"github.com/w4jnl/doma/internal/push"
	"github.com/w4jnl/doma/internal/secrets"
	"github.com/w4jnl/doma/internal/service"
	"github.com/w4jnl/doma/internal/version"
	"github.com/w4jnl/doma/internal/vision"
)

const usage = `doma: what to buy, what is there, what to bring

  doma serve [-d] [--config doma.toml] [--print-config]
  doma --version

serve runs the server. -d switches the log to debug level and colour.
--config names the TOML file; every key can also be set as DOMA_SECTION_KEY.
--print-config prints the effective configuration with secrets redacted and exits.
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	switch args[0] {
	case "--version", "-version", "version":
		fmt.Fprintln(stdout, version.String())
		return 0
	case "serve":
		if err := serve(ctx, args[1:], stdout, stderr); err != nil {
			if errors.Is(err, flag.ErrHelp) {
				return 2
			}
			fmt.Fprintln(stderr, "doma:", err)
			return 1
		}
		return 0
	case "-h", "--help", "help":
		fmt.Fprint(stdout, usage)
		return 0
	}
	fmt.Fprintf(stderr, "doma: unknown command %q\n\n%s", args[0], usage)
	return 2
}

func serve(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("doma serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	debug := fs.Bool("d", false, "debug: log level debug and a coloured text log")
	configPath := fs.String("config", os.Getenv("DOMA_CONFIG"), "path of doma.toml (default: none, built-in defaults and DOMA_* variables)")
	printConfig := fs.Bool("print-config", false, "print the effective configuration with secrets redacted and exit")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("serve takes no arguments, got %q", fs.Args())
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	if *printConfig {
		out, err := cfg.Redacted().TOML()
		if err != nil {
			return err
		}
		_, err = stdout.Write(out)
		return err
	}
	log := logging.New(logging.Options{Debug: *debug, Level: cfg.Log.Level, Format: cfg.Log.Format, Out: stderr})
	slog.SetDefault(log)
	if *debug || logging.IsTerminal(stderr) {
		_ = version.Lockup(stderr)
	}
	return runServe(ctx, cfg, log, *debug)
}

// runServe wires the process and blocks until ctx is cancelled.
func runServe(ctx context.Context, cfg *config.Config, log *slog.Logger, debug bool) error {
	log.Info("starting", "version", version.String(), "db", cfg.DB.Path, "listen", cfg.Server.Listen, "base_url", cfg.BaseURL())
	for _, w := range cfg.Warnings() {
		log.Warn("config: " + w)
	}
	d, err := db.Open(ctx, cfg.DB.Path)
	if err != nil {
		return err
	}
	defer func() { _ = d.Close() }()
	if debug {
		d.Slow, d.SlowLog = 50*time.Millisecond, log
	}
	if _, err := db.Migrate(ctx, d.Writer, log); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	svc := service.New(d, service.Config{
		BaseURL: cfg.BaseURL(), InviteDays: cfg.Invites.DefaultDays, GuestDays: cfg.Invites.GuestDefaultDays,
		StalenessDays: cfg.Defaults.StalenessDays, MaxEventsPerSync: cfg.Sync.MaxEventsPerResponse, ReplayLimit: cfg.Sync.ReplayLimit,
		SnapshotsDir: cfg.SnapshotsDir(), EventsDays: cfg.Retention.EventsDays,
		PhotosDir: cfg.PhotosDir(), MaxUploadBytes: int64(cfg.Photos.MaxBytesPerUpload), PhotosPerSpot: cfg.Retention.PhotosPerSpot,
	}, log)
	changes := bus.New()
	svc.SetBus(changes)
	m := metrics.New(version.Version)
	svc.SetMetrics(m)
	svc.SetTrace(debug)
	keyring, err := secrets.Load(cfg.SecretKeyFile())
	if err != nil {
		return fmt.Errorf("secrets: %w", err)
	}
	sender, err := pushSender(cfg, keyring, log)
	if err != nil {
		return err
	}
	svc.SetKeyring(keyring)
	pusher := push.New(push.ServiceRegistry{Svc: svc}, sender, cfg.BaseURL(), logging.Sub(log, "push"), m)
	// the vision worker exists only when vision.enabled is on; with it off nothing in the
	// process can reach the model
	var looker *vision.Worker
	if cfg.Vision.Enabled {
		client := vision.NewLooker(vision.Config{Provider: cfg.Vision.Provider, URL: cfg.Vision.URL, Model: cfg.Vision.Model, APIKey: cfg.Vision.APIKey, Timeout: time.Duration(cfg.Vision.TimeoutSeconds) * time.Second})
		looker = vision.New(svc, client, logging.Sub(log, "vision"))
		svc.SetVision(looker)
	}
	started := time.Now()
	redacted, _ := cfg.Redacted().TOML()
	facts := &web.ServerFacts{
		BaseURL: cfg.BaseURL(), Version: version.String(), PushEnabled: cfg.Push.Enabled, PushKeyFile: cfg.PushKeyFile(),
		PhotosDir: cfg.PhotosDir(), ConfigTOML: string(redacted), LastPushError: pusher.LastError, SecretKeyFile: cfg.SecretKeyFile(),
		SealKey: func(pemBytes []byte) error {
			sealed, err := keyring.Seal(pemBytes)
			if err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(cfg.PushKeyFile()), 0o750); err != nil { //nolint:gosec // G703: the operator's push.key_file
				return err
			}
			return os.WriteFile(cfg.PushKeyFile(), []byte(sealed), 0o600) //nolint:gosec // G703: as above
		},
	}
	h, err := dhttp.Handler(dhttp.Deps{Cfg: cfg, Log: log, Svc: svc, Metrics: m, Started: started, Facts: facts})
	if err != nil {
		return err
	}
	if ok, err := svc.AdminExists(ctx); err == nil && !ok {
		log.Info("first run: open " + cfg.BaseURL() + "/setup in a browser")
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	errc := make(chan error, 3)
	run := func(name string, fn func(context.Context) error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := fn(ctx); err != nil && !errors.Is(err, context.Canceled) {
				errc <- fmt.Errorf("%s: %w", name, err)
				cancel()
			}
		}()
	}
	run("snapshots", func(ctx context.Context) error { return svc.SnapshotJob(ctx, cfg.Retention.SnapshotHour) })
	run("push", func(ctx context.Context) error { return pusher.Run(ctx, changes.Subscribe()) })
	if looker != nil {
		run("vision", looker.Run)
	}
	run("http", func(ctx context.Context) error { return dhttp.Run(ctx, log, cfg.Server.Listen, h) })
	var firstErr error
	select {
	case <-ctx.Done():
	case firstErr = <-errc:
		cancel()
	}
	wg.Wait()
	if firstErr != nil {
		return firstErr
	}
	log.Info("stopped")
	return nil
}

// pushSender builds the APNs client when push.enabled is on: the key file
// is sealed in place under secrets.key_file after the first start. With
// push off it returns nil and nothing in the process can dial out.
func pushSender(cfg *config.Config, keyring *secrets.Keyring, log *slog.Logger) (push.Sender, error) {
	if !cfg.Push.Enabled {
		log.Info("push off: the server makes no outbound connections")
		return nil, nil //nolint:nilnil // nil is the disabled sender
	}
	path := cfg.PushKeyFile()
	if err := keyring.SealFile(path); err != nil {
		return nil, fmt.Errorf("push.key_file %s: %w (put the APNs .p8 key there or set push.enabled = false)", path, err)
	}
	pemBytes, err := keyring.OpenFile(path)
	if err != nil {
		return nil, fmt.Errorf("push.key_file: %w", err)
	}
	key, err := push.ParseKey(pemBytes)
	if err != nil {
		return nil, err
	}
	log.Info("push on", "topic", cfg.Push.Topic)
	return push.NewAPNs(key, cfg.Push.KeyID, cfg.Push.TeamID, cfg.Push.Topic), nil
}
