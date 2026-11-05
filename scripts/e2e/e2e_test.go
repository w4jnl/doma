//go:build e2e

package e2e

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/client"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

// instance is one built binary serving one temp data directory.
type instance struct {
	t    *testing.T
	base string
	http *http.Client
	log  bytes.Buffer
}

func start(t *testing.T) *instance {
	t.Helper()
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "doma")
	build := exec.Command("go", "build", "-o", bin, "./cmd/doma")
	build.Dir = root
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	in := &instance{t: t, base: "http://" + addr, http: &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, bin, "serve")
	cmd.Env = append(os.Environ(),
		"DOMA_SERVER_LISTEN="+addr, "DOMA_SERVER_BASE_URL="+in.base, "DOMA_DB_PATH="+filepath.Join(dir, "data", "doma.db"),
		"DOMA_LOG_FORMAT=json", "DOMA_METRICS_TOKEN=e2e-metrics", "NO_COLOR=1",
	)
	cmd.Stdout, cmd.Stderr = &in.log, &in.log
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cancel()
		_ = cmd.Wait()
		if t.Failed() {
			t.Logf("server log:\n%s", in.log.String())
		}
	})
	for i := 0; ; i++ {
		resp, err := in.http.Get(in.base + "/healthz")
		if err == nil {
			_ = resp.Body.Close()
			break
		}
		if i > 200 {
			t.Fatalf("server did not come up: %v\n%s", err, in.log.String())
		}
		time.Sleep(25 * time.Millisecond)
	}
	return in
}

func (in *instance) form(path string, v url.Values, cookie *http.Cookie) (*http.Response, string) {
	in.t.Helper()
	req, _ := http.NewRequest(http.MethodPost, in.base+path, strings.NewReader(v.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if cookie != nil {
		req.AddCookie(cookie)
	}
	resp, err := in.http.Do(req)
	if err != nil {
		in.t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	return resp, string(body)
}

func (in *instance) page(path string, cookie *http.Cookie) (int, string) {
	in.t.Helper()
	req, _ := http.NewRequest(http.MethodGet, in.base+path, nil)
	if cookie != nil {
		req.AddCookie(cookie)
	}
	resp, err := in.http.Do(req)
	if err != nil {
		in.t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	return resp.StatusCode, string(body)
}

type phone struct {
	*client.Client
	clock *domain.Clock
	since int64
}

func (p *phone) event(kind string, payload map[string]any) json.RawMessage {
	raw, _ := json.Marshal(map[string]any{"id": domain.NewID(), "hlc": p.clock.Next().String(), "kind": kind, "payload": payload})
	return raw
}

func (p *phone) sync(t *testing.T, household string, evs ...json.RawMessage) service.SyncHouseholdResult {
	t.Helper()
	var resp service.SyncResponse
	if err := p.Sync(context.Background(), service.SyncRequest{Households: []service.SyncHousehold{{ID: household, Since: p.since, Events: evs}}}, &resp); err != nil {
		t.Fatalf("sync: %v", err)
	}
	res := resp.Households[0]
	p.since = res.Next
	for _, e := range res.Events {
		if h, err := domain.ParseHLC(e.HLC); err == nil {
			p.clock.Observe(h)
		}
	}
	return res
}

func field(raw json.RawMessage, key string) string {
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	s, _ := m[key].(string)
	return s
}

// TestSmoke: setup, a household, two invites, sync both ways, a flag, a trip, a photo.
func TestSmoke(t *testing.T) {
	in := start(t)
	ctx := context.Background()

	// 1. the setup page, once
	resp, _ := in.form("/setup", url.Values{"login": {"j"}, "password": {"long enough password"}, "confirm": {"long enough password"}}, nil)
	if resp.StatusCode != http.StatusSeeOther || len(resp.Cookies()) == 0 {
		t.Fatalf("setup: %d", resp.StatusCode)
	}
	session := resp.Cookies()[0]
	if code, _ := in.page("/setup", nil); code != http.StatusNotFound {
		t.Fatalf("setup page again: %d", code)
	}

	// 2. a household from the admin page, then the owner invite as a QR
	_, body := in.page("/admin", session)
	csrf := regexp.MustCompile(`name="_csrf" value="([^"]+)"`).FindStringSubmatch(body)[1]
	resp, _ = in.form("/admin/households", url.Values{"_csrf": {csrf}, "name": {"De Vries"}, "timezone": {"Europe/Amsterdam"}, "home": {"Gouda"}}, session)
	hhPath := resp.Header.Get("Location")
	household := strings.TrimPrefix(hhPath, "/admin/h/")
	if code, page := in.page("/admin", session); code != http.StatusOK || !strings.Contains(page, "De Vries") || !strings.Contains(page, "no photos") {
		t.Fatalf("households page with a household: %d", code)
	}
	_, body = in.form(hhPath+"/invite", url.Values{"_csrf": {csrf}}, session)
	token := regexp.MustCompile(`/i/([A-Za-z0-9_-]+)`).FindStringSubmatch(body)
	if token == nil || !strings.Contains(body, "<svg") {
		t.Fatal("no owner invite on the page")
	}

	// 3. two phones: the owner from the admin's invite, the member from the owner's
	a := &phone{}
	a.Client, _ = client.New(in.base, in.http)
	a.clock, _ = domain.NewClock("a", nil)
	acc, err := a.Accept(ctx, token[1], "Jaro", "Jaro's iPhone")
	if err != nil {
		t.Fatal(err)
	}
	var inv map[string]any
	if err := a.Do(ctx, http.MethodPost, "/api/v1/h/"+household+"/invites", map[string]string{"role": "member"}, &inv); err != nil {
		t.Fatal(err)
	}
	memberToken := strings.TrimPrefix(inv["url"].(string), in.base+"/i/")
	if code, page := in.page("/i/"+memberToken, nil); code != http.StatusOK || !strings.Contains(page, "Join De Vries") {
		t.Fatalf("invite page: %d", code)
	}
	b := &phone{}
	b.Client, _ = client.New(in.base, in.http)
	b.clock, _ = domain.NewClock("b", nil)
	if _, err := b.Accept(ctx, memberToken, "Sam", "Sam's iPhone"); err != nil {
		t.Fatal(err)
	}
	var me map[string]any
	if err := b.Get(ctx, "/api/v1/me", &me); err != nil || len(me["memberships"].([]any)) != 1 {
		t.Fatalf("me: %v %v", err, me)
	}

	// 4. sync both ways: a adds, b pulls and strikes, a sees the strike
	first := a.sync(t, household)
	listID := field(first.Events[0].Payload, "list_id")
	homeID := field(first.Events[1].Payload, "home_id")
	melk := domain.NewID()
	res := a.sync(t, household,
		a.event("item.named", map[string]any{"item_id": melk, "name": "melk"}),
		a.event("entry.added", map[string]any{"list_id": listID, "item_id": melk, "qty": 2, "unit": "l"}),
	)
	if len(res.Accepted) != 2 {
		t.Fatalf("a's push: %+v", res)
	}
	pull := b.sync(t, household)
	if len(pull.Events) != 4 {
		t.Fatalf("b's pull: %d events", len(pull.Events))
	}
	b.sync(t, household, b.event("entry.checked", map[string]any{"list_id": listID, "item_id": melk}))
	res = a.sync(t, household)
	if len(res.Events) != 1 || res.Events[0].Kind != "entry.checked" || res.Events[0].PersonID != b.PersonID {
		t.Fatalf("a did not see b's strike: %+v", res)
	}

	// 5. a second home, a staple, a flag flipped to out: it lands on the default list
	hut := domain.NewID()
	olie := domain.NewID()
	a.sync(t, household,
		a.event("home.created", map[string]any{"home_id": hut, "name": "Hut"}),
		a.event("item.named", map[string]any{"item_id": olie, "name": "olijfolie"}),
		a.event("staple.added", map[string]any{"home_id": hut, "item_id": olie}),
		a.event("staple.added", map[string]any{"home_id": homeID, "item_id": olie}),
		a.event("flag.set", map[string]any{"home_id": homeID, "item_id": olie, "state": "have"}),
		a.event("flag.set", map[string]any{"home_id": hut, "item_id": olie, "state": "out"}),
	)
	b.sync(t, household)
	homes := exportHomes(t, b, household)
	if !strings.Contains(homes["homes/hut.md"], "olijfolie: out") || !strings.Contains(homes["homes/gouda.md"], "olijfolie: have") {
		t.Fatalf("flags before the trip:\nhut:\n%s\ngouda:\n%s", homes["homes/hut.md"], homes["homes/gouda.md"])
	}

	// 6. the trip, derived on the phone as the spec says: out at to-home and
	//    have at from-home is the bring list; arriving commits it
	bring := []string{olie}
	trip := domain.NewID()
	a.sync(t, household, a.event("trip.planned", map[string]any{"trip_id": trip, "from_home_id": homeID, "to_home_id": hut, "date": 1_800_000_000_000, "list_id": listID}))
	if planned := b.sync(t, household); len(planned.Events) != 1 || planned.Events[0].Kind != "trip.planned" {
		t.Fatalf("b did not see the plan: %+v", planned)
	}
	a.sync(t, household, a.event("trip.arrived", map[string]any{"trip_id": trip, "from_home_id": homeID, "to_home_id": hut, "moved": bring}))
	if hj := exportFile(t, b, household, "household.json"); !strings.Contains(hj, `"id": "`+trip+`"`) || !strings.Contains(hj, `"date": 1800000000000`) || !strings.Contains(hj, `"arrived_at"`) {
		t.Fatalf("the trip in household.json:\n%s", hj)
	}
	homes = exportHomes(t, b, household)
	if !strings.Contains(homes["homes/hut.md"], "olijfolie: have") || !strings.Contains(homes["homes/gouda.md"], "olijfolie: out") {
		t.Fatalf("flags after the trip:\nhut:\n%s\ngouda:\n%s", homes["homes/hut.md"], homes["homes/gouda.md"])
	}

	// 7. a spot's photo: the event through sync, the JPEG by id, the thumbnail on the other phone
	pantry, photoID := domain.NewID(), domain.NewID()
	a.sync(t, household,
		a.event("spot.created", map[string]any{"spot_id": pantry, "home_id": hut, "name": "Pantry"}),
		a.event("photo.added", map[string]any{"photo_id": photoID, "spot_id": pantry}),
	)
	var stored map[string]any
	if err := a.Upload(ctx, "/photos/v1/"+household+"/"+photoID, jpegBytes(t, 800, 600), "image/jpeg", &stored); err != nil {
		t.Fatalf("photo upload: %v", err)
	}
	if thumb, ctype, err := b.Download(ctx, "/photos/v1/"+household+"/"+photoID+"/thumb"); err != nil || ctype != "image/jpeg" || len(thumb) == 0 {
		t.Fatalf("thumbnail on b: %v %q", err, ctype)
	}
	if _, _, err := b.Download(ctx, "/photos/v1/"+household+"/"+domain.NewID()); err == nil {
		t.Fatal("a photo nobody added was served")
	}

	// 8. the guest view, readiness and metrics
	var guest map[string]any
	if err := a.Do(ctx, http.MethodPost, "/api/v1/h/"+household+"/guests", map[string]any{"home_id": hut, "list_id": listID, "label": "cleaner"}, &guest); err != nil {
		t.Fatal(err)
	}
	guestPath := strings.TrimPrefix(guest["url"].(string), in.base)
	if code, page := in.page(guestPath, nil); code != http.StatusOK || !strings.Contains(page, "<h1>Hut</h1>") {
		t.Fatalf("guest page: %d", code)
	}
	if code, _ := in.page("/readyz", nil); code != http.StatusOK {
		t.Errorf("readyz: %d", code)
	}
	req, _ := http.NewRequest(http.MethodGet, in.base+"/metrics", nil)
	req.Header.Set("Authorization", "Bearer e2e-metrics")
	mresp, err := in.http.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	mbody, _ := io.ReadAll(mresp.Body)
	_ = mresp.Body.Close()
	if mresp.StatusCode != http.StatusOK || !strings.Contains(string(mbody), "doma_sync_requests_total") {
		t.Errorf("metrics: %d", mresp.StatusCode)
	}
	_ = acc
}

// jpegBytes is a w by h JPEG, what a phone would send.
func jpegBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := range w {
		for y := range h {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 120, 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// exportHomes downloads the export and returns the homes/*.md files.
func exportHomes(t *testing.T, p *phone, household string) map[string]string {
	t.Helper()
	out := map[string]string{}
	for name, body := range exportFiles(t, p, household) {
		if strings.HasPrefix(name, "homes/") {
			out[name] = body
		}
	}
	return out
}

// exportFile downloads the export and returns one file of it.
func exportFile(t *testing.T, p *phone, household, name string) string {
	t.Helper()
	return exportFiles(t, p, household)[name]
}

func exportFiles(t *testing.T, p *phone, household string) map[string]string {
	t.Helper()
	raw, _, err := p.Download(context.Background(), "/api/v1/h/"+household+"/export")
	if err != nil {
		t.Fatal(err)
	}
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, f := range zr.File {
		rc, _ := f.Open()
		b, _ := io.ReadAll(rc)
		_ = rc.Close()
		out[f.Name] = string(b)
	}
	return out
}
