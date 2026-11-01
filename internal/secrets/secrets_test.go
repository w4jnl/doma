package secrets

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadCreatesAndReuses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d", "secret.key")
	a, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := a.Seal([]byte("hello"))
	if err != nil || !strings.HasPrefix(sealed, "v1:") {
		t.Fatalf("seal %q %v", sealed, err)
	}
	plain, err := b.Open(sealed)
	if err != nil || string(plain) != "hello" {
		t.Fatalf("open %q %v", plain, err)
	}
	other, _ := FromBytes(make([]byte, 32))
	if _, err := other.Open(sealed); err == nil {
		t.Error("another key opened the value")
	}
	if _, err := a.Open("plain"); err == nil {
		t.Error("plain text opened")
	}
	if err := os.WriteFile(path, []byte("short"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Error("a short key file loaded")
	}
}

func TestSealFileInPlace(t *testing.T) {
	k, _ := FromBytes([]byte("0123456789abcdef0123456789abcdef"))
	path := filepath.Join(t.TempDir(), "apns.p8")
	if err := os.WriteFile(path, []byte("-----BEGIN PRIVATE KEY-----\nabc\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := k.SealFile(path); err != nil {
			t.Fatal(err)
		}
	}
	raw, _ := os.ReadFile(path)
	if !IsSealed(string(raw)) {
		t.Fatalf("file not sealed: %q", raw)
	}
	plain, err := k.OpenFile(path)
	if err != nil || !strings.HasPrefix(string(plain), "-----BEGIN") {
		t.Fatalf("OpenFile %q %v", plain, err)
	}
}
