# doma — design

As of 2026-11-01 · J. This file is the source of truth for implementation. Brand and UI rules: `docs/design-system/`; logos and icons: `assets/brand/` and `assets/icons/`.

## Purpose, scope and principles

This document specifies a family household app — shared and personal shopping lists, stock flags across several homes, and trip lists — as one Go server with an event log and native iPhone and Mac clients, in enough detail for an implementing agent to build version 1 without further design decisions. Name: `doma`, Slovak for "at home" (binary, repo `w4jnl/doma`, bundle `nl.w4j.doma`); the App Store listing carries a qualified name, see open decisions. Background: ShopShop is the behavioural baseline for lists; vink (`w4jnl/vink`) is the structural baseline for the server.

**Goals (v1)**

- Shopping lists with ShopShop's mechanics: type, match against everything ever typed, tap to add, tap to strike, clear struck items. Lists are shared by the household or personal to one person.
- Purchase history from day one: every cleared entry is kept with its quantity, unit, who, when and which home it was for, so later versions can show what was bought, how often and how much. The list screen itself never grows.
- Homes with stock flags per item: have / low / out, who set it and when; flags older than a threshold fade to unknown. Spots (drawer, fridge) with one current photo each.
- Trips: pick from-home and to-home; the app derives what to bring and what to buy.
- Households as the tenant boundary; a person can be in several households with a different role in each; guests get a scoped web link.
- Onboarding by QR code: no accounts, no passwords, no URLs typed, no command line for anyone.
- Sync through one append-only event log per household; clients work offline and merge without conflicts.
- Server-rendered web pages for guests and for the instance admin, on the same service layer the API uses.
- No outbound calls from the server except APNs and whatever the admin configures.

**Non-goals (v1)**

- Stock counts, barcodes, expiry dates, recipes, meal plans. Quantities are kept on purchases (see Shopping lists), never tracked as stock levels.
- Overview and report screens over the purchase history: the data is kept in v1, the screens come in phase 3.
- Tasks and chores (a later list kind, no schema change needed).
- A full web client for members, multiple servers in one app install, passkeys: designed for, not built.
- Photo recognition by a vision model: a later server job on the photos table.
- Android native app; Android members use the web client when it exists, guests use the guest view now.

**House conventions**

| Concern | Choice |
| --- | --- |
| Server language | Go 1.23+, stdlib first, `internal/` packages, no global state, `context.Context` on every I/O path |
| Logging | `log/slog`, JSON by default; `-d` switches to debug level and the colourised text handler (`MatusOllah/slogcolor`); every request log carries `req_id`, `household_id`, `person_id` when known |
| HTTP | `net/http` ServeMux with method patterns, middleware as `func(http.Handler) http.Handler` |
| Database | SQLite via `modernc.org/sqlite`, WAL, one writer; all queries through `sqlc` from `internal/db/queries/*.sql` |
| Migrations | `amacneil/dbmate` as a library, embedded timestamped SQL, applied at startup; `db/schema.sql` dumped for sqlc |
| Web pages | `html/template` + htmx 2.x vendored, one CSS file with design tokens, no build step |
| Config | TOML file + `DOMA_*` env overrides; secrets never logged |
| Errors | `%w` wrapping, sentinel errors per package, RFC 7807 `application/problem+json` on the API |
| Apps | Swift 6, SwiftUI, XcodeGen projects under `app/ios` and `app/macos` over `app/shared`, as nt; GRDB for the local store, no third-party UI |
| Tests | table-driven; server tests on a temp SQLite file, no DB mocks; the fold logic tested against one JSON fixture under `docs/fixtures/`, read by the Go and the Swift tests |

**Principles**

1. Tenancy is structural: every row below `households` carries `household_id`; every sqlc query takes a scope; a CI grep fails a query on a household table without it.
2. One event log, one fold: the server and the apps apply the same events with the same rules; materialised tables are a cache of the log.
3. The family vocabulary is the only vocabulary: home, list, item, member, guest, invite. No tenant, token, event, sync or server on any family-facing screen.
4. Designed wider than built: persons, credentials and `(server, household)` keys exist from migration one so a second server, a web client and passkeys are rows and routes later, never migrations of family data.

## What a family sees: onboarding, roles, vocabulary

A new member goes from App Store to a working shared list in under a minute, with nothing typed: the household owner shows a QR code, the member scans it, the lists appear. Everything below exists to make that true.

**Onboarding**

1. The operator runs `doma serve` once; the first browser visit shows a setup page that creates the admin login (name, password, confirm) and the first household. The page never appears again.
2. The admin, or any owner from the app, creates a household: name, home timezone, first home name. Two fields and a button.
3. An owner taps **Invite** in the app's Family screen and chooses a role (member or owner). The app shows a QR code and a share button for the link. The invite is valid for 7 days and one use; the owner can revoke it from the same screen.
4. The new member installs the app from the App Store. First launch shows one screen: *Scan your family's invite*, with a camera view and a *Paste a link* fallback. Scanning registers the device (a key pair generated on the phone), creates the person on that server if the device is new to it, and adds the membership. A device that already belongs to the household, after a reinstall that kept its key, gets its membership back from any valid invite of that household and the invite stays unused.
5. The member lands on the household's list screen with the shared lists already populated. Personal lists start empty with one line of help.

A guest link is the same flow without an app: the owner picks a home and a list, taps **Guest link**, shares it; the guest opens it in any browser and sees that home's missing items and that list, nothing else. Default validity 7 days, revocable.

An owner who belongs to a second household accepts a second invite the same way; the app adds the household to its switcher. If the second household lives on a different server, the app stores a second server context; v1 ships with a single context and refuses a second with a clear message (see open decisions).

A second device of the same person, a Mac or a new phone, joins through *Add a device* in Settings: a one-use invite bound to the person, valid a day, shown as a QR. The new device scans it like any invite and gets its own key under the same name and every household the person is in; it never becomes a second member. A device invite is not among the household's pending invites.

**Roles**

| Action | guest | member | owner | admin (server) |
| --- | --- | --- | --- | --- |
| see the linked home's missing items and the linked list; add and strike on that list | ✓ | ✓ | ✓ | |
| all lists, homes, flags, trips of the household; create and edit personal lists | | ✓ | ✓ | |
| create shared lists, homes, spots; set flags; take photos | | ✓ | ✓ | |
| invite members, make guest links, remove a member or a lost device, rename the household | | | ✓ | |
| create households, set quotas, see server pages, back up | | | | ✓ |

Roles are per membership. The same person is owner at home and member at their parents'. There is no per-list permission in v1; a personal list is private to its person by construction.

**Vocabulary** (family-facing strings, used exactly, English first, with Dutch and Slovak strings in the same catalogue)

| Word | Means |
| --- | --- |
| household | the family; the tenant |
| home | a place the household keeps things: Gouda, the cabin |
| spot | a storage place in a home: pantry, fridge door, bathroom cabinet |
| item | a thing you buy or keep; the catalog is the set of items ever typed |
| list | a shopping list, shared or personal |
| flag | have, low, out, unknown — the state of an item at a home |
| trip | from one home to another: a bring list and a buy list |
| member, owner, guest | the three roles |
| invite, guest link | the two ways in |

Words that never appear on a family-facing screen: tenant, token, event, sync, server, credential, instance, device key.

## Architecture and repository layout

One repository, `github.com/w4jnl/doma`, as the siblings: the Go server at the root and the apps under `app/`, in nt's layout (`app/ios`, `app/macos`, `app/shared`). The event schema and the fold fixture live once, under `docs/`, and the Swift tests read them by path; nothing is vendored.

![Server architecture: three clients reach one service layer; one fold writes the store](diagrams/architecture.png)

Clients never reach the store: the apps speak the sync protocol, browsers get rendered pages, and every path ends in the service layer, which validates, appends to the log and lets the fold write the tables.

The server has four transports that never touch the database: the sync API used by the apps, the REST API for the web pages and later clients, the guest and admin web pages, and APNs out. All call one service layer that owns authorization, transactions and the fold; the store is generated by sqlc.

**Server repository `doma`**

```
cmd/doma/                 main: serve (the only subcommand), -d, --config
internal/config/          TOML + DOMA_* env, validation, redaction
internal/domain/          Household, Person, Credential, Membership, Home, Spot, Item, List, Entry, Flag, Photo, Event, Scope, Role, ids
internal/db/              open, pragmas, WAL, busy_timeout; generated sqlc code
internal/db/migrations/   YYYYMMDDHHMMSS_name.sql, embedded, dbmate; schema.sql dumped for sqlc
internal/db/queries/      *.sql by table; every query on a household table takes household_id
internal/fold/            the event fold: apply(event, tables) for every kind; pure, no I/O; fixture tests
internal/service/         households.go persons.go invites.go guests.go sync.go lists.go homes.go trips.go photos.go admin.go
internal/auth/            devicekey.go (signature check), session.go (admin), guest.go, scope middleware
internal/http/            server.go router.go middleware/ (reqid, log, recover, csrf, scope)
internal/http/sync/       POST /sync/v1, cursors, snapshot download
internal/http/api/        /api/v1 handlers, problem.go, openapi.yaml
internal/http/web/        guest pages, admin pages, setup page; templates/, static/ (tokens.css, fonts, doma.css, htmx.min.js, the icon sprite)
internal/push/            APNs token auth, device token registry, coalescing
internal/photos/          disk store per household, quota, thumbnails
internal/export/          household → markdown + JSON archive
internal/metrics/         Prometheus collectors
docs/                     event-schema.json, fixtures/fold.json, deploy/ (systemd, compose, nomad, traefik)
docs/design-system/       README.md (brand and UI rules), tokens.json (source of truth), tokens.py → tokens.css, fonts/
assets/brand/             marks, lockups, wordmark, tiles, app icon, hero and social; gen.py, render.py
assets/icons/             the pictograms, one SVG each plus the sprite doma-icons.svg; gen.py
```

**Apps, under `app/`** (nt's layout: two XcodeGen projects over one shared tree, `#if os` where the platforms differ)

```
app/ios/                  project.yml (XcodeGen), Doma/ (the iOS target, its Assets.xcassets with AppIcon), DomaTests/, ExportOptions.plist, Local.xcconfig.example
app/macos/                project.yml, Doma/ (the Mac target), DomaTests/
app/shared/               DomaKit, compiled into both targets
app/shared/Store/         GRDB schema mirrored from the server's household tables, keyed by (server_id, household_id)
app/shared/Fold/          Swift port of internal/fold, tested against ../../docs/fixtures/fold.json by path
app/shared/Sync/          outbox, cursor per (server, household), SyncClient (URLSession), background refresh, push handling
app/shared/Identity/      device key in the Secure Enclave or Keychain, server contexts, invite acceptance
app/shared/Model/         value types shared with the UI
app/shared/Views/         Lists, List, Homes, Home, Trip, Family, Scan, Settings
app/shared/Design/        Tokens.swift mirroring tokens.json, glyphs, the custom symbols, Dynamic Type helpers
```

**Conventions inside the tree**

- Handlers are thin: parse, one service call, render. Services own transactions and return domain errors (`ErrNotFound`, `ErrForbidden`, `ErrValidation{Field, Msg}`), never `sql.ErrNoRows`.
- `domain.Scope{HouseholdID, PersonID, Role}` is set once by auth middleware and travels in `context.Context`; every service method takes it first; a guest scope carries `HomeID` and `ListID` and nothing else.
- Ids are ULIDs as text; timestamps are integer Unix milliseconds UTC; the fold uses a hybrid logical clock (`hlc` = `(wall_ms, counter, device_id)`), never device wall time alone.
- The fold package is the only code that writes materialised tables from events, on both sides. The service layer validates and appends; the fold applies. A bug in the fold is fixed once and verified by the shared fixture.
- Templates: one layout, one file per page, partials for htmx swaps; view models built in Go; no external URLs in any template.
- Brand and UI rules are `docs/design-system/README.md`; its `tokens.json` is the source of truth for every colour, glyph and size. The web pages load `tokens.css` and use `dm-*` classes in one hand-written CSS file; the apps mirror the tokens in `app/shared/Design/Tokens.swift` with a test that fails on drift; `make brand` regenerates the marks and pictograms from `assets/brand/gen.py` and `assets/icons/gen.py`. No hex value anywhere else.

## Data model and tenancy

Eighteen tables. Four are instance-level (persons, credentials, households, admin), the rest hang off a household and carry `household_id` on every row. The materialised tables below `events` are a cache: the fold can rebuild them from the log, and a test proves it.

**Identity (instance level)**

| Table | Key columns | Notes |
| --- | --- | --- |
| `persons` | `id`, `display_name`, `created_at`, `last_seen_at` | one per server; no email, no password; the display name comes from the invite acceptance screen |
| `credentials` | `id`, `person_id`, `kind` (`device_key` / `passkey` / `guest_link`), `public_key` or `hash`, `label` ("J's iPhone"), `platform`, `apns_token` (nullable), `created_at`, `last_used_at`, `revoked_at` | a device is a credential; passkeys are a later kind, same table; guest links are credentials of a throwaway person with `kind = guest_link` |
| `households` | `id`, `slug`, `name`, `timezone`, `quota_devices`, `quota_photo_bytes`, `created_at` | quotas null = unlimited; `slug` is used in export paths only, never in URLs a family sees |
| `memberships` | `person_id`, `household_id`, `role` (`owner` / `member` / `guest`), `home_id` (guests only), `list_id` (guests only), `expires_at` (guests only), `created_at` | primary key (`person_id`, `household_id`); a guest membership is what a guest link resolves to |
| `invites` | `id`, `household_id`, `role`, `token_hash`, `created_by`, `expires_at`, `used_by`, `used_at`, `revoked_at`, `for_person_id` (nullable) | one use; the QR encodes `https://<base_url>/i/<token>`; with `for_person_id` set it is a device invite: accepting adds a key to that person instead of a person to the household |
| `admin` | `id`, `login`, `password_hash`, `totp_secret` (nullable), `created_at` | one row; the server pages' login; argon2id |

**Household data**

| Table | Key columns | Notes |
| --- | --- | --- |
| `events` | `seq` (integer, per household, assigned by the server), `id` (ULID from the client), `household_id`, `person_id`, `credential_id`, `hlc`, `kind`, `payload` (JSON), `received_at` | append-only; unique on `id`; indexed on (`household_id`, `seq`) |
| `snapshots` | `household_id`, `seq`, `blob_path`, `created_at` | nightly; a new device downloads the snapshot and then events after its `seq` |
| `homes` | `id`, `household_id`, `name`, `sort`, `archived_at` | |
| `spots` | `id`, `household_id`, `home_id`, `name`, `sort`, `archived_at` | |
| `items` | `id`, `household_id`, `name`, `norm_name` (unique per household), `category` (nullable), `last_used_at`, `use_count`, `archived_at` | the catalog; `norm_name` = lowercased, diacritics stripped, whitespace collapsed; `use_count` drives autocomplete order |
| `item_aliases` | `item_id`, `household_id`, `norm_name` | "olijfolie" and "olive oil" can be the same item; created only by an explicit merge in the UI |
| `lists` | `id`, `household_id`, `name`, `colour`, `owner_person_id` (null = shared), `sort`, `archived_at` | personal lists have an owner and are filtered by scope; the server never returns another person's personal list |
| `entries` | `id`, `household_id`, `list_id`, `item_id`, `note` ("the small jar"), `qty` (decimal, nullable), `unit` (nullable), `for_home_id` (nullable), `added_hlc`, `added_by`, `checked_hlc` (nullable), `checked_by`, `cleared_hlc` (nullable) | one open entry per (`list_id`, `item_id`) and any number of cleared ones; re-adding an item that is checked but not cleared unchecks it; cleared entries are never deleted or pruned: they are the purchase history |
| `flags` | `household_id`, `home_id`, `item_id`, `state` (`have` / `low` / `out`), `set_hlc`, `set_by`, `note` | primary key (`home_id`, `item_id`); staleness is computed at read time from `set_hlc`, never stored |
| `staples` | `household_id`, `home_id`, `item_id`, `sort` | the items a home should always have; the trip view and the home view are built from this set |
| `photos` | `id`, `household_id`, `spot_id`, `taken_hlc`, `taken_by`, `path`, `thumb_path`, `bytes`, `width`, `height` | files under `photos.dir/<household_id>/`; the newest per spot is current; older ones kept until `retention.photos_per_spot` |
| `trips` | `id`, `household_id`, `from_home_id`, `to_home_id`, `date`, `created_by`, `arrived_at` | a trip is a view until the person taps *Arrived*, which commits the bring list as flag changes; stored so the history shows what moved |
| `push_log` | `household_id`, `credential_id`, `sent_at`, `seq` | coalescing: at most one push per device per 30 s |

**Tenancy rules the agent must enforce in code and tests**

- Every sqlc query on a household table has `WHERE household_id = ?` as its first predicate; CI greps `internal/db/queries` and fails on a `SELECT`, `UPDATE` or `DELETE` on those tables without it.
- Personal lists add a second predicate: `AND (owner_person_id IS NULL OR owner_person_id = ?)`. A guest scope adds `AND list_id = ?` on entries and `AND home_id = ?` on flags and staples.
- The sync endpoint filters events the same way before returning them: a member never receives another member's personal-list events; a guest receives only events for its home and list. Filtering is by event `kind` and payload fields the fold indexes, so personal-list events carry `list_id` and `owner_person_id` in the payload.
- Uniqueness is scoped: `items.norm_name` per household, `lists.name` per (household, owner), `homes.name` per household.
- Deleting a household is admin-only, requires zero members, cascades through `ON DELETE CASCADE`, and removes the photo directory.
- Photos are the only data outside SQLite; the quota is checked before the upload is accepted and the usage is recomputed nightly from disk.
- SQLite pragmas at open: `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`; one `*sql.DB` with `MaxOpenConns(1)` for writes and a second read-only pool.

## Event log and sync

Every change a person makes is one event appended to the household's log; the server orders them and every client folds them into the same tables. The data is sets and single-value flags, so the merge rules fit in one table and two phones striking the same list in the same shop never conflict.

**Event shape**

```json
{
  "id": "01JBX…",               "// ULID minted on the client"
  "household_id": "01JBW…",
  "hlc": "1730380000000:0003:dev_8f2a",   "// wall_ms:counter:device, compared lexically after zero-padding"
  "kind": "entry.added",
  "payload": { "list_id": "…", "item_id": "…", "note": "2x", "for_home_id": null }
}
```

The server adds `seq`, `person_id`, `credential_id` and `received_at` on append. A client never sends `seq`. Payloads are validated per kind against `docs/event-schema.json` before append; an invalid event is rejected with 422 and the client drops it from its outbox and logs it.

**Event kinds and merge rules**

| Kind | Payload | Fold rule |
| --- | --- | --- |
| `item.named` | `item_id`, `name` | insert if `norm_name` unknown; if a different `item_id` already owns that `norm_name`, record the new id as an alias of the existing item (so two phones typing "melk" offline converge on one item) |
| `item.renamed` | `item_id`, `name`, `hlc` | last writer wins on `hlc` |
| `item.merged` | `keep_id`, `drop_id` | add alias, repoint entries, flags and staples; idempotent |
| `list.created` / `list.renamed` / `list.archived` | `list_id`, `name`, `colour`, `owner_person_id` | add-wins for create; LWW on name and colour; archive wins over rename |
| `entry.added` | `list_id`, `item_id`, `note`, `qty`, `unit`, `for_home_id` | add-wins among open entries on (`list_id`, `item_id`); if an open entry exists and is checked, clear `checked_hlc` (re-adding unchecks); if only cleared entries exist, a new entry row is created; LWW on `note`, `qty`, `unit` |
| `entry.checked` / `entry.unchecked` | `list_id`, `item_id` | LWW on `hlc` between the two kinds; an `added` newer than `checked` unchecks |
| `entry.cleared` | `list_id`, `before_hlc` | sets `cleared_hlc` on entries checked before `before_hlc`; a cleared entry is a purchase record, never changed or deleted; an `added` newer than `cleared` creates a new entry |
| `flag.set` | `home_id`, `item_id`, `state`, `note` | LWW on `hlc`; `state` ∈ have / low / out; `out` also adds the item to the household's default list with `for_home_id = home_id` if no open entry exists (done in the fold so every client agrees) |
| `staple.added` / `staple.removed` | `home_id`, `item_id` | add-wins, remove-wins only if newer than the latest add |
| `home.created` / `home.renamed` / `home.archived`, `spot.*` | `home_id`, `spot_id`, `name` | as for lists |
| `photo.added` | `photo_id`, `spot_id`, `bytes`, `width`, `height` | append; the blob is uploaded separately by `photo_id`; the fold marks the photo current if its `hlc` is newest for the spot |
| `trip.arrived` | `trip_id`, `from_home_id`, `to_home_id`, `moved` (list of `item_id`) | for each moved item: `flag.set out` at from-home and `have` at to-home with the trip's `hlc`; one event so a trip is atomic |
| `member.removed`, `device.revoked` | `person_id`, `credential_id` | server-originated; clients drop the membership or stop syncing that credential |

Rules that hold for every kind: events are idempotent by `id`; the fold is deterministic given the same ordered events; a client folds its own events optimistically at creation and again when they come back with `seq`, with identical result; an unknown `kind` is stored and skipped by the fold, so an old app survives a new server.

**Endpoint**

`POST /sync/v1` with the device key signature header (see Security). Body: `{"households": [{"id": "…", "since": 4812, "events": [ … outbox … ]}]}`. One request covers every household the device belongs to on that server.

Response: `{"households": [{"id": "…", "accepted": ["01JBX…"], "rejected": [{"id": "…", "reason": "…"}], "events": [ … everything after since, in seq order, with seq … ], "next": 4830, "snapshot": null}]}`. `events` is capped at 500 per household; the client loops while `next` advances. `snapshot` carries a URL when `since` is older than the newest snapshot by more than `sync.replay_limit` events (default 5,000), and the client replaces its tables from the snapshot before continuing.

The server appends and folds in one transaction per household, then publishes `HouseholdChanged{id, seq}` on the in-process bus; the push subsystem coalesces per device.

**Client side**

- Outbox table: `(event_id, household_id, body, created_at, attempts)`. Events are written to the outbox and folded locally in one GRDB transaction, so the UI updates before any network.
- Cursor table: `(server_id, household_id, since)`.
- Triggers: on foreground, after any outbox write (debounced 300 ms), every 5 s while a list screen is visible, on silent push, and on `BGAppRefreshTask` roughly every 15 min in the background.
- Conflicts do not exist at the fold level; the only user-visible merge is two people renaming the same list, which LWW resolves silently.

**Push**

APNs with token-based auth (`.p8` key, key id, team id in config). On `HouseholdChanged`, one silent push (`content-available: 1`) per device that has a token and has not been pushed in the last 30 s, with `{"server": base_url, "household": id, "seq": n}` so the app pulls the right cursor. Push is a hint: a device that misses it catches up on the next trigger. A push also carries words when it can: the server composes, from the events since the device was last pushed, what other members added to which list or that they cleared it ("Sam added melk and brood" under the list's name, threaded per list), and sends that as an alert with `content-available` still set; a device whose own person made every change gets the silent push. Only `entry.added` and `entry.cleared` speak; checks never do. Whether the words show is the phone's notification permission, asked once after joining and shown in Settings; the server keeps no preference and the Mac, which polls, gets none.

**Compaction and retention**

A nightly job writes a snapshot per household (the materialised tables as JSON, gzip) and records its `seq`. Events older than the newest snapshot by `retention.events_days` (default 365) are deleted. The export archive always includes the full remaining log. Materialised entries are never pruned: cleared entries are the purchase history and travel in the snapshot.

## Shopping lists

A list is a blank screen with one add control; the item catalog does the rest. The behaviour below is ShopShop's, specified so the family does not notice the switch.

**Add**

- The add bar is pinned at the bottom of the list, above the keyboard when it is up, and never moves. Each keystroke filters the catalog by prefix on any word of `norm_name` or an alias, ordered by `use_count` desc, then `last_used_at` desc; the top 5 matches show as one-tap rows above the bar, the best nearest the bar, each with a muted *last bought 5 days ago* when the history has it. The row nearest the bar is what Return does: the exact item when the typed name exists, the typed line as a new item otherwise. With the field empty and focused, one row of chips shows the household's most used items that are not on the list.
- Tapping a match adds it and clears the field with the keyboard still up, so a run of items is tap, tap, tap. Pressing return adds the typed text as-is: an exact `norm_name` match reuses the item, anything else creates one (`item.named` + `entry.added` in one outbox write).
- A leading or trailing quantity is split off into `qty` and `unit`, any other trailing text into `note`: "melk 2", "2 melk", "2x melk", "500 g gehakt", "1,5 l melk" and "melk (the small jar)" give item *melk* or *gehakt* with qty 2 / 2 / 2 / 500 / 1.5 / none and unit x / x / x / g / l / none. Units recognised: x, ×, st, stuks, pcs, g, kg, ml, cl, l, pak, fles, zak, blik, bos; anything else stays in `note`. The item name is what is matched; qty, unit and note are shown muted after it.
- Adding an item that is already open on the list flashes the existing row instead of duplicating. Adding one that is checked but not cleared unchecks it.
- A swipe left on a row offers *Edit*: the row becomes one field holding the line as it would be typed ("melk 2 (the small jar)"), with a home chip when the household has homes. A changed name renames the item, the quantity, unit and note replace the entry's (for when the shop only had the big pack), a changed home sets `for_home_id`. Long-press is drag to reorder and nothing else. *Merge with…* is a Mac menu item, not a phone action.

**Strike and clear**

- Tapping a row strikes it (`entry.checked`) where it is: the glyph pops, the line draws through, one light haptic, and the row keeps its place for 1.5 s so a second tap takes it back; then it sinks below a thin divider, newest struck at the top of that group. A run of taps sinks together after the last. Tapping a struck row restores it the same way. A scroll never strikes.
- The divider says how many are got and carries *Clear*, armed in place (*Really clear?*), which removes the struck rows (`entry.cleared` with the current `hlc`) with a success haptic; it exists only while something is struck. Cleared entries leave the screen but stay in the store as the purchase history, for the catalog's `use_count` and for *Recent* below.
- Checking an entry with `for_home_id` set flags that item `have` at that home when the list is cleared, not when it is checked; a mis-tap in the shop should not move stock. The flag change rides on the same `entry.cleared` fold rule.

**Lists**

- The Lists tab opens into the last-used list, the default shared list the first time, remembered per household on the device. A *Lists* button at the top left opens the overview, one level down, and so does a second tap on the Lists tab. The overview shows the household's lists first, then the person's own (*Just me*), each with its colour dot, name and how many are to get; `+` creates one. Badge on the app icon = what this device has not seen: entries others added to the household's lists (shared and the person's own) after each list was last in front here. Opening a list moves its seen mark to its newest entry, so the badge falls; in the list the rows others added since the last visit carry a small accent dot for that visit, and in the overview a list with unseen entries shows the dot before its count. Seen marks live on the device only; the person's own adds never count.
- Creating a list asks for a name and *Household* or *Just me*; the list takes the first of the six list colours no list wears, changeable in *Rename*. A personal list cannot be made shared later (create a new one), a shared one cannot be made personal.
- A long-press or a swipe on a list row offers *Rename* and *Archive*, armed in place like every destructive action; the default list offers only *Rename*. An archived list keeps its history and leaves the screen.
- Each household has one default shared list, created with the household, used by `flag.set out` and by guests. It can be renamed, not deleted.
- *Recent* at the bottom of a list, collapsed by default, shows the last 30 cleared items for one-tap re-adding. This replaces ShopShop's habit of leaving struck items as memory.
- Reorder by drag; the order is per list, stored as a `sort` field on the entry, LWW. Default order is by time added, newest at the bottom, so the list reads like the shop walk the family already has.

**History and quantities**

- A purchase is an entry that was checked and then cleared. It keeps item, `qty`, `unit`, `note`, `for_home_id`, who added it, who checked it and both times. Entries are never deleted, never pruned, and never reused: re-adding an item after clearing creates a new entry.
- Quantities are parsed on add as described above and can be corrected with *Bought…* before clearing. Unparsed text stays in `note`, so nothing typed is lost.
- In v1 the history surfaces in two places only: *Recent* under each list, and the *last bought* hint on autocomplete rows. Overview screens come in phase 3 and read the same rows: purchases per item and per month, totals of `qty` by `unit`, per home, who shops what. No new events are needed for them.
- The history is in every export as `purchases.csv` (one row per cleared entry) and in the household snapshot, so pruning old events loses nothing a family can see.

**In the shop**

There is no shop mode: the list screen is always ready for the shop. Rows are 52pt, the add bar is at the bottom, the screen stays awake while a list is in front, and sync runs every 5 s while it is visible. One layout, learnt once.

**Guest view**

The guest's web page shows the one list with the same add, strike and clear, rendered server-side with htmx, polling every 10 s, and nothing else about the household.

## Homes, stock flags and trips

Stock is a presence flag per item per home, never a count. Whoever notices sets it; whoever leaves takes a photo; the trip view turns the two into a bring list and a buy list.

![Flag states: have, low, out and unknown, and what moves an item between them](diagrams/flag-states.png)

Any tap sets any flag directly; the drawn arrows are the paths the app takes on its own: a cleared list or a trip arrival restores have, a trip departure sets out, and silence fades every flag to unknown until someone answers *Still there?*.

**Flags**

| State | Meaning | Set by |
| --- | --- | --- |
| have | it is there | a tap on the home screen; clearing a list entry marked for this home; arriving with it on a trip |
| low | last one open, running out | a tap |
| out | not there | a tap; a trip that moved it away; also adds it to the default list for this home |
| unknown | no flag, or the flag is older than `staleness` | computed, never stored |

- `staleness` is per household, default 60 days, settable by an owner between 14 and 365 days. The home screen shows the flag with a muted age label ("3 wk") past half the threshold, and as unknown past it.
- Staples define which items a home is expected to have. The home screen lists staples first, grouped by spot if the item is pinned to one, then any other item that has a flag at this home. A staple with an unknown flag is the question the app asks: *Still there?* with have / low / out buttons.
- Setting `out` on a staple adds it to the household's default list with `for_home_id` set, so the next shop covers it; clearing that entry flags it `have` again. No other automation.

**Spots and photos**

- A home has spots (pantry, fridge, bathroom). A spot has one current photo and a history of `retention.photos_per_spot` (default 5). The home screen shows the current photo as a thumbnail per spot; tap to view full size with the taken-by and age.
- *Departure sweep*: from the home screen, *Take photos* walks through the spots in order with the camera open and one tap per spot. Two minutes before locking up; nothing else to fill in.
- Photos are uploaded as JPEG, long edge 1600 px, quality 0.8, by the app after the `photo.added` event is accepted; the server stores the original and a 320 px thumbnail; upload retries ride the outbox. A photo is shown as pending until the upload lands.
- Vision-model proposals (a server job that reads a new photo against the spot's staples and proposes flag changes for a member to confirm) are designed as a later `flag.proposed` event kind and a confirm screen; not in v1.

**Trips**

- A trip is from-home → to-home, created from the Trip tab with two pickers and a date (default today). It is a derived view until *Arrived*.
- Bring = items that are `out` or `low` at to-home and `have` at from-home. Buy = items that are `out` or `low` at to-home and not `have` at from-home, plus every open entry on any shared list with `for_home_id = to-home`. Unknown counts as not `have` at from-home and not `out` at to-home; the trip screen lists unknown staples of to-home in a third group, *Check on arrival*.
- Each bring row has a checkbox for packing; each buy row a *Add to list* button that creates an entry with `for_home_id = to-home`. *Add all* for the buy group.
- *Arrived* commits one `trip.arrived` event with the packed items; the fold flags them `out` at from-home and `have` at to-home with the trip's `hlc`. Items not packed are left alone. The trip then shows in History with what moved.
- Two members on the same trip see the same derived view; packing checkboxes are local to the device until *Arrived*, by design: the event is the record, not the checkboxes.

## iPhone and Mac apps

One SwiftUI code base under `app/shared`, four tabs on iPhone and a sidebar with the same four sections on Mac. Every screen reads from the local GRDB store and writes to the outbox; nothing waits on the network.

**Screens**

| Screen | Content | Writes |
| --- | --- | --- |
| Scan (first launch, or Family → Add) | camera, paste-link fallback, display-name field on first join | registers the device, accepts the invite |
| Lists | opens into the last-used list; the Lists button or a second tab tap leads to the overview: household lists, then personal, colour dot, name, how many to get; `+` to create | `list.created` |
| List | open rows, the divider with the got count and Clear, struck rows, Recent; the add bar pinned at the bottom with matches or the usual items above it; swipe left for Edit, long-press to drag | `item.named`, `entry.*` |
| Homes | one card per home: name, count of out/low/unknown staples, spot thumbnails | — |
| Home | staples grouped by spot with flag buttons; other flagged items; *Take photos*; manage staples and spots behind Edit | `flag.set`, `staple.*`, `spot.*`, `photo.added` |
| Trip | from/to pickers, date; Bring, Buy, Check on arrival groups; *Arrived* | `entry.added`, `trip.arrived` |
| Family | household name, members with role and last seen, pending invites, guest links, Invite (prominent), Guest link, Settings, Leave; Remove and Revoke behind a swipe, armed in the row; household switcher at the top when the person is in more than one | invites and guests through the REST API, not events |
| Settings | this device's name, notifications (on, or a way to allow them), staleness (owners), the person's devices with Revoke and *Add a device* (a QR the new device scans to join as the same person), About with the lockup, server name and version | REST |

**Interaction rules**

- State is shown by a word and a glyph, never colour alone: have ●, low ◐, out ◆, unknown ◌. One colour set per state, defined once in `Design/`, with a light and a dark variant.
- Every destructive action is a two-step inline confirm (*Remove → Really remove?*); no modals except the camera.
- Optimistic everywhere: the row appears, strikes or moves on tap; a sync failure shows one small offline badge in the toolbar, never an alert.
- Dynamic Type and VoiceOver on every row; the strike is announced as "checked".
- A household switcher appears only when the person has more than one membership; otherwise the household name is a title.
- Nothing about servers is visible unless the app holds more than one context, which v1 does not allow.

**Local store and identity**

- GRDB with the household tables mirrored, every table keyed by (`server_id`, `household_id`); `server_id` is a local ULID per context, mapped to a base URL and the device's credential id on that server.
- The device key is an Ed25519 pair in the Keychain (Secure Enclave is P-256 only; the server accepts both, prefer Ed25519 on iOS 17+ via CryptoKit). The public key is sent once at invite acceptance; every sync request is signed (see Security).
- Personal lists are stored like shared ones with `owner_person_id`; the UI filters by the context's person id.
- Background: `BGAppRefreshTask` registered for sync; silent pushes trigger a sync with a 25 s budget; photos upload with a background `URLSession`.

**Mac**

The Mac target reuses every screen in a `NavigationSplitView`: sidebar with Lists, Homes, Trip, Family; the list detail in the main pane, its title in the pane and its rows at `content-max`, left-aligned. A click selects a row, the symbol strikes it, a double click or return edits it; the add row is the last row of the open items. *New list* sits at the foot of the sidebar and opens one field there; a right-click on a list offers *Rename*, *Colour* and *Archive*, armed in place. Settings is a window (`⌘,`); an invite is a popover. Keyboard, all of it in the menu bar: `⌘N` new list, return adds or edits, space or `⌫` strikes the selected row, `⌘E` edits, `⌘⌫` clears. The Mac can accept an invite by pasting the link or by scanning the QR with Continuity Camera.

**Simplicity budget**

Four tabs, at most one list and one detail per screen, no screen with more than one text field apart from Scan. Anything that does not fit is a long-press item or a Settings row, not a new screen.

## Web: guest view, admin pages, later web client

The server renders three page sets with `html/template` and htmx on the same service layer the API uses: the guest view a family shares, the admin pages only the operator sees, and the setup page that appears once.

**Guest view** (`/g/{token}`)

| Route | Content | Live behaviour |
| --- | --- | --- |
| `/g/{token}` | the home's missing items (staples flagged out, low or unknown, with age) and the linked list with add, strike, clear | list body polls every 10 s; a 24 h cookie keeps the guest signed in after the first open |
| `/g/{token}/add` (POST) | adds an entry; the typed text goes through the same item matching as the app | htmx swap of the list |
| expired or revoked | one plain page: *This link is no longer valid* | |

No household name beyond the list's title, no other homes, no members, no photos. The guest's events carry the guest person's id, so the family sees *added by guest (cleaner)* with the label the owner gave the link.

**Admin pages** (`/admin`, admin login with password; TOTP optional)

| Page | Content |
| --- | --- |
| `/setup` | first run only: admin login, password, first household; redirects to `/admin` and never renders again |
| `/admin` | households: name, members, devices, photo bytes used, last event; create household |
| `/admin/h/{id}` | members with role and last seen, devices with platform and last sync, pending invites, guest links, quotas, staleness, export, delete (zero members only) |
| `/admin/server` | base URL and TLS check, APNs key status and last error, backup now, last snapshot time, log level, version |
| `/admin/invite` | create the first owner invite for a household (QR rendered server-side as SVG) so a family can be bootstrapped without any member yet |

Admin pages never read family content: no list entries, no item names, no photos. The operator sees counts and metadata only.

**Later web client for members**

Designed, not built: `/app` as server-rendered htmx pages for Lists, List, Homes, Home, Trip and Family, signed in with a passkey (`credentials.kind = passkey`). First sign-in is *scan this QR with your phone*, which lets the app vouch for the browser and register the passkey. No offline support; the sync endpoint stays the apps' path. This needs the `credentials` table and the service layer as designed here and nothing else in the schema.

## HTTP API

Three surfaces on one router: the sync endpoint for the apps, a REST API for everything that is not an event, and the web pages. All JSON errors are RFC 7807; every response carries `X-Request-Id`.

**Authentication**

| Caller | Credential | Scope |
| --- | --- | --- |
| app | device key signature (headers `Doma-Credential`, `Doma-Timestamp`, `Doma-Signature` over method, path, timestamp, body hash) | every household the credential's person is a member of; a request names the household in the path or body |
| guest | token in `/g/{token}` then a cookie | one home and one list |
| admin | session cookie after password (+ TOTP) | instance pages only |

**Endpoints**

| Method + path | Purpose |
| --- | --- |
| `POST /sync/v1` | the event exchange (see Event log and sync) |
| `GET /sync/v1/snapshot/{household}/{seq}` | gzip JSON snapshot download |
| `POST /photos/v1/{household}/{photo_id}` | JPEG upload for an accepted `photo.added`; 413 over quota |
| `GET /photos/v1/{household}/{photo_id}[/thumb]` | signed, cacheable 1 h |
| `POST /i/{token}` | accept an invite: body `{public_key, platform, label, display_name}`; returns `{server, person_id, credential_id, display_name, household, role}`; for a device invite the person's name wins over the typed one; `GET /i/{token}` renders the App Store page with the deep link |
| `GET /api/v1/me` | person, credentials, memberships with roles |
| `GET` and `POST /api/v1/h/{household}/invites` · `DELETE /api/v1/h/{household}/invites/{id}` | owners; `POST` with `{device: true}` is any member's, for a device of their own, valid a day, not listed among the household's |
| `GET` and `POST /api/v1/h/{household}/guests` · `DELETE …/guests/{id}` | owners; body `{home_id, list_id, label, days}` |
| `GET /api/v1/h/{household}/members` · `DELETE …/members/{person}` · `PUT …/members/{person}/role` | owners; the last owner cannot be removed or demoted |
| `DELETE /api/v1/credentials/{id}` | a person revokes their own device; owners revoke any device in their household |
| `PUT /api/v1/h/{household}` | name, timezone, staleness (owners) |
| `POST /api/v1/devices/{credential}/apns` | register or refresh the APNs token |
| `GET /api/v1/h/{household}/export` | zip: `household.json`, `events.ndjson`, `purchases.csv`, `lists/*.md`, `homes/*.md`, `photos/` (members) |
| `GET /healthz` · `GET /readyz` · `GET /metrics` | process up; DB writable and snapshot job alive; Prometheus with a bearer when `metrics.token` is set |
| `GET /api/v1/openapi.yaml` | hand-maintained, tested against the router |

Membership, invites and guests are REST and not events because they change who may read the log; the server is the only authority on them and clients learn of changes through the `member.removed` and `device.revoked` events the server appends.

**Errors and limits**

Codes: 400 malformed, 401 bad signature or expired token, 403 role, 404 for anything outside the caller's households (never 403, so households cannot be enumerated), 409 invite already used, 413 photo over quota, 422 event validation, 429 rate limit with `Retry-After`. Limits: 120 sync requests per minute per device, 2,000 events per sync request, 10 photo uploads per minute per device.

## Security checklist

The attack surface is small and named: invite and guest links, the sync signature, photo uploads, and the admin login. Everything else is unreachable without one of those.

- **Device keys.** Ed25519 (or P-256) public key stored in `credentials`; every app request signs `method\npath\ntimestamp\nsha256(body)`; the server rejects timestamps more than 5 min off and replays within the window by a per-credential nonce cache. The private key never leaves the Keychain; a lost phone is revoked from Family or `/admin`, and the next sync from it gets 401 and the app wipes its local store for that server.
- **Invites and guest links.** 32 random bytes, base64url, stored as SHA-256; shown once in a QR or link; single use for invites, time-limited for both; constant-time comparison; 10 failed token lookups per minute per IP, then 429. The App Store deep link carries the token in the fragment, not the query, so it does not land in logs.
- **Personal lists.** Filtered in the sync layer by the fold's index of `owner_person_id` on every list event, tested by the cross-person suite: two members in one household never see each other's personal entries through sync, REST or export.
- **Guests.** A guest scope is `(household, home, list)`; the sync filter and every query add those predicates; a guest cannot call `/sync/v1` at all, only the web routes.
- **Photos.** Decoded and re-encoded server-side (JPEG only) to strip metadata and defuse malformed files; served with `Content-Type: image/jpeg`, `X-Content-Type-Options: nosniff`, from a signed URL valid 1 h. Quota is enforced before the body is read (`Content-Length`) and again after.
- **Admin.** argon2id (`t=2, m=64MB, p=1`), session cookie `HttpOnly, Secure, SameSite=Lax`, CSRF double-submit on every form, 5 failed logins per minute per IP, optional TOTP in v1 since it is one screen.
- **Headers on every page.** `Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'`, `Referrer-Policy: same-origin`, `X-Frame-Options: DENY`.
- **Outbound.** The server makes no outbound connection except APNs (`api.push.apple.com`) and nothing at all when `push.enabled = false`. No update check, no telemetry, no CDN.
- **Secrets at rest.** The APNs `.p8` key and the admin TOTP secret are encrypted with XChaCha20-Poly1305 under `secrets.key_file` (32 bytes, created on first run). Back it up with the database: without it the APNs key must be re-uploaded, nothing else is lost.
- **Cross-tenant suite.** Integration tests create two households and two persons per household plus one guest, and assert 404 across every boundary for sync, REST, photos and export.
- **Supply chain.** `go.sum` verified, `govulncheck` in CI, no cgo, `-trimpath -ldflags "-s -w -buildid="`, SBOM from the release workflow; the apps pin GRDB by version and carry no other dependency.

## Configuration, observability, packaging

**Configuration** (`doma.toml`, every key overridable as `DOMA_SECTION_KEY`; `/admin/server` shows the effective, redacted config)

```toml
[server]
listen = ":8080"
base_url = "https://doma.example.com"   # invite and guest links, APNs payload, signed photo URLs
trusted_proxies = ["10.0.0.0/8"]
[db]
path = "/var/lib/doma/doma.db"
[photos]
dir = "/var/lib/doma/photos"
max_bytes_per_upload = "8MB"
[sync]
max_events_per_response = 500
replay_limit = 5000                     # older cursors get a snapshot first
[push]
enabled = false
key_file = "/var/lib/doma/apns.p8"      # encrypted at rest after first start
key_id = ""
team_id = ""
topic = "nl.w4j.doma"                   # the app's bundle id
sandbox = false
[invites]
default_days = 7
guest_default_days = 7
[retention]
events_days = 365
photos_per_spot = 5
snapshot_hour = 3                       # server local time
[defaults]
staleness_days = 60
[log]
level = "info"
format = "json"
[metrics]
token = ""
[secrets]
key_file = "/var/lib/doma/secret.key"
```

**Observability of the server itself**

- `slog` JSON: one line per request (`method path status dur_ms req_id household person`), one per sync batch (`household accepted rejected returned next`), one per push attempt, one per snapshot job, one per photo upload.
- `/metrics`: `doma_households`, `doma_members{household}`, `doma_events_total{household,kind}`, `doma_sync_requests_total{result}`, `doma_sync_duration_seconds`, `doma_push_total{result}`, `doma_photo_bytes{household}`, `doma_snapshot_age_seconds{household}`, `doma_db_write_duration_seconds`.
- `/readyz` fails when the writer cannot `BEGIN IMMEDIATE` within 2 s or the snapshot job has not run in 36 h.
- `-d` on `serve` switches to debug and colour, logs every sync request's event ids, every fold rule applied with its before and after state, and every SQL statement slower than 50 ms.

**Packaging**

- Server: `goreleaser` builds `doma_{version}_linux_{amd64,arm64}` and a `FROM scratch` image `ghcr.io/w4jnl/doma` with `/doma` and CA certificates; `docs/deploy/` has `doma.service` (systemd, `DynamicUser=yes`, `StateDirectory=doma`), `compose.yaml`, `doma.nomad.hcl` and a Traefik snippet that terminates TLS and forwards everything. No reverse-proxy auth in front: the server authenticates every route itself, and the guest and invite links must be reachable without it.
- Backup = the DB file, the photos directory and `secret.key`; `/admin/server` has *Back up now*, which uses the SQLite online backup API and writes a dated zip next to the DB.
- Apps: `make ios-build`, `make mac-build`, `make ios-testflight` as in nt; TestFlight for the family during phases 0–1, App Store from phase 2 so non-technical members install from the store. Bundle id `nl.w4j.doma`; the App Store listing name is a qualified form such as "Doma – lists, homes, trips" because "Doma" alone is taken (see open decisions); the listing opens on the Scan screen and includes a demo household so review can exercise the app without a server.

## Testing, milestones, open decisions

Four phases, each with a gate the family can feel; the implementing agent works the task lists in order and does not start a phase before the previous gate is met.

![Roadmap: four phases, each gated by something the family can feel](diagrams/roadmap.png)

Phase 0 is the biggest and the only one with a fixed shape; phases 1 and 2 are short; phase 3 is a list of designed-for features taken one at a time, each with its own gate.

**Testing**

- Fold fixture: `docs/fixtures/fold.json` holds ordered event sequences and the expected tables after each, including out-of-order delivery, duplicate ids, two devices naming the same item offline, re-add after clear, and a trip. The Go and Swift fold tests both load it; a change to the fold is a change to the fixture first.
- Server integration: boot on a temp SQLite file; exercise invite acceptance, sync round trips with two devices, the guest view, photo upload and quota, export; the cross-tenant and cross-person suites.
- Property test on the fold: random event sets applied in random orders converge to the same tables.
- App UI tests: add, strike, clear, offline add then sync, accept invite from a QR image; snapshot tests for every screen in light and dark, two Dynamic Type sizes.
- End-to-end smoke: `make e2e` starts the server, creates a household, accepts two invites with a Go test client that implements the device-key signature, adds on one and reads on the other, flips a flag, derives a trip, commits it, and checks the flags moved.
- Load: `cmd/domaload` with 200 devices syncing every 5 s against a laptop; acceptance is p99 sync under 50 ms and no event lost.
- CI: `go vet`, `golangci-lint`, `sqlc diff`, `govulncheck`, tests with `-race`, the household_id grep gate, `xcodebuild test` for DomaKit.

**Phase 0 — server and lists** (gate: the family's shared list runs on doma for two weeks and ShopShop is deleted)

- [ ] Brand kit in the repos as delivered: `docs/design-system/`, `assets/brand/`, `assets/icons/`, `make brand`; `app/shared/Design/Tokens.swift` and its drift test; the custom SF Symbols from the pictogram files
- [ ] Server skeleton: `serve`, config, migrations for every table above, sqlc queries, setup page, admin login
- [ ] Identity: persons, credentials, device-key signature middleware, invites with QR, memberships and roles, scope middleware
- [ ] Fold package with the fixture; events for items, lists, entries with qty and unit parsing and the purchase history; `POST /sync/v1` with cursors and limits
- [ ] Snapshot job, retention, export zip
- [ ] APNs silent push with coalescing; `push.enabled = false` path verified to make zero outbound calls
- [ ] Apps: DomaKit store, Swift fold against the fixture, outbox and sync client, Scan screen, Lists and List screens with every ShopShop behaviour, Family screen with invite and member management, Mac target
- [ ] Admin pages: households, household detail, server
- [ ] Cross-tenant and cross-person suites, e2e smoke, TestFlight build

**Phase 1 — homes and trips** (gate: one trip between two homes with nothing bought twice and nothing missing)

- [ ] Homes, spots, staples, flags with staleness; `flag.set out` → default list rule
- [ ] Trip derivation on the client, `trip.arrived`, history
- [ ] Photos: capture, upload, thumbnails, quota, departure sweep
- [ ] Guest links and the guest view
- [ ] Home and Trip screens, Dutch and Slovak strings

**Phase 2 — public install** (gate: a second family onboards from the App Store with no help beyond the QR)

- [ ] App Store listing, demo household for review, onboarding polish
- [ ] Second household on the same server end to end; switcher; quotas
- [ ] Backup and restore drill from `/admin/server`
- [ ] Metrics, `docs/deploy/` verified on Nomad and compose

**Phase 3 — designed-for features** (each its own gate)

- [ ] Passkeys and the member web client
- [ ] Multiple server contexts in the app
- [ ] `flag.proposed` from a vision model over new photos, with a confirm screen
- [ ] History and overviews: purchases per item, per month and per home, totals of `qty` by `unit`; read from the entries table, no new events
- [ ] Tasks as a third list kind
- [ ] Watch app for lists

**Open decisions** (defaults the agent takes unless overruled)

| Decision | Default | Alternative |
| --- | --- | --- |
| Name | `doma` (decided) | the App Store name "Doma" is taken by a property app and Doma Home is a smart-home brand, so the listing uses a qualified name; check EUIPO before the listing |
| Local store | GRDB | SwiftData with a custom store; loses SQL-level fold tests |
| Device key algorithm | Ed25519 in Keychain | P-256 in Secure Enclave; server accepts both from day one |
| Push in phase 0 | yes, behind `push.enabled` | polling only until phase 2 |
| Default list per household | one, auto-created, renameable | user chooses the target list on each `out` |
| Autocomplete order | `use_count`, then recency | recency only, as ShopShop |
| Photo size | 1600 px long edge, JPEG 0.8 | originals; 4–8× the storage |
| Second server in one app | refused in v1 with a message | supported from v1; adds a context picker to Scan |
| Admin TOTP | in v1 | phase 2 |
| Licence and repo visibility | public, MIT, as vink (opened 2026-11-03) | private until the public install |
