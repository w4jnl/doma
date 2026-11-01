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
	"syscall"

	"github.com/w4jnl/doma/internal/config"
	dhttp "github.com/w4jnl/doma/internal/http"
	"github.com/w4jnl/doma/internal/logging"
	"github.com/w4jnl/doma/internal/version"
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
	return runServe(ctx, cfg, log)
}

// runServe wires the process and blocks until ctx is cancelled.
func runServe(ctx context.Context, cfg *config.Config, log *slog.Logger) error {
	log.Info("starting", "version", version.String(), "db", cfg.DB.Path, "listen", cfg.Server.Listen, "base_url", cfg.BaseURL())
	for _, w := range cfg.Warnings() {
		log.Warn("config: " + w)
	}
	deps := dhttp.Deps{Cfg: cfg, Log: log}
	if err := dhttp.Run(ctx, log, cfg.Server.Listen, dhttp.Handler(deps)); err != nil {
		return err
	}
	log.Info("stopped")
	return nil
}
