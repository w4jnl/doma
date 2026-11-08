package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func env(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestDefaultsValidate(t *testing.T) {
	cfg, err := LoadWith("", env(nil))
	if err != nil {
		t.Fatalf("defaults do not validate: %v", err)
	}
	if cfg.Sync.MaxEventsPerResponse != 500 || cfg.Retention.EventsDays != 365 || cfg.Push.Enabled {
		t.Errorf("unexpected defaults: %+v", cfg)
	}
	if got := cfg.SecretKeyFile(); got != "secret.key" {
		t.Errorf("SecretKeyFile() = %q", got)
	}
	if got := cfg.PhotosDir(); got != "photos" {
		t.Errorf("PhotosDir() = %q", got)
	}
	if got := cfg.PushKeyFile(); got != "apns.p8" {
		t.Errorf("PushKeyFile() = %q", got)
	}
}

func TestFileAndEnv(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "doma.toml")
	file := `
[server]
listen = ":9090"
base_url = "https://doma.example.com"
trusted_proxies = ["10.0.0.0/8"]
[db]
path = "/var/lib/doma/doma.db"
[photos]
max_bytes_per_upload = "4MB"
[metrics]
token = "env:DOMA_TEST_METRICS"
`
	if err := os.WriteFile(path, []byte(file), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadWith(path, env(map[string]string{
		"DOMA_SERVER_LISTEN":          ":7070",
		"DOMA_SERVER_TRUSTED_PROXIES": "10.0.0.0/8, 192.168.0.0/16",
		"DOMA_RETENTION_EVENTS_DAYS":  "30",
		"DOMA_TEST_METRICS":           "s3cret",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Server.Listen != ":7070" {
		t.Errorf("env must win over the file, got listen %q", cfg.Server.Listen)
	}
	if len(cfg.Server.TrustedProxies) != 2 {
		t.Errorf("list from env: %v", cfg.Server.TrustedProxies)
	}
	if cfg.Retention.EventsDays != 30 {
		t.Errorf("int from env: %+v", cfg.Retention)
	}
	if cfg.Photos.MaxBytesPerUpload != 4<<20 {
		t.Errorf("byte size: %d", cfg.Photos.MaxBytesPerUpload)
	}
	if cfg.Metrics.Token != "s3cret" {
		t.Errorf("env: reference not resolved: %q", cfg.Metrics.Token)
	}
	if got := cfg.SecretKeyFile(); got != "/var/lib/doma/secret.key" {
		t.Errorf("SecretKeyFile() = %q", got)
	}
	if got := cfg.PhotosDir(); got != "/var/lib/doma/photos" {
		t.Errorf("PhotosDir() = %q", got)
	}
	red := cfg.Redacted()
	if red.Metrics.Token != "***" || cfg.Metrics.Token != "s3cret" {
		t.Errorf("redaction: %q / %q", red.Metrics.Token, cfg.Metrics.Token)
	}
	out, err := red.TOML()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(out), "s3cret") || !strings.Contains(string(out), "max_bytes_per_upload = '4MB'") {
		t.Errorf("TOML output: %s", out)
	}
}

func TestUnknownKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "doma.toml")
	if err := os.WriteFile(path, []byte("[server]\nlisten = \":1\"\nport = 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := LoadWith(path, env(nil))
	if err == nil || !strings.Contains(err.Error(), "unknown keys") {
		t.Fatalf("expected unknown key error, got %v", err)
	}
}

func TestEnvRefMissing(t *testing.T) {
	_, err := LoadWith("", env(map[string]string{"DOMA_METRICS_TOKEN": "env:NOPE"}))
	if err == nil || !strings.Contains(err.Error(), "NOPE is not set") {
		t.Fatalf("expected missing env ref error, got %v", err)
	}
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"relative base url", map[string]string{"DOMA_SERVER_BASE_URL": "doma.example.com"}, "absolute URL"},
		{"base url with path", map[string]string{"DOMA_SERVER_BASE_URL": "https://example.com/doma"}, "without a path"},
		{"bad cidr", map[string]string{"DOMA_SERVER_TRUSTED_PROXIES": "10.0.0.1"}, "not a CIDR"},
		{"empty db", map[string]string{"DOMA_DB_PATH": ""}, "db.path"},
		{"too many events", map[string]string{"DOMA_SYNC_MAX_EVENTS_PER_RESPONSE": "5000"}, "between 1 and 2000"},
		{"push without ids", map[string]string{"DOMA_PUSH_ENABLED": "true"}, "push.key_id or push.team_id"},
		{"snapshot hour", map[string]string{"DOMA_RETENTION_SNAPSHOT_HOUR": "24"}, "between 0 and 23"},
		{"staleness", map[string]string{"DOMA_DEFAULTS_STALENESS_DAYS": "0"}, "staleness_days"},
		{"log level", map[string]string{"DOMA_LOG_LEVEL": "loud"}, "log.level"},
		{"log format", map[string]string{"DOMA_LOG_FORMAT": "xml"}, "log.format"},
		{"bad bool", map[string]string{"DOMA_PUSH_ENABLED": "yes"}, "expected true or false"},
		{"bad size", map[string]string{"DOMA_PHOTOS_MAX_BYTES_PER_UPLOAD": "big"}, "invalid size"},
		{"vision provider", map[string]string{"DOMA_VISION_PROVIDER": "gemini"}, "openai or anthropic"},
		{"vision without url", map[string]string{"DOMA_VISION_ENABLED": "true", "DOMA_VISION_MODEL": "m"}, "vision.url"},
		{"vision without model", map[string]string{"DOMA_VISION_ENABLED": "true", "DOMA_VISION_URL": "http://ollama:11434/v1"}, "vision.model"},
		{"anthropic without key", map[string]string{"DOMA_VISION_ENABLED": "true", "DOMA_VISION_PROVIDER": "anthropic", "DOMA_VISION_MODEL": "claude-opus-5-5"}, "vision.api_key"},
		{"logos without key", map[string]string{"DOMA_LOGOS_ENABLED": "true"}, "logos.api_key"},
		{"logos timeout", map[string]string{"DOMA_LOGOS_TIMEOUT_SECONDS": "0"}, "logos.timeout_seconds"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := LoadWith("", env(c.env))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want an error containing %q", err, c.want)
			}
		})
	}
}

func TestPushEnabledValidates(t *testing.T) {
	cfg, err := LoadWith("", env(map[string]string{"DOMA_PUSH_ENABLED": "true", "DOMA_PUSH_KEY_ID": "ABC123", "DOMA_PUSH_TEAM_ID": "TEAM42"}))
	if err != nil {
		t.Fatal(err)
	}
	// which gateway a push goes to is the device's to say, so there is nothing to warn about
	if len(cfg.Warnings()) != 0 {
		t.Errorf("warnings: %v", cfg.Warnings())
	}
}

func TestWarnsPlainHTTPOnPublicHost(t *testing.T) {
	cfg, err := LoadWith("", env(map[string]string{"DOMA_SERVER_BASE_URL": "http://doma.example.com"}))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Warnings()) != 1 {
		t.Errorf("warnings: %v", cfg.Warnings())
	}
	cfg, _ = LoadWith("", env(nil))
	if len(cfg.Warnings()) != 0 {
		t.Errorf("localhost must not warn: %v", cfg.Warnings())
	}
}

func TestByteSizeString(t *testing.T) {
	for in, want := range map[ByteSize]string{8 << 20: "8MB", 1 << 30: "1GB", 3 << 10: "3KB", 1500: "1500"} {
		if got := in.String(); got != want {
			t.Errorf("%d.String() = %q, want %q", int64(in), got, want)
		}
	}
}

func TestAdminProxyValidates(t *testing.T) {
	bad := []struct{ name, file, want string }{
		{"unknown mode", "[admin]\nauth = \"oidc\"\n", "admin.auth must be password or proxy"},
		{"no peers", "[admin]\nauth = \"proxy\"\nproxy_secret = \"s\"\n", "admin.proxy_cidrs is empty"},
		{"bad peer", "[admin]\nauth = \"proxy\"\nproxy_cidrs = [\"traefik\"]\nproxy_secret = \"s\"\n", "is not a CIDR"},
		{"no secret", "[admin]\nauth = \"proxy\"\nproxy_cidrs = [\"172.16.0.0/12\"]\n", "admin.proxy_secret is empty"},
		{"relative logout", "[admin]\nauth = \"proxy\"\nproxy_cidrs = [\"172.16.0.0/12\"]\nproxy_secret = \"s\"\nproxy_logout_url = \"/logout\"\n", "admin.proxy_logout_url must be an absolute"},
	}
	for _, c := range bad {
		path := filepath.Join(t.TempDir(), "doma.toml")
		if err := os.WriteFile(path, []byte(c.file), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := LoadWith(path, env(nil))
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", c.name, err, c.want)
		}
	}
	cfg, err := LoadWith("", env(map[string]string{
		"DOMA_ADMIN_AUTH": "proxy", "DOMA_ADMIN_PROXY_CIDRS": "172.16.0.0/12, 0.0.0.0/0", "DOMA_ADMIN_PROXY_SECRET": "env:PROXY_SECRET", "PROXY_SECRET": "hush",
		"DOMA_ADMIN_PROXY_LOGOUT_URL": "https://auth.example.com/logout?rd=https://doma.example.com",
	}))
	if err != nil {
		t.Fatalf("proxy from the environment: %v", err)
	}
	if !cfg.ProxyAuth() || cfg.Admin.ProxySecret != "hush" || len(cfg.Admin.ProxyCIDRs) != 2 {
		t.Errorf("unexpected admin config: %+v", cfg.Admin)
	}
	if got := cfg.Redacted().Admin.ProxySecret; got != "***" {
		t.Errorf("Redacted secret = %q", got)
	}
	warns := strings.Join(cfg.Warnings(), "\n")
	if !strings.Contains(warns, "trusts every peer") || !strings.Contains(warns, "server.trusted_proxies is empty") {
		t.Errorf("warnings = %q", warns)
	}
	if def, _ := LoadWith("", env(nil)); def.ProxyAuth() || def.Admin.Auth != "password" {
		t.Errorf("default admin.auth = %q", def.Admin.Auth)
	}
}
