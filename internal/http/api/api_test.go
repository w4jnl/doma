package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db/dbtest"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/http/api"
	"github.com/w4jnl/doma/internal/service"
)

// device is a test client with its own key.
type device struct {
	t      *testing.T
	mux    http.Handler
	signer auth.Signer
	cred   string
	person string
	now    func() time.Time
}

func (d *device) do(method, path string, body any) (*httptest.ResponseRecorder, map[string]any) {
	d.t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(raw))
	if body != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	if d.signer != nil {
		if err := auth.SignRequest(r, d.cred, d.signer, raw, d.now()); err != nil {
			d.t.Fatal(err)
		}
	}
	rec := httptest.NewRecorder()
	d.mux.ServeHTTP(rec, r)
	var out map[string]any
	if rec.Body.Len() > 0 {
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
	}
	return rec, out
}

type world struct {
	svc *service.Service
	mux *http.ServeMux
	api *api.API
	now time.Time
}

func newWorld(t *testing.T) *world {
	t.Helper()
	auth.FastParamsForTests()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := service.New(dbtest.Open(t), service.Config{BaseURL: "https://doma.test"}, log)
	a := api.New(svc, log)
	w := &world{svc: svc, mux: http.NewServeMux(), api: a, now: time.Unix(1_800_000_000, 0)}
	a.SetClock(func() time.Time { return w.now })
	a.Mount(w.mux)
	return w
}

// join accepts a fresh invite for a household and returns the signed device.
func (w *world) join(t *testing.T, householdID string, role domain.Role, name string) *device {
	t.Helper()
	inv, err := w.svc.CreateInvite(context.Background(), domain.Scope{HouseholdID: householdID, Role: domain.RoleOwner}, role)
	if err != nil {
		t.Fatal(err)
	}
	signer, _ := auth.NewP256Signer()
	d := &device{t: t, mux: w.mux, now: func() time.Time { return w.now }}
	rec, out := d.do(http.MethodPost, "/i/"+inv.Token, map[string]string{"public_key": signer.Public(), "platform": "ios", "label": name + "'s iPhone", "display_name": name})
	if rec.Code != http.StatusCreated {
		t.Fatalf("accept: %d %s", rec.Code, rec.Body.String())
	}
	d.signer, d.cred, d.person = signer, out["credential_id"].(string), out["person_id"].(string)
	if out["server"] != "https://doma.test" || out["role"] != string(role) {
		t.Errorf("accept body: %v", out)
	}
	return d
}

func TestInviteAcceptAndMe(t *testing.T) {
	w := newWorld(t)
	ctx := context.Background()
	h, _ := w.svc.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	owner := w.join(t, h.ID, domain.RoleOwner, "Jaro")
	rec, out := owner.do(http.MethodGet, "/api/v1/me", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("me: %d %s", rec.Code, rec.Body.String())
	}
	ms := out["memberships"].([]any)
	if len(ms) != 1 || ms[0].(map[string]any)["role"] != "owner" || ms[0].(map[string]any)["household_name"] != "Family" {
		t.Errorf("me: %v", out)
	}
	// the household's time zone and staleness travel with the membership, so a
	// device learns a change made elsewhere
	if m := ms[0].(map[string]any); m["timezone"] != "Europe/Amsterdam" || m["staleness_days"] != float64(60) {
		t.Errorf("me membership: %v", m)
	}
	// unsigned, bad timestamp and replayed requests are 401 problems
	anon := &device{t: t, mux: w.mux, now: owner.now}
	rec, out = anon.do(http.MethodGet, "/api/v1/me", nil)
	if rec.Code != http.StatusUnauthorized || rec.Header().Get("Content-Type") != "application/problem+json" || out["type"] != "unauthorized" {
		t.Errorf("unsigned: %d %v", rec.Code, out)
	}
	stale := &device{t: t, mux: w.mux, signer: owner.signer, cred: owner.cred, now: func() time.Time { return w.now.Add(-10 * time.Minute) }}
	if rec, _ := stale.do(http.MethodGet, "/api/v1/me", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("stale timestamp: %d", rec.Code)
	}
	r := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	_ = auth.SignRequest(r, owner.cred, owner.signer, nil, w.now)
	rec1, rec2 := httptest.NewRecorder(), httptest.NewRecorder()
	w.mux.ServeHTTP(rec1, r)
	r2 := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	r2.Header = r.Header.Clone()
	w.mux.ServeHTTP(rec2, r2)
	if rec1.Code != http.StatusOK || rec2.Code != http.StatusUnauthorized {
		t.Errorf("replay: %d then %d", rec1.Code, rec2.Code)
	}
	// a second accept of the same invite is a 409; a bad token a 404; garbage a 400
	inv, _ := w.svc.CreateInvite(ctx, domain.Scope{HouseholdID: h.ID, PersonID: owner.person, Role: domain.RoleOwner}, domain.RoleMember)
	signer, _ := auth.NewEd25519Signer()
	body := map[string]string{"public_key": signer.Public(), "display_name": "Sam"}
	if rec, _ := anon.do(http.MethodPost, "/i/"+inv.Token, body); rec.Code != http.StatusCreated {
		t.Fatalf("accept: %d", rec.Code)
	}
	if rec, _ := anon.do(http.MethodPost, "/i/"+inv.Token, body); rec.Code != http.StatusConflict {
		t.Errorf("second accept: %d", rec.Code)
	}
	if rec, _ := anon.do(http.MethodPost, "/i/nope-nope-nope-nope-nope-nope", body); rec.Code != http.StatusNotFound {
		t.Errorf("unknown token: %d", rec.Code)
	}
	if rec, out := anon.do(http.MethodPost, "/i/"+inv.Token, map[string]string{"display_name": "x", "public_key": "junk"}); rec.Code != http.StatusUnprocessableEntity || out["field"] != "public_key" {
		t.Errorf("bad key: %d %v", rec.Code, out)
	}
	rr := httptest.NewRequest(http.MethodPost, "/i/"+inv.Token, bytes.NewReader([]byte("{not json")))
	rec = httptest.NewRecorder()
	w.mux.ServeHTTP(rec, rr)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("bad json: %d", rec.Code)
	}
	for range api.InviteLookupsPerMinute + 2 {
		rec, _ = anon.do(http.MethodPost, "/i/nope-nope-nope-nope-nope-nope", body)
	}
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") == "" {
		t.Errorf("invite lookup limit: %d", rec.Code)
	}
}

func TestMembersRolesAndBoundaries(t *testing.T) {
	w := newWorld(t)
	ctx := context.Background()
	h, _ := w.svc.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	other, _ := w.svc.CreateHousehold(ctx, "Others", "Europe/Amsterdam", "Elsewhere")
	owner := w.join(t, h.ID, domain.RoleOwner, "Jaro")
	member := w.join(t, h.ID, domain.RoleMember, "Sam")
	stranger := w.join(t, other.ID, domain.RoleOwner, "Alex")
	base := "/api/v1/h/" + h.ID

	rec, out := member.do(http.MethodGet, base+"/members", nil)
	if rec.Code != http.StatusOK || len(out["members"].([]any)) != 2 {
		t.Fatalf("members: %d %v", rec.Code, out)
	}
	// another household's owner gets 404, not 403
	if rec, _ := stranger.do(http.MethodGet, base+"/members", nil); rec.Code != http.StatusNotFound {
		t.Errorf("stranger: %d", rec.Code)
	}
	if rec, _ := stranger.do(http.MethodGet, "/api/v1/h/nope/members", nil); rec.Code != http.StatusNotFound {
		t.Errorf("unknown household: %d", rec.Code)
	}
	// a member may not invite, change roles or rename
	if rec, out := member.do(http.MethodPost, base+"/invites", map[string]any{"device": true}); rec.Code != http.StatusCreated || out["device"] != true || out["url"] == nil {
		t.Errorf("a member's device invite: %d %v", rec.Code, out)
	}
	if rec, _ := member.do(http.MethodPost, base+"/invites", map[string]string{"role": "member"}); rec.Code != http.StatusForbidden {
		t.Errorf("member inviting: %d", rec.Code)
	}
	if rec, _ := member.do(http.MethodPut, base, map[string]string{"name": "X", "timezone": "Europe/Amsterdam"}); rec.Code != http.StatusForbidden {
		t.Errorf("member renaming: %d", rec.Code)
	}
	// the owner invites, lists and revokes
	rec, out = owner.do(http.MethodPost, base+"/invites", map[string]string{"role": "member"})
	if rec.Code != http.StatusCreated || out["url"] == nil {
		t.Fatalf("invite: %d %v", rec.Code, out)
	}
	rec, out = owner.do(http.MethodGet, base+"/invites", nil)
	if rec.Code != http.StatusOK || len(out["invites"].([]any)) != 1 {
		t.Errorf("invites: %d %v", rec.Code, out)
	}
	invID := out["invites"].([]any)[0].(map[string]any)["id"].(string)
	if rec, _ := stranger.do(http.MethodDelete, base+"/invites/"+invID, nil); rec.Code != http.StatusNotFound {
		t.Errorf("stranger revoking: %d", rec.Code)
	}
	if rec, _ := owner.do(http.MethodDelete, base+"/invites/"+invID, nil); rec.Code != http.StatusNoContent {
		t.Errorf("revoke invite: %d", rec.Code)
	}
	if rec, _ := owner.do(http.MethodDelete, base+"/invites/"+invID, nil); rec.Code != http.StatusNotFound {
		t.Errorf("revoke twice: %d", rec.Code)
	}
	// roles: the last owner stays
	if rec, out := owner.do(http.MethodPut, base+"/members/"+owner.person+"/role", map[string]string{"role": "member"}); rec.Code != http.StatusConflict || out["detail"] == "" {
		t.Errorf("demote last owner: %d %v", rec.Code, out)
	}
	if rec, _ := owner.do(http.MethodPut, base+"/members/"+member.person+"/role", map[string]string{"role": "owner"}); rec.Code != http.StatusNoContent {
		t.Errorf("promote: %d", rec.Code)
	}
	if rec, _ := owner.do(http.MethodPut, base+"/members/"+member.person+"/role", map[string]string{"role": "king"}); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("bad role: %d", rec.Code)
	}
	// rename with staleness
	rec, out = owner.do(http.MethodPut, base, map[string]any{"name": "De Vries", "timezone": "Europe/Amsterdam", "staleness_days": 30})
	if rec.Code != http.StatusOK || out["name"] != "De Vries" || out["staleness_days"] != float64(30) {
		t.Errorf("rename: %d %v", rec.Code, out)
	}
	// unknown fields are a 400
	rr := httptest.NewRequest(http.MethodPut, base, bytes.NewReader([]byte(`{"name":"x","timezone":"Europe/Amsterdam","colour":"teal"}`)))
	_ = auth.SignRequest(rr, owner.cred, owner.signer, []byte(`{"name":"x","timezone":"Europe/Amsterdam","colour":"teal"}`), w.now)
	rec = httptest.NewRecorder()
	w.mux.ServeHTTP(rec, rr)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("unknown field: %d", rec.Code)
	}
	// devices: push token, revoke, then 401
	if rec, _ := member.do(http.MethodPost, "/api/v1/devices/"+member.cred+"/apns", map[string]string{"token": "abc"}); rec.Code != http.StatusNoContent {
		t.Errorf("apns: %d", rec.Code)
	}
	if rec, _ := member.do(http.MethodPost, "/api/v1/devices/"+member.cred+"/apns", map[string]any{"token": "abc", "sandbox": true}); rec.Code != http.StatusNoContent {
		t.Errorf("apns sandbox: %d", rec.Code)
	}
	if rec, _ := member.do(http.MethodPut, "/api/v1/devices/"+member.cred+"/notify", map[string]any{"muted_lists": []string{"L9"}, "clears": false}); rec.Code != http.StatusNoContent {
		t.Errorf("notify prefs: %d", rec.Code)
	}
	if rec, out := member.do(http.MethodGet, "/api/v1/me", nil); rec.Code != http.StatusOK || !strings.Contains(fmt.Sprint(out["credentials"]), "L9") {
		t.Errorf("me carries the prefs: %d %v", rec.Code, out["credentials"])
	}
	if rec, _ := member.do(http.MethodPut, "/api/v1/devices/"+owner.cred+"/notify", map[string]any{"muted_lists": []string{}, "clears": true}); rec.Code != http.StatusNotFound {
		t.Errorf("notify prefs on another device: %d", rec.Code)
	}
	if rec, _ := member.do(http.MethodPost, "/api/v1/devices/"+owner.cred+"/apns", map[string]string{"token": "abc"}); rec.Code != http.StatusNotFound {
		t.Errorf("apns on another device: %d", rec.Code)
	}
	if rec, _ := stranger.do(http.MethodDelete, "/api/v1/credentials/"+member.cred, nil); rec.Code != http.StatusNotFound {
		t.Errorf("stranger revoking a device: %d", rec.Code)
	}
	if rec, _ := owner.do(http.MethodDelete, "/api/v1/credentials/"+member.cred, nil); rec.Code != http.StatusNoContent {
		t.Errorf("owner revoking a member's device: %d", rec.Code)
	}
	if rec, _ := member.do(http.MethodGet, "/api/v1/me", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("revoked device: %d", rec.Code)
	}
	// remove: the owner removes the other owner, the removed person gets 404 after
	if rec, _ := owner.do(http.MethodDelete, base+"/members/"+member.person, nil); rec.Code != http.StatusNoContent {
		t.Errorf("remove: %d", rec.Code)
	}
	if rec, _ := owner.do(http.MethodGet, "/api/v1/openapi.yaml", nil); rec.Code != http.StatusOK {
		t.Errorf("openapi: %d", rec.Code)
	}
}

func TestGuestsAPI(t *testing.T) {
	w := newWorld(t)
	ctx := context.Background()
	h, _ := w.svc.CreateHousehold(ctx, "Family", "Europe/Amsterdam", "Gouda")
	owner := w.join(t, h.ID, domain.RoleOwner, "Jaro")
	member := w.join(t, h.ID, domain.RoleMember, "Sam")
	d, err := w.svc.HouseholdDetail(ctx, h.ID)
	if err != nil {
		t.Fatal(err)
	}
	base := "/api/v1/h/" + h.ID + "/guests"
	if rec, _ := member.do(http.MethodPost, base, map[string]any{"home_id": d.Homes[0].ID, "list_id": d.Lists[0].ID, "label": "cleaner"}); rec.Code != http.StatusForbidden {
		t.Errorf("member making a guest: %d", rec.Code)
	}
	rec, out := owner.do(http.MethodPost, base, map[string]any{"home_id": d.Homes[0].ID, "list_id": d.Lists[0].ID, "label": "cleaner", "days": 3})
	if rec.Code != http.StatusCreated || out["url"] == nil || out["active"] != true {
		t.Fatalf("create guest: %d %v", rec.Code, out)
	}
	id := out["id"].(string)
	rec, out = owner.do(http.MethodGet, base, nil)
	if rec.Code != http.StatusOK || len(out["guests"].([]any)) != 1 {
		t.Errorf("list guests: %d %v", rec.Code, out)
	}
	if rec, _ := owner.do(http.MethodDelete, base+"/"+id, nil); rec.Code != http.StatusNoContent {
		t.Errorf("revoke guest: %d", rec.Code)
	}
	if rec, _ := owner.do(http.MethodDelete, base+"/"+id, nil); rec.Code != http.StatusNoContent && rec.Code != http.StatusNotFound {
		t.Errorf("revoke twice: %d", rec.Code)
	}
	_, out = owner.do(http.MethodGet, base, nil)
	if g := out["guests"].([]any)[0].(map[string]any); g["active"] != false {
		t.Errorf("guest still active after revoke: %v", g)
	}
}
