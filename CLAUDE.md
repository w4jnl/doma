# doma

The family's household app: shared and personal shopping lists, what is at each home, and what
to bring from one home to the other. One cgo-free Go binary (`doma serve`) with an append-only
event log per household, server-rendered guest and admin pages, and a sync endpoint for the native
iPhone and Mac apps under `app/`. Sibling of github.com/w4jnl/flok, github.com/w4jnl/vink and
github.com/w4jnl/nt; vink is the structural baseline for the server and nt for the apps.

## Read first
- `docs/design.md` is the spec: purpose, onboarding and roles, architecture, data model and
  tenancy, the event log and the fold, lists, homes and trips, the apps, the web pages, the API,
  security, configuration, testing, phases and open decisions. It is the source of truth; ask
  before deviating from it. Its drawings are in `docs/diagrams/`.
- `docs/design-system/README.md` is the brand and UI rules; `tokens.json` holds every colour,
  glyph and size and `tokens.py` writes `tokens.css` from it. The apps mirror it in
  `app/shared/Design/Tokens.swift` with a test that fails on drift.
- `assets/brand/` holds the marks, lockups, tiles and banners; `gen.py` regenerates the SVGs from
  one geometry and `render.py` the PNGs. `assets/icons/gen.py` writes the pictograms and the
  sprite the web pages inline.
- `docs/dev/kickoff.md` holds the prompts, one per phase and platform: prompt 0 is the server's
  phase 0 in seven steps, prompt 1 the apps. Their step order is the build order; later phases get
  a prompt of the same shape when the previous gate is met.

## State of the tree (update this when it changes)
- The server's phase 0 is in, steps 1 to 7: the module, `doma serve` with config and logging, the Makefile,
  CI, goreleaser and the gate scripts; the schema, sqlc queries, the fold with
  `docs/fixtures/fold.json`, the SQL store under `internal/foldsql` and the event schema with its
  validator; identity in `internal/auth` (device-key signatures, admin sessions, argon2id, the proxy's
  sign-in behind `admin.auth = "proxy"`),
  `internal/service` (setup, households, members, devices, invites), the REST API under
  `internal/http/api` with `openapi.yaml`, and the first pages under `internal/http/web` (setup,
  admin login, households with the owner invite QR, the invite page); the sync path: `POST
  /sync/v1` and the snapshot download in `internal/http/sync`, the exchange, the nightly snapshot
  and retention job and the export zip in `internal/service`, the bus, the Prometheus collectors
  and the Go client under `internal/client` that tests and the e2e smoke drive; push in
  `internal/push` (APNs with token auth, one silent push per device per 30 s, built only when
  `push.enabled`) with the key sealed at rest by `internal/secrets`; the web pages: the admin's
  households, household and server pages (APNs key upload, back up now, log level, TOTP), the
  guest links and the guest view polled with vendored htmx 2.0.4; the cross-tenant and
  cross-person suite in `internal/http/crosstenant_test.go`, the e2e smoke under `scripts/e2e`
  and the README. The apps under `app/` are through step 5 of prompt 1: the two XcodeGen projects
  (`app/ios`, `app/macos`) over `app/shared`, GRDB pinned, `Design/Tokens.swift` with its drift
  test, the custom symbols in `Design/Symbols.xcassets` written by `assets/icons/gen.py`, the
  `mac-*` and `ios-*` make targets; DomaKit: `Model` (HLC, ULID, the name key, the typed line,
  events and rows), `Fold` (the port, `MemStore`, tested against the fixture in every order),
  `Store` (GRDB schema, `SQLFoldStore`, `DomaStore` with log, outbox, cursor and snapshot import),
  `Identity` (`DeviceKey` in the Keychain, `InviteLink`, `Session` with one context per server
  and the household in front chosen across them), `Sync` (`SyncClient` with
  the signature, `Syncer` with the triggers, `Background` for the phone's refresh and push),
  `Voice` (speech to words on the device in English, Dutch and Slovak, nt's Listener, and the mic
  in the add bar; `make voice` checks the three languages on the Mac);
  the screens under `Views` (Scan, Lists, List, Family, Settings, the Mac split view) over
  `Store/Queries.swift` (what they read, live through GRDB observation) and
  `Store/ListActions.swift` (what they write, as events), with one string catalogue in English,
  Dutch and Slovak; the UI tests in `app/ios/DomaUITests` against the throwaway server
  `scripts/ui-test.sh` starts, the snapshot tests in `app/shared/Tests/SnapshotTests.swift` with
  their pictures under `Snapshots/`, and the hooks they use in `Identity/UITestHooks.swift`; the
  TestFlight path (`make ios-testflight`, the push entitlement, `app/ios/README.md`), which
  waits for the team id and the App Store Connect record. Phase 1 on the server: photos under
  `internal/photo` (decode, re-encode, scale, thumbnail) and `internal/http/photos` (the upload
  for an accepted `photo.added`, the picture and its thumbnail for a member's signed request or
  a link the server signs for an hour), retention per spot, the quota before and after the
  body, the nightly reconcile from disk, photos in the export and the bytes on the admin pages.
  Not yet: Homes, Home and Trip in the apps, and the photo capture (phase 1, steps 4 to 6).
  Check `git log` and `ls` before assuming otherwise.
- The fold's one design choice beyond the spec: it is order-independent, not only deterministic
  in seq order. The catalog and each (list, item) key are replayed from the log in hlc order;
  flags are derived from all their candidates; everything else is last-writer-wins or add and
  remove maxima. `internal/fold/fold.go` says why, and the property test proves it. The Swift
  port adds one thing the server does not need: rows a snapshot brought without their events
  are replayed as the events that made them, at their own stamps (`app/shared/Fold/Fold.swift`).
- The package map to build to is "Architecture and repository layout" in `docs/design.md`; the
  tables are in "Data model and tenancy", the event kinds and fold rules in "Event log and sync",
  the task lists and the open-decisions table in "Testing, milestones, open decisions".

## How a change moves
A tap in an app writes one event to the local GRDB outbox and folds it locally in the same
transaction, so the screen updates before any network. `POST /sync/v1` carries the outbox up; the
server validates the payload against `docs/event-schema.json`, appends it to the household's log
with a server-assigned `seq`, folds it into the materialised tables in the same transaction, and
publishes `HouseholdChanged` on the in-process bus, which the push package coalesces into at most
one silent APNs push per device per 30 s. Other devices pull everything after their cursor, 500
events at a time, and fold the same events with the same rules; a device too far behind takes a
snapshot first. The four transports (sync, REST, web pages, APNs out) never touch the store: all
of them call one service layer that owns authorisation, transactions and the fold. Ordering is by
hybrid logical clock, never device wall time; ids are ULIDs; the materialised tables are a cache
the fold can rebuild from the log, and a test proves it.

## House conventions
- Go 1.23+, cgo-free, `internal/` packages, stdlib first. `net/http` ServeMux with method
  patterns; middleware as `func(http.Handler) http.Handler`. One subcommand, `serve`; no CLI for
  anyone else, the admin works in the browser.
- SQLite through `modernc.org/sqlite` in WAL mode with one writer; every query through `sqlc`
  from `internal/db/queries/*.sql`; migrations are embedded dbmate files applied at startup and
  `db/schema.sql` is dumped for sqlc. Every query on a household table has `WHERE household_id = ?`
  as its first predicate, and CI greps for it.
- `internal/fold` is the only code that writes materialised tables from events, pure and
  I/O-free, tested against `docs/fixtures/fold.json`; the Swift port in the apps loads the same
  fixture. A change to the fold is a change to the fixture first.
- `domain.Scope{HouseholdID, PersonID, Role}` is set once by auth middleware and travels in the
  context; every service method takes it first; handlers are thin and services own transactions.
- Web pages are `html/template` + vendored htmx 2.x, one hand-written CSS file over `tokens.css`,
  no inline styles (the CSP forbids them), no build step, no external URL anywhere.
- `log/slog`, JSON by default; `-d` switches to debug and `MatusOllah/slogcolor`. Config is
  `doma.toml` with `DOMA_*` overrides; secrets are never logged.
- Voice in docs, pages and messages: plain, direct, short sentences; no emoji, no exclamation
  marks; `doma` always lowercase. The family vocabulary only (household, home, spot, item, list,
  flag, trip, member, owner, guest, invite): never tenant, token, event, sync, server or credential
  on a page a family member sees. Flags are shown as glyph and word, never colour alone.
- Tests: table-driven, a temp SQLite file per test, no mocks of the DB. The cross-tenant and
  cross-person suites assert 404 across every boundary for sync, REST, photos and export.
- Apps (`app/ios`, `app/macos`, `app/shared`, nt's layout): Swift 6 with complete strict
  concurrency, SwiftUI, `@MainActor @Observable` state, Apple frameworks only; GRDB, pinned, is
  the one third-party dependency; XcodeGen `project.yml` per platform, `#if os` where they
  differ. Every screen reads the local GRDB store and writes the outbox; nothing waits on the
  network. The Swift fold under `app/shared/Fold` is a port of `internal/fold` and its test reads
  `docs/fixtures/fold.json` by path. Colours, glyphs and sizes come only from
  `app/shared/Design/Tokens.swift`; UI words in the system face through Dynamic Type, JetBrains
  Mono for data only; SF Symbols wherever Apple's shape says the same thing, the custom symbols
  from `assets/icons/`. Four tabs, no modals except the camera and the share sheet. The apps make
  no network call except to the configured server.

## Rules
- Build one phase at a time (`docs/design.md`, Testing, milestones, open decisions) and stop at
  its gate for review. Phase 0 first, server before apps; do not start homes and trips before the
  family's shared list has run on doma.
- Take the defaults in the open-decisions table unless overruled; do not add tables, events,
  screens, pages, colours or config keys beyond the spec and the design system without asking.
  Simplicity is the main requirement.
- Never make an outbound network call other than APNs, and none at all when `push.enabled` is
  false. No telemetry, no update check, no CDN.
- `main` takes pull requests only: work on a branch, open a PR, and CI must pass before it merges.
- Before calling a task done: `gofmt -l ./cmd ./internal` is empty, `make vet`, `make lint` and
  `make test` pass, and `make e2e` passes after any change to the sync path or the fold; after a
  change under `app/`, `make mac-test` and `make ios-test` pass and the snapshots are updated in
  light and dark.

## Commands
- `make build`: `bin/doma` with the version stamped from git.
- `make run`: `doma serve -d` on a throwaway data directory with a config under `tmp/`.
- `make test`, `make vet`, `make lint`, `make fmt`, `make generate` (sqlc), `make migrate`
  (dbmate up and schema dump). One package or one test: `go test ./internal/<pkg> -run <Name>`.
- `make e2e`: the end-to-end smoke in `scripts/e2e/`: start the server, create a household,
  accept two invites with the Go test client, sync both ways, flip a flag, derive and commit a
  trip. `make load`: `cmd/domaload` against a throwaway server, 200 devices syncing every 5 s
  for two minutes; p99 under 50 ms and nothing lost (`LOAD_FLAGS='-devices 50 -for 1m'`).
- `make brand`: regenerate `assets/brand` and `assets/icons` from their generators and `tokens.css`
  from `tokens.json`, and write the flattened app icon into `app/ios` (needs Python with fontTools,
  brotli, cairosvg and Playwright's Chromium).
- `make mac-project`, `make mac-build`, `make mac-test`, `make mac-run`: the Mac app (Xcode 26+,
  XcodeGen); `make ios-project`, `make ios-build`, `make ios-test`, `make ios-device`,
  `make ios-testflight` (`V=0.3.0` stamps the version): the iOS app in the simulator, its tests, on
  a connected iPhone, or uploaded for TestFlight. `make ui-test` runs the UI tests and the live test against a throwaway server;
  `make snapshots` records the screen pictures the test suites compare against, after a change
  to a screen.
- `make mac-release V=<version>`: doma for Mac signed with the Developer ID, notarized and
  stapled, as a DMG under `app/macos/build/release` (`scripts/mac-release.sh`).
- `scripts/release.sh <version>`: tag a release; goreleaser builds the binaries and the image in
  CI. Before the tag it builds the Mac app, after it adds the DMG to the GitHub release and
  writes the cask `doma` in w4jnl/homebrew-tap (`scripts/cask.sh`); `DOMA_NO_APP=1` skips the
  app. It needs a `## <version> (YYYY-MM-DD)` section in `CHANGELOG.md`.
