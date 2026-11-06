//go:build e2e

package e2e

import (
	"net/http"
	"net/url"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/client"
	"github.com/w4jnl/doma/internal/domain"
)

// TestRestore is the backup and restore drill: a live server with the admin's second step
// on, a household, a device, events and a photo is backed up from /admin/server; the server
// stops; scripts/restore.sh puts the zip onto an empty directory; the server that comes up
// on it has the household, the device, the log, the photo and the second step, and the
// phone carries on with its key.
func TestRestore(t *testing.T) {
	in := start(t)
	ctx := t.Context()

	// the admin, with the second step on: its secret lives sealed under secret.key
	resp, _ := in.form("/setup", url.Values{"login": {"j"}, "password": {"long enough password"}, "confirm": {"long enough password"}}, nil)
	if resp.StatusCode != http.StatusSeeOther || len(resp.Cookies()) == 0 {
		t.Fatalf("setup: %d", resp.StatusCode)
	}
	session := resp.Cookies()[0]
	_, body := in.page("/admin", session)
	csrf := regexp.MustCompile(`name="_csrf" value="([^"]+)"`).FindStringSubmatch(body)[1]
	_, body = in.form("/admin/server/totp/setup", url.Values{"_csrf": {csrf}}, session)
	secret := regexp.MustCompile(`name="secret" value="([^"]+)"`).FindStringSubmatch(body)
	if secret == nil {
		t.Fatal("no TOTP secret on the setup page")
	}
	code, _ := auth.TOTPCode(secret[1], time.Now())
	if resp, _ = in.form("/admin/server/totp/confirm", url.Values{"_csrf": {csrf}, "secret": {secret[1]}, "code": {code}}, session); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("totp confirm: %d", resp.StatusCode)
	}

	// a household, its owner on a phone, a line on the list, a spot with a photo
	resp, _ = in.form("/admin/households", url.Values{"_csrf": {csrf}, "name": {"De Vries"}, "timezone": {"Europe/Amsterdam"}, "home": {"Gouda"}}, session)
	hhPath := resp.Header.Get("Location")
	household := strings.TrimPrefix(hhPath, "/admin/h/")
	_, body = in.form(hhPath+"/invite", url.Values{"_csrf": {csrf}}, session)
	token := regexp.MustCompile(`/i/([A-Za-z0-9_-]+)`).FindStringSubmatch(body)
	if token == nil {
		t.Fatal("no owner invite")
	}
	a := &phone{}
	a.Client, _ = client.New(in.base, in.http)
	a.clock, _ = domain.NewClock("a", nil)
	if _, err := a.Accept(ctx, token[1], "Jaro", "Jaro's iPhone"); err != nil {
		t.Fatal(err)
	}
	first := a.sync(t, household)
	if len(first.Events) != 2 {
		t.Fatalf("a new household has a list and a home: %+v", first.Events)
	}
	listID := field(first.Events[0].Payload, "list_id")
	homeID := field(first.Events[1].Payload, "home_id")
	melk, spot, photoID := domain.NewID(), domain.NewID(), domain.NewID()
	a.sync(t, household,
		a.event("item.named", map[string]any{"item_id": melk, "name": "melk"}),
		a.event("entry.added", map[string]any{"list_id": listID, "item_id": melk}),
		a.event("spot.created", map[string]any{"spot_id": spot, "home_id": homeID, "name": "Fridge"}),
		a.event("photo.added", map[string]any{"photo_id": photoID, "spot_id": spot, "bytes": 1, "width": 800, "height": 600}),
	)
	if err := a.Upload(ctx, "/photos/v1/"+household+"/"+photoID, jpegBytes(t, 800, 600), "image/jpeg", nil); err != nil {
		t.Fatal(err)
	}

	// Back up now: the page names the zip, next to the database
	resp, body = in.form("/admin/server/backup", url.Values{"_csrf": {csrf}}, session)
	name := regexp.MustCompile(`doma-backup-[0-9]{8}-[0-9]{6}\.zip`).FindString(body)
	if resp.StatusCode != http.StatusOK || name == "" || !strings.Contains(body, "Backup written") {
		t.Fatalf("backup: %d %q", resp.StatusCode, name)
	}
	zipPath := filepath.Join(in.data, name)

	// the server stops; the zip goes onto an empty directory with the documented script (the
	// photo is two files there: the original and its thumbnail)
	in.stop()
	root, _ := filepath.Abs("../..")
	fresh := filepath.Join(t.TempDir(), "restored")
	out, err := exec.Command("sh", filepath.Join(root, "scripts", "restore.sh"), zipPath, fresh).CombinedOutput()
	if err != nil || !strings.Contains(string(out), "doma.db, secret.key, 2 photos") {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	if out, err := exec.Command("sh", filepath.Join(root, "scripts", "restore.sh"), zipPath, fresh).CombinedOutput(); err == nil {
		t.Fatalf("a restore onto a directory in use should be refused:\n%s", out)
	}

	// the server comes up on it: the admin signs in with the same password and the same
	// second step, and finds the household and the device
	back := startIn(t, fresh)
	resp, _ = back.form("/admin/login", url.Values{"login": {"j"}, "password": {"long enough password"}}, nil)
	if resp.StatusCode != http.StatusSeeOther || !strings.HasPrefix(resp.Header.Get("Location"), "/admin/login/code") || len(resp.Cookies()) == 0 {
		t.Fatalf("login after restore: %d %s", resp.StatusCode, resp.Header.Get("Location"))
	}
	code, _ = auth.TOTPCode(secret[1], time.Now())
	resp, _ = back.form("/admin/login/code", url.Values{"code": {code}}, resp.Cookies()[0])
	session = nil
	for _, c := range resp.Cookies() {
		// the answer also clears the challenge cookie; the session is the one with a value
		if c.Value != "" && c.MaxAge >= 0 {
			session = c
		}
	}
	if resp.StatusCode != http.StatusSeeOther || session == nil {
		t.Fatalf("second step after restore: %d", resp.StatusCode)
	}
	if status, page := back.page(hhPath, session); status != http.StatusOK || !strings.Contains(page, "De Vries") || !strings.Contains(page, "Jaro&#39;s iPhone") {
		t.Fatalf("household page after restore: %d", status)
	}

	// the phone carries on: the same key and credential sign, the whole log comes down
	a.BaseURL = back.base
	a.since = 0
	res := a.sync(t, household)
	var kinds []string
	for _, e := range res.Events {
		kinds = append(kinds, e.Kind)
	}
	if strings.Join(kinds, " ") != "list.created home.created item.named entry.added spot.created photo.added" {
		t.Fatalf("log after restore: %v", kinds)
	}
	// the photo and its thumbnail came back with it
	if raw, ctype, err := a.Download(ctx, "/photos/v1/"+household+"/"+photoID+"/thumb"); err != nil || ctype != "image/jpeg" || len(raw) == 0 {
		t.Fatalf("thumbnail after restore: %v %s", err, ctype)
	}
	if _, _, err := a.Download(ctx, "/photos/v1/"+household+"/"+domain.NewID()); err == nil {
		t.Error("a photo that never was")
	}
}
