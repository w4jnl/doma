// domaload is the load check from docs/design.md (Testing): many devices syncing against one
// doma every few seconds, each adding an entry now and then, with the sync latency measured
// at the client and every event checked to have reached every device. Acceptance: p99 under
// 50 ms and no event lost. It joins through one owner invite, mints a member invite per device
// through the API, and leaves the household full of load members, so it is for a throwaway
// server (make run), never the family's.
//
//	domaload -server http://127.0.0.1:8080 -invite https://.../i/<token> [-devices 200] [-every 5s] [-for 2m] [-adds 20s]
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/w4jnl/doma/internal/client"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "domaload:", err)
		os.Exit(1)
	}
}

type device struct {
	*client.Client
	n      int
	clock  *domain.Clock
	since  int64
	sent   map[string]bool
	seen   map[string]bool
	lastAt time.Time
}

type config struct {
	server, invite string
	devices        int
	every, dur     time.Duration
	adds           time.Duration
}

func run() error {
	var c config
	flag.StringVar(&c.server, "server", "http://127.0.0.1:8080", "the doma to load")
	flag.StringVar(&c.invite, "invite", "", "an owner invite, as link or token, from /admin/h/<id>/invite")
	flag.IntVar(&c.devices, "devices", 200, "how many devices sync")
	flag.DurationVar(&c.every, "every", 5*time.Second, "how often each device syncs")
	flag.DurationVar(&c.dur, "for", 2*time.Minute, "how long the load runs")
	flag.DurationVar(&c.adds, "adds", 20*time.Second, "how often each device adds an entry, on average")
	flag.Parse()
	if c.invite == "" {
		return errors.New("-invite is needed: make an owner invite on the admin page and pass its link")
	}
	token := c.invite
	if i := strings.LastIndex(token, "/i/"); i >= 0 {
		token = token[i+3:]
	}
	ctx := context.Background()
	httpClient := &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{MaxIdleConnsPerHost: c.devices, MaxConnsPerHost: 0}}

	// the owner, then a member invite per device
	fmt.Printf("joining %d devices\n", c.devices)
	devices := make([]*device, 0, c.devices)
	owner, err := newDevice(ctx, c.server, httpClient, 0, token)
	if err != nil {
		return fmt.Errorf("owner: %w", err)
	}
	household := owner.household
	devices = append(devices, owner.device)
	// the owner mints five a second: inside the REST limit of one device (300 a minute, a
	// burst of 60), and never two in one millisecond, which on a fast loopback they otherwise
	// do and which the server takes for a replay of one signature
	for n := 1; n < c.devices; n++ {
		time.Sleep(200 * time.Millisecond)
		var inv struct {
			URL string `json:"url"`
		}
		if err := owner.Do(ctx, http.MethodPost, "/api/v1/h/"+household+"/invites", map[string]string{"role": "member"}, &inv); err != nil {
			return fmt.Errorf("invite %d: %w", n, err)
		}
		d, err := newDevice(ctx, c.server, httpClient, n, inv.URL[strings.LastIndex(inv.URL, "/i/")+3:])
		if err != nil {
			return fmt.Errorf("device %d: %w", n, err)
		}
		devices = append(devices, d.device)
	}

	// the default list, from the household's first events
	var listID string
	res, _, err := owner.sync(ctx, household, nil)
	if err != nil {
		return fmt.Errorf("first sync: %w", err)
	}
	for _, e := range res.Events {
		if e.Kind == "list.created" {
			var p struct {
				ListID  string `json:"list_id"`
				Default bool   `json:"default"`
			}
			if json.Unmarshal(e.Payload, &p) == nil && (p.Default || listID == "") {
				listID = p.ListID
			}
		}
	}
	if listID == "" {
		return errors.New("the household has no list")
	}

	// the load: every device on its own ticker, offset so they do not all fire together
	fmt.Printf("syncing every %s for %s, an add about every %s per device\n", c.every, c.dur, c.adds)
	var mu sync.Mutex
	var latencies []time.Duration
	var failures int
	var wg sync.WaitGroup
	deadline := time.Now().Add(c.dur)
	for _, d := range devices {
		wg.Add(1)
		go func(d *device) {
			defer wg.Done()
			time.Sleep(time.Duration(rand.Int64N(int64(c.every)))) //nolint:gosec // G404: spreading the devices, not a secret
			for time.Now().Before(deadline) {
				var evs []json.RawMessage
				if rand.Float64() < float64(c.every)/float64(c.adds) { //nolint:gosec // G404: who adds when, not a secret
					item := domain.NewID()
					evs = append(evs,
						d.event("item.named", map[string]any{"item_id": item, "name": fmt.Sprintf("item %d %s", d.n, item[len(item)-4:])}),
						d.event("entry.added", map[string]any{"list_id": listID, "item_id": item}))
				}
				start := time.Now()
				_, ids, err := d.sync(ctx, household, evs)
				took := time.Since(start)
				mu.Lock()
				if err != nil {
					failures++
				} else {
					latencies = append(latencies, took)
					for _, id := range ids {
						d.sent[id] = true
					}
				}
				mu.Unlock()
				time.Sleep(c.every)
			}
		}(d)
	}
	wg.Wait()

	// then each device pulls to the head, a page at a time, so every one has had the chance
	// to see everything
	for _, d := range devices {
		for range 100 {
			res, _, err := d.sync(ctx, household, nil)
			if err != nil {
				failures++
				break
			}
			if len(res.Events) == 0 {
				break
			}
		}
	}
	all := map[string]bool{}
	for _, d := range devices {
		for id := range d.sent {
			all[id] = true
		}
	}
	lost := 0
	for _, d := range devices {
		for id := range all {
			if !d.seen[id] {
				lost++
			}
		}
	}

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	pct := func(p float64) time.Duration {
		if len(latencies) == 0 {
			return 0
		}
		i := int(p * float64(len(latencies)-1))
		return latencies[i]
	}
	fmt.Printf("syncs %d, failed %d, events sent %d\n", len(latencies), failures, len(all))
	fmt.Printf("latency p50 %s, p95 %s, p99 %s, max %s\n", pct(0.50).Round(time.Millisecond), pct(0.95).Round(time.Millisecond), pct(0.99).Round(time.Millisecond), pct(1).Round(time.Millisecond))
	fmt.Printf("events missing on some device: %d\n", lost)
	serverSide(ctx, httpClient, c.server)
	ok := pct(0.99) < 50*time.Millisecond && lost == 0 && failures == 0
	if ok {
		fmt.Println("ok: p99 under 50 ms, nothing lost")
		return nil
	}
	return errors.New("not within the acceptance (p99 under 50 ms, no failure, nothing lost)")
}

// serverSide prints what the server measured itself, when /metrics is open: the sync and the
// database write durations, so a slow tail can be told apart as the server's or the way to it.
func serverSide(ctx context.Context, httpClient *http.Client, server string) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(server, "/")+"/metrics", nil)
	if err != nil {
		return
	}
	resp, err := httpClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			_ = resp.Body.Close()
		}
		fmt.Println("server side: /metrics not open, no server durations")
		return
	}
	defer func() { _ = resp.Body.Close() }()
	var body strings.Builder
	if _, err := io.Copy(&body, resp.Body); err != nil {
		return
	}
	for _, name := range []string{"doma_sync_duration_seconds", "doma_db_write_duration_seconds"} {
		type bucket struct {
			le    float64
			count float64
		}
		var buckets []bucket
		var total float64
		for _, line := range strings.Split(body.String(), "\n") {
			if !strings.HasPrefix(line, name+"_bucket") {
				continue
			}
			i := strings.Index(line, `le="`)
			j := strings.Index(line[i+4:], `"`)
			if i < 0 || j < 0 {
				continue
			}
			le, err1 := strconv.ParseFloat(line[i+4:i+4+j], 64)
			n, err2 := strconv.ParseFloat(strings.TrimSpace(line[strings.LastIndex(line, " ")+1:]), 64)
			if err1 != nil || err2 != nil {
				continue
			}
			buckets = append(buckets, bucket{le, n})
			if le > total {
				total = n // the +Inf bucket parses as the largest le and holds the total
			}
		}
		sort.Slice(buckets, func(i, j int) bool { return buckets[i].le < buckets[j].le })
		if len(buckets) == 0 || total == 0 {
			fmt.Printf("server side: no %s samples\n", name)
			continue
		}
		total = buckets[len(buckets)-1].count
		at := func(q float64) string {
			for _, b := range buckets {
				if b.count >= q*total {
					if math.IsInf(b.le, 1) {
						return "over the last bucket"
					}
					return "under " + (time.Duration(b.le * float64(time.Second))).String()
				}
			}
			return "?"
		}
		fmt.Printf("server side: %s p50 %s, p95 %s, p99 %s (%d samples)\n", name, at(0.5), at(0.95), at(0.99), int(total))
	}
}

type joined struct {
	*device
	household string
}

// fromAddress gives a device an address of its own in X-Forwarded-For, as 200 phones would
// come from 200 places; the throwaway server trusts the loopback as a proxy (make load sets
// that), so its per-address limits, ten invite accepts a minute among them, see 200 clients.
type fromAddress struct {
	rt http.RoundTripper
	ip string
}

func (f fromAddress) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("X-Forwarded-For", f.ip)
	return f.rt.RoundTrip(r)
}

func newDevice(ctx context.Context, server string, httpClient *http.Client, n int, token string) (*joined, error) {
	own := *httpClient
	own.Transport = fromAddress{rt: httpClient.Transport, ip: fmt.Sprintf("10.%d.%d.%d", (n>>16)&255, (n>>8)&255, n&255)}
	c, err := client.New(server, &own)
	if err != nil {
		return nil, err
	}
	acc, err := c.Accept(ctx, token, fmt.Sprintf("Load %d", n), fmt.Sprintf("load-%d", n))
	if err != nil {
		return nil, err
	}
	clock, err := domain.NewClock(acc.CredentialID, nil)
	if err != nil {
		return nil, err
	}
	return &joined{device: &device{Client: c, n: n, clock: clock, sent: map[string]bool{}, seen: map[string]bool{}}, household: acc.Household.ID}, nil
}

func (d *device) event(kind string, payload map[string]any) json.RawMessage {
	raw, _ := json.Marshal(map[string]any{"id": domain.NewID(), "hlc": d.clock.Next().String(), "kind": kind, "payload": payload})
	return raw
}

// sync sends evs and pulls what is new, moving the cursor; it returns the server's answer and
// the ids of the events it accepted, and remembers every event id it has seen.
func (d *device) sync(ctx context.Context, household string, evs []json.RawMessage) (service.SyncHouseholdResult, []string, error) {
	var resp service.SyncResponse
	err := d.Sync(ctx, service.SyncRequest{Households: []service.SyncHousehold{{ID: household, Since: d.since, Events: evs}}}, &resp)
	if err != nil || len(resp.Households) == 0 {
		if err == nil {
			err = errors.New("empty answer")
		}
		return service.SyncHouseholdResult{}, nil, err
	}
	res := resp.Households[0]
	d.since = res.Next
	for _, e := range res.Events {
		d.seen[e.ID] = true
		if h, err := domain.ParseHLC(e.HLC); err == nil {
			d.clock.Observe(h)
		}
	}
	for _, id := range res.Accepted {
		d.seen[id] = true
	}
	d.lastAt = time.Now()
	return res, res.Accepted, nil
}
