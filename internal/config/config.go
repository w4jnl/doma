// Package config loads doma.toml, overlays DOMA_* environment variables,
// resolves env: references, validates, and redacts secrets for display.
package config

import (
	"bytes"
	"encoding"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// EnvPrefix is the prefix of every environment override: DOMA_SERVER_LISTEN.
const EnvPrefix = "DOMA"

// Config is the whole doma.toml, in the order of the design document.
type Config struct {
	Server    Server    `toml:"server"`
	DB        DB        `toml:"db"`
	Photos    Photos    `toml:"photos"`
	Sync      Sync      `toml:"sync"`
	Push      Push      `toml:"push"`
	Invites   Invites   `toml:"invites"`
	Retention Retention `toml:"retention"`
	Defaults  Defaults  `toml:"defaults"`
	Log       Log       `toml:"log"`
	Metrics   Metrics   `toml:"metrics"`
	Secrets   Secrets   `toml:"secrets"`
	Admin     Admin     `toml:"admin"`
}

type Server struct {
	Listen string `toml:"listen"`
	// BaseURL is the public address: invite and guest links, the APNs
	// payload and signed photo URLs are built from it.
	BaseURL        string   `toml:"base_url"`
	TrustedProxies []string `toml:"trusted_proxies"`
}

type DB struct {
	Path string `toml:"path"`
}

type Photos struct {
	// Dir is the photo store; empty means photos/ next to the database.
	Dir               string   `toml:"dir"`
	MaxBytesPerUpload ByteSize `toml:"max_bytes_per_upload"`
}

type Sync struct {
	MaxEventsPerResponse int `toml:"max_events_per_response"`
	// ReplayLimit is how far behind the newest snapshot a cursor may be
	// before the client is sent the snapshot first.
	ReplayLimit int `toml:"replay_limit"`
}

type Push struct {
	Enabled bool `toml:"enabled"`
	// KeyFile is the APNs .p8 key, encrypted at rest after the first start;
	// empty means apns.p8 next to the database.
	KeyFile string `toml:"key_file"`
	KeyID   string `toml:"key_id"`
	TeamID  string `toml:"team_id"`
	// Topic is the app's bundle id. Which of Apple's gateways a push goes to
	// is the device's to say when it registers its token, not the server's.
	Topic string `toml:"topic"`
}

type Invites struct {
	DefaultDays      int `toml:"default_days"`
	GuestDefaultDays int `toml:"guest_default_days"`
}

type Retention struct {
	EventsDays    int `toml:"events_days"`
	PhotosPerSpot int `toml:"photos_per_spot"`
	// SnapshotHour is the hour of the nightly job, server local time.
	SnapshotHour int `toml:"snapshot_hour"`
}

type Defaults struct {
	// StalenessDays is after how long a flag fades to unknown.
	StalenessDays int `toml:"staleness_days"`
}

type Log struct {
	Level  string `toml:"level"`
	Format string `toml:"format"`
}

type Metrics struct {
	Token string `toml:"token" redact:"true"`
}

// Admin is who signs the admin in: doma's own form, or the proxy in front.
type Admin struct {
	// Auth is "password", doma's own sign-in with the optional TOTP step,
	// or "proxy": the reverse proxy in front (Authelia) signs the admin in
	// and names them in Remote-User; doma's form is then not served.
	Auth string `toml:"auth"`
	// ProxyCIDRs are the peers whose Remote-User counts, the proxy's own
	// addresses; ProxySecret is what the proxy adds in X-Auth-Proxy-Secret
	// on every request; ProxyLogoutURL is where Sign out goes, the proxy's
	// logout page, empty for no button.
	ProxyCIDRs     []string `toml:"proxy_cidrs"`
	ProxySecret    string   `toml:"proxy_secret" redact:"true"`
	ProxyLogoutURL string   `toml:"proxy_logout_url"`
}

type Secrets struct {
	// KeyFile holds the 32-byte key that encrypts the APNs key and the
	// admin TOTP secret; empty means secret.key next to the database.
	KeyFile string `toml:"key_file"`
}

// Default returns the built-in defaults from the design document, with
// development paths: the database in the working directory and the photo
// store and key files next to it.
func Default() *Config {
	return &Config{
		Server:    Server{Listen: ":8080", BaseURL: "http://localhost:8080"},
		DB:        DB{Path: "doma.db"},
		Photos:    Photos{MaxBytesPerUpload: 8 << 20},
		Sync:      Sync{MaxEventsPerResponse: 500, ReplayLimit: 5000},
		Push:      Push{Topic: "nl.w4j.doma"},
		Invites:   Invites{DefaultDays: 7, GuestDefaultDays: 7},
		Retention: Retention{EventsDays: 365, PhotosPerSpot: 5, SnapshotHour: 3},
		Defaults:  Defaults{StalenessDays: 60},
		Log:       Log{Level: "info", Format: "json"},
		Admin:     Admin{Auth: "password"},
	}
}

// Load reads the TOML file at path (optional), applies DOMA_* environment
// overrides, resolves env: references and validates the result.
func Load(path string) (*Config, error) {
	return LoadWith(path, os.LookupEnv)
}

// LoadWith is Load with an injectable environment, for tests.
func LoadWith(path string, lookup func(string) (string, bool)) (*Config, error) {
	cfg := Default()
	if path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read config: %w", err)
		}
		dec := toml.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(cfg); err != nil {
			var sme *toml.StrictMissingError
			if errors.As(err, &sme) {
				return nil, fmt.Errorf("parse config %s: unknown keys:\n%s", path, sme.String())
			}
			return nil, fmt.Errorf("parse config %s: %w", path, err)
		}
	}
	if err := applyEnv(reflect.ValueOf(cfg).Elem(), EnvPrefix, lookup); err != nil {
		return nil, err
	}
	if err := resolveEnvRefs(reflect.ValueOf(cfg).Elem(), lookup); err != nil {
		return nil, err
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return cfg, nil
}

// dataDir is the directory of the database file, where the other state
// files default to.
func (c *Config) dataDir() string {
	return filepath.Dir(c.DB.Path)
}

// SecretKeyFile returns secrets.key_file, or secret.key next to the database.
func (c *Config) SecretKeyFile() string {
	if c.Secrets.KeyFile != "" {
		return c.Secrets.KeyFile
	}
	return filepath.Join(c.dataDir(), "secret.key")
}

// PhotosDir returns photos.dir, or photos/ next to the database.
func (c *Config) PhotosDir() string {
	if c.Photos.Dir != "" {
		return c.Photos.Dir
	}
	return filepath.Join(c.dataDir(), "photos")
}

// SnapshotsDir is snapshots/ next to the database; it is not a config key.
func (c *Config) SnapshotsDir() string {
	return filepath.Join(c.dataDir(), "snapshots")
}

// PushKeyFile returns push.key_file, or apns.p8 next to the database.
func (c *Config) PushKeyFile() string {
	if c.Push.KeyFile != "" {
		return c.Push.KeyFile
	}
	return filepath.Join(c.dataDir(), "apns.p8")
}

// ProxyAuth reports whether the proxy in front signs the admin in.
func (c *Config) ProxyAuth() bool { return c.Admin.Auth == "proxy" }

// BaseURL returns server.base_url without a trailing slash.
func (c *Config) BaseURL() string {
	return strings.TrimRight(c.Server.BaseURL, "/")
}

// Validate checks values that would otherwise fail later and less clearly.
func (c *Config) Validate() error {
	var errs []error
	fail := func(format string, a ...any) { errs = append(errs, fmt.Errorf(format, a...)) }

	if c.Server.Listen == "" {
		fail("server.listen must not be empty")
	}
	if u, err := url.Parse(c.Server.BaseURL); err != nil || u.Scheme == "" || u.Host == "" {
		fail("server.base_url must be an absolute URL, got %q", c.Server.BaseURL)
	} else {
		if u.Scheme != "http" && u.Scheme != "https" {
			fail("server.base_url must be http or https, got %q", c.Server.BaseURL)
		}
		if strings.Trim(u.Path, "/") != "" || u.RawQuery != "" || u.Fragment != "" {
			fail("server.base_url must be a host without a path, got %q; doma serves at the root", c.Server.BaseURL)
		}
	}
	for _, cidr := range c.Server.TrustedProxies {
		if _, _, err := net.ParseCIDR(cidr); err != nil {
			fail("server.trusted_proxies: %q is not a CIDR", cidr)
		}
	}
	if c.DB.Path == "" {
		fail("db.path must not be empty")
	}
	if c.Photos.MaxBytesPerUpload <= 0 {
		fail("photos.max_bytes_per_upload must be positive")
	}
	if c.Sync.MaxEventsPerResponse <= 0 || c.Sync.MaxEventsPerResponse > 2000 {
		fail("sync.max_events_per_response must be between 1 and 2000, got %d", c.Sync.MaxEventsPerResponse)
	}
	if c.Sync.ReplayLimit <= 0 {
		fail("sync.replay_limit must be positive")
	}
	if c.Push.Enabled {
		if c.Push.KeyID == "" || c.Push.TeamID == "" {
			fail("push.enabled is on but push.key_id or push.team_id is empty")
		}
		if c.Push.Topic == "" {
			fail("push.topic must be the app's bundle id when push is enabled")
		}
	}
	if c.Invites.DefaultDays <= 0 || c.Invites.GuestDefaultDays <= 0 {
		fail("invites.default_days and invites.guest_default_days must be positive")
	}
	if c.Retention.EventsDays <= 0 || c.Retention.PhotosPerSpot <= 0 {
		fail("retention.events_days and retention.photos_per_spot must be positive")
	}
	if c.Retention.SnapshotHour < 0 || c.Retention.SnapshotHour > 23 {
		fail("retention.snapshot_hour must be between 0 and 23, got %d", c.Retention.SnapshotHour)
	}
	if c.Defaults.StalenessDays <= 0 {
		fail("defaults.staleness_days must be positive")
	}
	switch strings.ToLower(c.Log.Level) {
	case "debug", "info", "warn", "warning", "error":
	default:
		fail("log.level must be debug, info, warn or error, got %q", c.Log.Level)
	}
	switch strings.ToLower(c.Log.Format) {
	case "json", "text":
	default:
		fail("log.format must be json or text, got %q", c.Log.Format)
	}
	switch c.Admin.Auth {
	case "password":
	case "proxy":
		if len(c.Admin.ProxyCIDRs) == 0 {
			fail("admin.auth is proxy but admin.proxy_cidrs is empty; name the proxy's addresses")
		}
		for _, cidr := range c.Admin.ProxyCIDRs {
			if _, _, err := net.ParseCIDR(cidr); err != nil {
				fail("admin.proxy_cidrs: %q is not a CIDR", cidr)
			}
		}
		if c.Admin.ProxySecret == "" {
			fail("admin.auth is proxy but admin.proxy_secret is empty; the proxy must send one in X-Auth-Proxy-Secret")
		}
		if c.Admin.ProxyLogoutURL != "" {
			if u, err := url.Parse(c.Admin.ProxyLogoutURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
				fail("admin.proxy_logout_url must be an absolute http or https URL, got %q", c.Admin.ProxyLogoutURL)
			}
		}
	default:
		fail("admin.auth must be password or proxy, got %q", c.Admin.Auth)
	}
	return errors.Join(errs...)
}

// Warnings are settings that are valid but probably not what was meant;
// doma serve logs them at start.
func (c *Config) Warnings() []string {
	var out []string
	if u, err := url.Parse(c.Server.BaseURL); err == nil && u.Scheme == "http" && !isLoopback(u.Hostname()) {
		out = append(out, "server.base_url is http on a non-local host; the admin cookie is only Secure over https")
	}
	if c.ProxyAuth() {
		for _, cidr := range c.Admin.ProxyCIDRs {
			if _, n, err := net.ParseCIDR(cidr); err == nil {
				if ones, _ := n.Mask.Size(); ones == 0 {
					out = append(out, "admin.proxy_cidrs trusts every peer ("+cidr+"); anyone who reaches the port with the secret is the admin")
				}
			}
		}
		if len(c.Server.TrustedProxies) == 0 {
			out = append(out, "admin.auth is proxy but server.trusted_proxies is empty; rate limits and logs will see the proxy's address, not the client's")
		}
	}
	return out
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// Redacted returns a copy with every secret replaced by "***".
func (c *Config) Redacted() *Config {
	cp := *c
	cp.Server.TrustedProxies = append([]string(nil), c.Server.TrustedProxies...)
	cp.Admin.ProxyCIDRs = append([]string(nil), c.Admin.ProxyCIDRs...)
	redact(reflect.ValueOf(&cp).Elem())
	return &cp
}

// TOML renders the config as TOML text.
func (c *Config) TOML() ([]byte, error) {
	return toml.Marshal(c)
}

func redact(v reflect.Value) {
	t := v.Type()
	for i := range t.NumField() {
		f := t.Field(i)
		fv := v.Field(i)
		switch {
		case fv.Kind() == reflect.Struct:
			redact(fv)
		case f.Tag.Get("redact") == "true" && fv.Kind() == reflect.String && fv.String() != "":
			fv.SetString("***")
		}
	}
}

// applyEnv overlays DOMA_<SECTION>_<KEY> values onto v. Lists are comma
// separated.
func applyEnv(v reflect.Value, prefix string, lookup func(string) (string, bool)) error {
	t := v.Type()
	for i := range t.NumField() {
		f := t.Field(i)
		key, _, _ := strings.Cut(f.Tag.Get("toml"), ",")
		if key == "" || key == "-" {
			continue
		}
		name := prefix + "_" + strings.ToUpper(key)
		fv := v.Field(i)
		if fv.Kind() == reflect.Struct {
			if err := applyEnv(fv, name, lookup); err != nil {
				return err
			}
			continue
		}
		raw, ok := lookup(name)
		if !ok {
			continue
		}
		if err := setFromString(fv, raw); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	return nil
}

func setFromString(fv reflect.Value, raw string) error {
	if fv.CanAddr() {
		if u, ok := fv.Addr().Interface().(encoding.TextUnmarshaler); ok {
			return u.UnmarshalText([]byte(raw))
		}
	}
	switch fv.Kind() {
	case reflect.String:
		fv.SetString(raw)
	case reflect.Bool:
		b, err := strconv.ParseBool(raw)
		if err != nil {
			return fmt.Errorf("expected true or false, got %q", raw)
		}
		fv.SetBool(b)
	case reflect.Int, reflect.Int64:
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return fmt.Errorf("expected an integer, got %q", raw)
		}
		fv.SetInt(n)
	case reflect.Slice:
		if fv.Type().Elem().Kind() != reflect.String {
			return errors.New("unsupported list type")
		}
		var items []string
		for part := range strings.SplitSeq(raw, ",") {
			if p := strings.TrimSpace(part); p != "" {
				items = append(items, p)
			}
		}
		fv.Set(reflect.ValueOf(items))
	default:
		return fmt.Errorf("unsupported type %s", fv.Type())
	}
	return nil
}

// resolveEnvRefs replaces string values of the form env:NAME with the value
// of that environment variable, so a secret can stay out of the file.
func resolveEnvRefs(v reflect.Value, lookup func(string) (string, bool)) error {
	t := v.Type()
	for i := range t.NumField() {
		fv := v.Field(i)
		switch fv.Kind() {
		case reflect.Struct:
			if err := resolveEnvRefs(fv, lookup); err != nil {
				return err
			}
		case reflect.String:
			if name, ok := strings.CutPrefix(fv.String(), "env:"); ok {
				val, found := lookup(name)
				if !found {
					return fmt.Errorf("%s.%s refers to env:%s but %s is not set", t.Name(), t.Field(i).Name, name, name)
				}
				fv.SetString(val)
			}
		}
	}
	return nil
}

// ByteSize is a byte count that reads "8MB", "64KB", "512" and similar.
type ByteSize int64

// UnmarshalText implements encoding.TextUnmarshaler.
func (b *ByteSize) UnmarshalText(text []byte) error {
	s := strings.ToUpper(strings.TrimSpace(string(text)))
	if s == "" {
		return errors.New("empty size")
	}
	mult := int64(1)
	for _, suf := range []struct {
		s string
		m int64
	}{{"GB", 1 << 30}, {"MB", 1 << 20}, {"KB", 1 << 10}, {"G", 1 << 30}, {"M", 1 << 20}, {"K", 1 << 10}, {"B", 1}} {
		if strings.HasSuffix(s, suf.s) {
			mult = suf.m
			s = strings.TrimSpace(strings.TrimSuffix(s, suf.s))
			break
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n < 0 {
		return fmt.Errorf("invalid size %q", string(text))
	}
	*b = ByteSize(n * mult)
	return nil
}

// MarshalText implements encoding.TextMarshaler.
func (b ByteSize) MarshalText() ([]byte, error) { return []byte(b.String()), nil }

// String renders the size with the largest exact unit.
func (b ByteSize) String() string {
	v := int64(b)
	switch {
	case v >= 1<<30 && v%(1<<30) == 0:
		return strconv.FormatInt(v>>30, 10) + "GB"
	case v >= 1<<20 && v%(1<<20) == 0:
		return strconv.FormatInt(v>>20, 10) + "MB"
	case v >= 1<<10 && v%(1<<10) == 0:
		return strconv.FormatInt(v>>10, 10) + "KB"
	default:
		return strconv.FormatInt(v, 10)
	}
}
