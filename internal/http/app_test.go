package http_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"regexp"
	"strings"
	"testing"
)

// The web client: a browser signed in by the phone, then by a passkey, reading
// and writing the family's lists, and seeing nothing of another household or
// of another member's personal list.

// browser is one browser with its cookies, which never follows a redirect.
type browser struct {
	t    *testing.T
	base string
	c    *http.Client
}

func newBrowser(t *testing.T, base string) *browser {
	t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	return &browser{t: t, base: base, c: &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

// reply is what a browser call gives back: the status, the headers and the body, closed.
type reply struct {
	StatusCode int
	Header     http.Header
}

func (b *browser) do(method, path string, body io.Reader, headers map[string]string) (reply, string) {
	b.t.Helper()
	req, err := http.NewRequest(method, b.base+path, body)
	if err != nil {
		b.t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := b.c.Do(req)
	if err != nil {
		b.t.Fatal(err)
	}
	raw, _ := io.ReadAll(res.Body)
	_ = res.Body.Close()
	return reply{StatusCode: res.StatusCode, Header: res.Header}, string(raw)
}

func (b *browser) get(path string) (reply, string) {
	return b.do(http.MethodGet, path, nil, nil)
}

func (b *browser) form(path string, form url.Values) (reply, string) {
	return b.do(http.MethodPost, path, strings.NewReader(form.Encode()), map[string]string{"Content-Type": "application/x-www-form-urlencoded"})
}

func (b *browser) htmx(path string, csrf string, form url.Values) (reply, string) {
	return b.do(http.MethodPost, path, strings.NewReader(form.Encode()), map[string]string{"Content-Type": "application/x-www-form-urlencoded", "HX-Request": "true", "X-CSRF-Token": csrf})
}

var (
	vouchLink = regexp.MustCompile(`/app/v/([A-Za-z0-9_-]+)`)
	csrfMeta  = regexp.MustCompile(`<meta name="csrf" content="([^"]+)"`)
)

// signInByPhone shows the code to the phone client, which vouches, and
// returns the browser signed in with its CSRF token.
func signInByPhone(t *testing.T, s *suite, phone interface {
	Do(ctx context.Context, method, path string, body, out any) error
}) (*browser, string) {
	t.Helper()
	b := newBrowser(t, s.srv.URL)
	res, body := b.get("/app")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET /app: %d", res.StatusCode)
	}
	m := vouchLink.FindStringSubmatch(body)
	if m == nil {
		t.Fatalf("no code on the sign-in page: %s", body)
	}
	token := m[1]
	if res, _ := b.get("/app/wait/" + token); res.StatusCode != http.StatusNoContent {
		t.Fatalf("waiting: %d", res.StatusCode)
	}
	if err := phone.Do(context.Background(), http.MethodPost, "/api/v1/vouch", map[string]string{"token": token}, nil); err != nil {
		t.Fatalf("vouch: %v", err)
	}
	res, _ = b.get("/app/wait/" + token)
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/app" {
		t.Fatalf("after the vouch: %d to %q", res.StatusCode, res.Header.Get("Location"))
	}
	res, _ = b.get("/app")
	if res.StatusCode != http.StatusSeeOther || !strings.HasSuffix(res.Header.Get("Location"), "/lists") {
		t.Fatalf("/app signed in: %d to %q", res.StatusCode, res.Header.Get("Location"))
	}
	_, body = b.get(res.Header.Get("Location"))
	cm := csrfMeta.FindStringSubmatch(body)
	if cm == nil {
		t.Fatal("no csrf meta on the lists page")
	}
	return b, cm[1]
}

func TestWebClientSignsInByThePhoneAndWorksTheLists(t *testing.T) {
	s := newSuite(t)
	// an unknown or used code is a 404 to the phone
	if err := s.a.owner.Do(context.Background(), http.MethodPost, "/api/v1/vouch", map[string]string{"token": "nope"}, nil); status(err) != http.StatusNotFound {
		t.Errorf("vouch with a strange code: %v", err)
	}
	b, csrf := signInByPhone(t, s, s.a.owner)
	lists := "/app/h/" + s.a.id + "/lists"
	res, body := b.get(lists)
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "Household") {
		t.Fatalf("lists page: %d", res.StatusCode)
	}
	if !strings.Contains(body, "Add a passkey") {
		t.Errorf("a browser signed in by the phone is offered a passkey")
	}
	// the other household is a 404, as everywhere
	if res, _ := b.get("/app/h/" + s.b.id + "/lists"); res.StatusCode != http.StatusNotFound {
		t.Errorf("another household's lists: %d", res.StatusCode)
	}
	// a form without the token is refused
	if res, _ := b.form(lists, url.Values{"name": {"Weekend"}}); res.StatusCode != http.StatusForbidden {
		t.Errorf("create without csrf: %d", res.StatusCode)
	}
	// a new tasks list, then a personal one
	res, _ = b.form(lists, url.Values{"_csrf": {csrf}, "name": {"Chores"}, "who": {"household"}, "what": {"tasks"}})
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("create list: %d", res.StatusCode)
	}
	chores := res.Header.Get("Location")
	res, _ = b.form(lists, url.Values{"_csrf": {csrf}, "name": {"Secret"}, "who": {"me"}, "what": {"shopping"}})
	secret := res.Header.Get("Location")
	_, body = b.get(lists)
	if !strings.Contains(body, "Chores") || !strings.Contains(body, "Secret") || !strings.Contains(body, "tasks") {
		t.Errorf("the overview lacks the new lists: %s", body)
	}
	// the list page: add, strike, not needed, clear; htmx answers with the fragment
	res, body = b.htmx(chores+"/add", csrf, url.Values{"text": {"stofzuigen"}})
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "stofzuigen") || !strings.Contains(body, `id="panel"`) {
		t.Fatalf("add: %d %s", res.StatusCode, body)
	}
	res, body = b.htmx(chores+"/add", csrf, url.Values{"text": {"planten water geven"}})
	if !strings.Contains(body, "2 to do") && !strings.Contains(body, "planten") {
		t.Errorf("second add: %s", body)
	}
	_, body = b.get(chores)
	if !strings.Contains(body, "2 to do") {
		t.Errorf("a tasks list speaks of doing: %s", body)
	}
	var ids []string
	for _, m := range regexp.MustCompile(`/check/([A-Za-z0-9]+)`).FindAllStringSubmatch(body, -1) {
		if len(ids) == 0 || ids[len(ids)-1] != m[1] {
			ids = append(ids, m[1])
		}
	}
	if len(ids) != 2 {
		t.Fatalf("two rows, got %d: %v", len(ids), ids)
	}
	res, body = b.htmx(chores+"/check/"+ids[0], csrf, nil)
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "1 done") || !strings.Contains(body, "Clear") {
		t.Errorf("strike: %d %s", res.StatusCode, body)
	}
	res, body = b.htmx(chores+"/remove/"+ids[1], csrf, nil)
	if res.StatusCode != http.StatusOK || strings.Contains(body, "Not needed") {
		t.Errorf("not needed: %d %s", res.StatusCode, body)
	}
	res, body = b.htmx(chores+"/clear", csrf, nil)
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "Nothing to do") {
		t.Errorf("clear: %d %s", res.StatusCode, body)
	}
	// the polled fragment answers 304 to its own ETag
	res, _ = b.get(chores + "/rows")
	etag := res.Header.Get("ETag")
	res2, _ := b.do(http.MethodGet, chores+"/rows", nil, map[string]string{"If-None-Match": etag})
	if etag == "" || res2.StatusCode != http.StatusNotModified {
		t.Errorf("rows etag %q: %d", etag, res2.StatusCode)
	}
	// the member of the same household sees the shared list and not the personal one
	m, _ := signInByPhone(t, s, s.a.member)
	if res, _ := m.get(chores); res.StatusCode != http.StatusOK {
		t.Errorf("member opens the shared list: %d", res.StatusCode)
	}
	if res, _ := m.get(secret); res.StatusCode != http.StatusNotFound {
		t.Errorf("member opens the owner's personal list: %d", res.StatusCode)
	}
	if res, _ := m.htmx(secret+"/add", csrf, url.Values{"text": {"x"}}); res.StatusCode == http.StatusOK {
		t.Errorf("member adds to the owner's personal list: %d", res.StatusCode)
	}
	// sign out ends the session
	res, _ = b.form("/app/signout", url.Values{"_csrf": {csrf}})
	if res.StatusCode != http.StatusSeeOther {
		t.Errorf("sign out: %d", res.StatusCode)
	}
	if res, _ := b.get(lists); res.StatusCode != http.StatusSeeOther {
		t.Errorf("after sign out: %d", res.StatusCode)
	}
}

// fakeAuthenticator is a browser's passkey: one P-256 key that answers the
// two ceremonies the way a platform authenticator does, with no attestation.
type fakeAuthenticator struct {
	key    *ecdsa.PrivateKey
	credID []byte
	count  uint32
	rpID   string
	origin string
}

func newFakeAuthenticator(t *testing.T, origin string) *fakeAuthenticator {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(origin)
	id := make([]byte, 16)
	_, _ = rand.Read(id)
	return &fakeAuthenticator{key: key, credID: id, rpID: u.Hostname(), origin: origin}
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// cbor writes the little CBOR this needs: unsigned and negative ints, byte
// and text strings, and maps with a known number of pairs.
func cborHead(major byte, n uint64) []byte {
	switch {
	case n < 24:
		return []byte{major<<5 | byte(n)}
	case n < 256:
		return []byte{major<<5 | 24, byte(n)}
	default:
		return []byte{major<<5 | 25, byte(n >> 8), byte(n)}
	}
}

func cborInt(i int64) []byte {
	if i >= 0 {
		return cborHead(0, uint64(i))
	}
	return cborHead(1, uint64(-1-i))
}

func cborBytes(b []byte) []byte { return append(cborHead(2, uint64(len(b))), b...) }
func cborText(s string) []byte  { return append(cborHead(3, uint64(len(s))), s...) }

func (f *fakeAuthenticator) coseKey() []byte {
	point, _ := f.key.PublicKey.Bytes() // 0x04, x, y
	x, y := point[1:33], point[33:65]
	var b bytes.Buffer
	b.Write(cborHead(5, 5))
	b.Write(cborInt(1))
	b.Write(cborInt(2)) // kty EC2
	b.Write(cborInt(3))
	b.Write(cborInt(-7)) // alg ES256
	b.Write(cborInt(-1))
	b.Write(cborInt(1)) // crv P-256
	b.Write(cborInt(-2))
	b.Write(cborBytes(x))
	b.Write(cborInt(-3))
	b.Write(cborBytes(y))
	return b.Bytes()
}

func (f *fakeAuthenticator) authData(flags byte, withKey bool) []byte {
	h := sha256.Sum256([]byte(f.rpID))
	var b bytes.Buffer
	b.Write(h[:])
	b.WriteByte(flags)
	f.count++
	_ = binary.Write(&b, binary.BigEndian, f.count)
	if withKey {
		b.Write(make([]byte, 16)) // aaguid
		_ = binary.Write(&b, binary.BigEndian, uint16(len(f.credID)))
		b.Write(f.credID)
		b.Write(f.coseKey())
	}
	return b.Bytes()
}

func (f *fakeAuthenticator) clientData(typ, challenge string) []byte {
	raw, _ := json.Marshal(map[string]any{"type": typ, "challenge": challenge, "origin": f.origin})
	return raw
}

// create answers navigator.credentials.create for the options the server sent.
func (f *fakeAuthenticator) create(options []byte) []byte {
	var opts struct {
		PublicKey struct {
			Challenge string `json:"challenge"`
		} `json:"publicKey"`
	}
	_ = json.Unmarshal(options, &opts)
	auth := f.authData(0x45, true) // UP, UV, AT
	var att bytes.Buffer
	att.Write(cborHead(5, 3))
	att.Write(cborText("fmt"))
	att.Write(cborText("none"))
	att.Write(cborText("attStmt"))
	att.Write(cborHead(5, 0))
	att.Write(cborText("authData"))
	att.Write(cborBytes(auth))
	raw, _ := json.Marshal(map[string]any{
		"id": b64(f.credID), "rawId": b64(f.credID), "type": "public-key",
		"response":               map[string]any{"clientDataJSON": b64(f.clientData("webauthn.create", opts.PublicKey.Challenge)), "attestationObject": b64(att.Bytes())},
		"clientExtensionResults": map[string]any{},
	})
	return raw
}

// get answers navigator.credentials.get, signing as the user handle says.
func (f *fakeAuthenticator) get(options []byte, userHandle string) []byte {
	var opts struct {
		PublicKey struct {
			Challenge string `json:"challenge"`
		} `json:"publicKey"`
	}
	_ = json.Unmarshal(options, &opts)
	auth := f.authData(0x05, false) // UP, UV
	cd := f.clientData("webauthn.get", opts.PublicKey.Challenge)
	cdh := sha256.Sum256(cd)
	digest := sha256.Sum256(append(append([]byte{}, auth...), cdh[:]...))
	sig, _ := ecdsa.SignASN1(rand.Reader, f.key, digest[:])
	raw, _ := json.Marshal(map[string]any{
		"id": b64(f.credID), "rawId": b64(f.credID), "type": "public-key",
		"response":               map[string]any{"clientDataJSON": b64(cd), "authenticatorData": b64(auth), "signature": b64(sig), "userHandle": b64([]byte(userHandle))},
		"clientExtensionResults": map[string]any{},
	})
	return raw
}

func TestWebClientPasskeyRegistersAndSignsIn(t *testing.T) {
	s := newSuite(t)
	b, csrf := signInByPhone(t, s, s.a.owner)
	authn := newFakeAuthenticator(t, s.srv.URL)
	// the server's base URL is doma.test; the browser speaks to the test server by address,
	// so the authenticator answers for the origin the server was told
	authn.origin = "http://doma.test"
	authn.rpID = "doma.test"

	// register: begin, answer, finish
	res, options := b.get("/app/passkey/register/begin")
	if res.StatusCode != http.StatusOK || !strings.Contains(options, `"challenge"`) {
		t.Fatalf("register begin: %d %s", res.StatusCode, options)
	}
	res, body := b.do(http.MethodPost, "/app/passkey/register/finish", bytes.NewReader(authn.create([]byte(options))), map[string]string{"Content-Type": "application/json", "X-CSRF-Token": csrf, "User-Agent": "Mozilla/5.0 (Macintosh) Safari/605"})
	if res.StatusCode != http.StatusOK {
		t.Fatalf("register finish: %d %s", res.StatusCode, body)
	}
	// the passkey is one of the person's credentials now, named after the browser
	var me struct {
		Credentials []struct {
			Kind, Label, Platform string
		} `json:"credentials"`
	}
	if err := s.a.owner.Get(context.Background(), "/api/v1/me", &me); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range me.Credentials {
		if c.Kind == "passkey" {
			found = true
			if c.Label != "Safari on Mac" || c.Platform != "web" {
				t.Errorf("passkey credential: %+v", c)
			}
		}
	}
	if !found {
		t.Fatalf("no passkey among the credentials: %+v", me.Credentials)
	}
	// the offer is gone from the lists page
	if _, body := b.get("/app/h/" + s.a.id + "/lists"); strings.Contains(body, "Add a passkey") {
		t.Errorf("a browser with a passkey is still offered one")
	}
	// a fresh browser signs in with the passkey alone
	fresh := newBrowser(t, s.srv.URL)
	res, options = fresh.get("/app/passkey/login/begin")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("login begin: %d %s", res.StatusCode, options)
	}
	res, body = fresh.do(http.MethodPost, "/app/passkey/login/finish", bytes.NewReader(authn.get([]byte(options), s.a.owner.PersonID)), map[string]string{"Content-Type": "application/json"})
	if res.StatusCode != http.StatusOK || !strings.Contains(body, `"/app"`) {
		t.Fatalf("login finish: %d %s", res.StatusCode, body)
	}
	if res, _ := fresh.get("/app"); res.StatusCode != http.StatusSeeOther || !strings.Contains(res.Header.Get("Location"), s.a.id) {
		t.Errorf("signed in by the passkey: %d to %q", res.StatusCode, res.Header.Get("Location"))
	}
	// a replayed assertion with an old count, or a strange key, is refused
	res, options = fresh.get("/app/passkey/login/begin")
	stranger := newFakeAuthenticator(t, "http://doma.test")
	stranger.credID = authn.credID
	res, body = fresh.do(http.MethodPost, "/app/passkey/login/finish", bytes.NewReader(stranger.get([]byte(options), s.a.owner.PersonID)), map[string]string{"Content-Type": "application/json"})
	if res.StatusCode != http.StatusUnauthorized {
		t.Errorf("a stranger's key with the passkey's id: %d %s", res.StatusCode, body)
	}
	// a finish without a begin
	res, _ = fresh.do(http.MethodPost, "/app/passkey/login/finish", bytes.NewReader(authn.get([]byte(options), s.a.owner.PersonID)), map[string]string{"Content-Type": "application/json"})
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("finish without a ceremony: %d", res.StatusCode)
	}
}

func TestWebClientHomesTripsAndFamily(t *testing.T) {
	s := newSuite(t)
	b, csrf := signInByPhone(t, s, s.a.owner)
	base := "/app/h/" + s.a.id
	// homes: the first home is there; a second one is made
	res, body := b.get(base + "/homes")
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "Home") {
		t.Fatalf("homes: %d", res.StatusCode)
	}
	res, _ = b.form(base+"/homes", url.Values{"_csrf": {csrf}, "name": {"Hut"}})
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("create home: %d", res.StatusCode)
	}
	hut := res.Header.Get("Location")
	hutID := hut[strings.LastIndex(hut, "/")+1:]
	// a staple at the hut, flagged out: the home page says so and the default list gets it
	res, _ = b.form(hut+"/staples", url.Values{"_csrf": {csrf}, "text": {"melk"}})
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("add staple: %d", res.StatusCode)
	}
	_, body = b.get(hut)
	ids := regexp.MustCompile(`/flag/([A-Za-z0-9]+)`).FindStringSubmatch(body)
	if ids == nil || !strings.Contains(body, "melk") {
		t.Fatalf("the staple is not on the home page: %s", body)
	}
	melk := ids[1]
	if res, _ := b.form(hut+"/flag/"+melk, url.Values{"_csrf": {csrf}, "state": {"out"}}); res.StatusCode != http.StatusSeeOther {
		t.Fatalf("flag out: %d", res.StatusCode)
	}
	_, body = b.get(hut)
	if !strings.Contains(body, `dm-flag-out`) || !strings.Contains(body, "1 out") && !strings.Contains(body, ">out<") {
		t.Errorf("the flag does not read out: %s", body)
	}
	if _, body := b.get(base + "/l/" + s.a.list); !strings.Contains(body, "melk") {
		t.Errorf("out did not put melk on the default list")
	}
	// a trip from Home to the hut: melk is to buy, since Home has no flag for it; Arrived closes it
	res, body = b.get(base + "/trips")
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "Plan a trip") {
		t.Fatalf("trips: %d %s", res.StatusCode, body)
	}
	res, _ = b.form(base+"/trips", url.Values{"_csrf": {csrf}, "from": {s.a.home}, "to": {hutID}, "date": {"2026-11-08"}, "list": {s.a.list}})
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("plan: %d", res.StatusCode)
	}
	trip := res.Header.Get("Location")
	_, body = b.get(trip)
	if !strings.Contains(body, "Buy") || !strings.Contains(body, "melk") || !strings.Contains(body, "on the list") {
		t.Errorf("the plan lacks melk to buy, on the list already: %s", body)
	}
	if res, _ := b.form(base+"/trips", url.Values{"_csrf": {csrf}, "from": {s.a.home}, "to": {s.a.home}, "date": {"2026-11-08"}}); res.StatusCode != http.StatusUnprocessableEntity {
		t.Errorf("a trip to the same home: %d", res.StatusCode)
	}
	if res, _ := b.form(trip+"/arrived", url.Values{"_csrf": {csrf}}); res.StatusCode != http.StatusSeeOther {
		t.Errorf("arrived: %d", res.StatusCode)
	}
	if _, body := b.get(base + "/trips"); !strings.Contains(body, "Past") || !strings.Contains(body, "arrived") {
		t.Errorf("the trip is not among the past ones: %s", body)
	}
	if res, _ := b.form(trip+"/arrived", url.Values{"_csrf": {csrf}}); res.StatusCode != http.StatusConflict {
		t.Errorf("arriving twice: %d", res.StatusCode)
	}
	// family: members, an invite with its QR, a guest link, the devices
	res, body = b.get(base + "/family")
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "Family A owner") || !strings.Contains(body, "Family A member") || !strings.Contains(body, "Your devices") {
		t.Fatalf("family: %d %s", res.StatusCode, body)
	}
	res, body = b.form(base+"/family/invite", url.Values{"_csrf": {csrf}, "role": {"member"}})
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "/i/") || !strings.Contains(body, "<svg") {
		t.Errorf("invite: %d %s", res.StatusCode, body)
	}
	res, body = b.form(base+"/family/guests", url.Values{"_csrf": {csrf}, "label": {"cleaner web"}, "home": {s.a.home}, "list": {s.a.list}, "days": {"7"}})
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "/g/") {
		t.Errorf("guest link: %d %s", res.StatusCode, body)
	}
	_, body = b.get(base + "/family")
	if !strings.Contains(body, "cleaner web") || !strings.Contains(body, "member invite") {
		t.Errorf("the family page lacks the new link or invite: %s", body)
	}
	// a member sees no invite form and may not invite
	m, mcsrf := signInByPhone(t, s, s.a.member)
	if _, body := m.get(base + "/family"); strings.Contains(body, "Make a link") || strings.Contains(body, `name="role"`) {
		t.Errorf("a member is offered the owner's forms")
	}
	if res, _ := m.form(base+"/family/invite", url.Values{"_csrf": {mcsrf}, "role": {"member"}}); res.StatusCode != http.StatusForbidden {
		t.Errorf("a member invites: %d", res.StatusCode)
	}
	// the other household's pages are 404 here too
	for _, p := range []string{"/homes", "/trips", "/family"} {
		if res, _ := b.get("/app/h/" + s.b.id + p); res.StatusCode != http.StatusNotFound {
			t.Errorf("household B %s: %d", p, res.StatusCode)
		}
	}
}
