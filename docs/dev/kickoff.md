# doma kickoff

The prompts this project was started from, in order. Paste each into Claude Code at the root of
the repository after the previous one has been reviewed. Kept here for the record, as flok, vink
and nt keep theirs.

## 0. Server, phase 0

```
You are starting doma, the family's household app. Read CLAUDE.md, then docs/design.md in full,
then docs/design-system/README.md. docs/design.md is the source of truth; the brand kit under
docs/design-system/, assets/brand/ and assets/icons/ is finished and is not to be redesigned.

Build phase 0 for the server, in the order of its task list under "Testing, milestones, open
decisions", taking every default in the open-decisions table:

1. Repository skeleton in the siblings' shape (vink is the model): go.mod with module
   github.com/w4jnl/doma, Makefile with the targets CLAUDE.md names, CI workflow (vet, lint,
   sqlc diff, govulncheck, test -race, the household_id grep gate), goreleaser config,
   CHANGELOG.md with an Unreleased section, SECURITY.md and CONTRIBUTING.md adapted from vink's.
2. Migrations for every table in the data model, sqlc queries with household_id as the first
   predicate, the fold package with docs/fixtures/fold.json covering every rule in the event
   table, and the property test that random orders converge.
3. Identity: persons, credentials, the device-key signature middleware, invites with a QR
   rendered server-side, memberships and roles, the Scope middleware, the setup page and the
   admin login.
4. POST /sync/v1 with cursors, limits and snapshots; the snapshot and retention job; the export
   zip including purchases.csv.
5. APNs silent push behind push.enabled, coalesced, with a test that proves zero outbound calls
   when it is off.
6. The admin pages and the guest view, server-rendered with htmx over tokens.css and one
   hand-written dm-* CSS file, with the icon sprite inlined; the voice and vocabulary rules
   apply to every string.
7. The cross-tenant and cross-person suites, the e2e smoke under scripts/e2e/, and a README in
   the siblings' voice with the hero banner from assets/brand/. Leave app/ as it is; the apps are
   the next prompt.

Work on a branch per step and open a PR for each; stop after step 7 and report what the gate
needs from me: a server reachable from a phone, then the apps' phase 0. Do not start phase 1.
Ask before deviating from docs/design.md; if something in it cannot be built as written, say
what and propose the smallest change.
```

## 1. Apps, phase 0

```
The server's phase 0 is in and reviewed. Now the apps, under app/ in this repository, in nt's
layout: app/ios and app/macos with XcodeGen project.yml each, app/shared for everything both
compile. Re-read CLAUDE.md, the sections of docs/design.md on the client side, lists, the apps and
security, and docs/design-system/README.md, in particular Voice, Colour, Type, iPhone and Mac apps
and Pictograms.

Build phase 0 for the apps, taking every default in the open-decisions table:

1. The two XcodeGen projects (as nt's app/ios and app/macos) with targets Doma and DomaTests
   each, over app/shared; GRDB pinned; the fonts from docs/design-system/fonts and the app icon
   already in app/ios; app/shared/Design/Tokens.swift mirroring docs/design-system/tokens.json
   with TokensTests that fail on drift; the custom SF Symbols exported from assets/icons/;
   the Makefile's mac-* and ios-* targets.
2. app/shared: the GRDB store keyed by (server_id, household_id), the Swift fold tested against
   docs/fixtures/fold.json by path, the outbox and cursor tables, the signed SyncClient, invite
   acceptance with the device key in the Keychain, background refresh and silent-push handling.
3. Screens: Scan, Lists, List with every ShopShop behaviour in the spec (match rows, quantity
   parsing, strike, clear, Recent, shop mode, long-press menu), Family with invites, guest links
   and members, Settings; the Mac target in a NavigationSplitView with the keyboard rules.
4. UI tests for add, strike, clear, offline add then sync, and invite acceptance from a QR image;
   snapshot tests for every screen in light and dark at two Dynamic Type sizes.
5. A TestFlight build.

Run against `make run` of the server in this repository. Work on a branch per step and open a
PR for each; stop after step 5 and report what the gate needs from me. Do not build Homes or Trip.
Ask before deviating from the spec or the design system.
```

## 2. Homes and trips, phase 1

Written 2026-11-05, to be pasted once phase 0's gate is met: the family's shared list has run on
doma for two weeks and ShopShop is deleted.

```
Phase 0 is in, reviewed and in the family's hands: the server released, the apps on TestFlight
and the Mac app on the Homebrew tap. Now phase 1, homes and trips. Re-read CLAUDE.md, then in
docs/design.md the sections "Homes, stock flags and trips", "Event log and sync" (home.*,
spot.*, staple.*, flag.set, photo.added and trip.arrived with their fold rules), "Shopping
lists" (the default list rule), "iPhone and Mac apps" (the Homes, Home and Trip screens,
photos), "Web" (the guest view's missing items) and "Security checklist" (photos); then
docs/design-system/README.md for the flag glyphs and the pictograms. docs/fixtures/fold.json
already holds flag and trip cases; a change to the fold is a change to the fixture first, on
both sides.

Build phase 1 in the order of its task list under "Testing, milestones, open decisions", taking
every default in the open-decisions table (photos 1600 px long edge, JPEG 0.8; staleness 60
days; five photos per spot), server first, then the apps:

1. Server: homes, spots, staples and flags with staleness in the fold and the materialised
   tables; "flag.set out" adds the item to the default list for that home when no entry is
   open; trip.arrived moves the flags; sqlc queries with household_id first; the fixture cases
   still open; the cross-tenant suite extended to every new route.
2. Server: photos. photo.added through sync, then the JPEG to POST /photos/v1/{household}/{photo_id}
   with the device-key signature; decoded and re-encoded (JPEG only, metadata stripped), a
   320 px thumbnail, the quota checked before and after the body (413), GET signed and cacheable
   1 h, the departure sweep and photos_per_spot retention; the admin's household page shows
   bytes used.
3. Server: the guest view's missing items for its home (staples flagged out, low or unknown,
   with age) above the list it already shows; make e2e flips a flag, derives a trip, commits it
   and checks the flags moved.
4. Apps: the Swift fold's new rules against the fixture; Homes and Home screens (spots, staples
   grouped by spot, the three flags as glyph and word, never colour alone, staleness fading to
   unknown, Take photos through the camera, nothing else modal, Edit for staples and spots); the
   "out" flag adding to the default list; the upload after photo.added is accepted, retried
   with the outbox; Dutch and Slovak for every new string.
5. Apps: Trip. Derived on the device from the two homes' flags: from and to pickers, a date,
   Bring, Buy and Check-on-arrival groups, Buy adding entries for the trip; Arrived commits one
   trip.arrived with what was packed; history under the home. The Mac has the same screens in
   the split view with the keyboard rules.
6. UI tests for a flag flip, a photo, a trip derived and arrived; snapshot tests for Homes, Home
   and Trip in light and dark at two sizes on both platforms; a TestFlight build and the Mac app
   through scripts/release.sh.

Run against make run of the server in this repository. Work on a branch per step and open a PR
for each; stop after step 6 and report what the gate needs from me: one trip between two homes
with nothing bought twice and nothing missing. Do not start phase 2. Ask before deviating from
the spec or the design system; if something in it cannot be built as written, say what and
propose the smallest change.
```

## 3. A second family, phase 2

Written 2026-11-05, reshaped 2026-11-06 (the App Store moved to the end of phase 3; the second
household and server, mostly built, became the first step), to be pasted once phase 1's gate is
met: one trip between two homes with nothing bought twice and nothing missing, on 0.4.1 or later.

```
Phase 1 is in, reviewed and in the family's hands: homes, flags, photos and planned trips,
released as 0.4.1 with the apps on TestFlight. Now phase 2, a second family. Its gate is a
second family joining a second household from TestFlight with no help beyond the QR, on a
server that came back from a backup. Re-read CLAUDE.md, then in docs/design.md "What a family
sees: onboarding, roles, vocabulary" (the five steps from install to list, the second household
and the switcher), "Data model and tenancy" (quotas, null is unlimited), "Web" (/admin/h/{id}
and /admin/server), "Observability of the server itself" and "Packaging" (metrics, backup,
docs/deploy/); then docs/design-system/README.md for the words a stranger reads first.

Most of the pieces exist: two households on one server and two servers on one phone (the
contexts, the switcher, the cross-tenant suite), quotas on the admin's household page with the
photo quota enforced, Back up now on /admin/server, the Prometheus collectors, the deploy files
under docs/deploy/. Phase 2 finishes them and proves them end to end. No new table, event, page
or config key is expected; ask if one turns out to be needed. The App Store is not in this
phase: it is the last feature of phase 3.

Build phase 2 in the order of its task list under "Testing, milestones, open decisions", taking
every default in the open-decisions table, server first, then the apps:

1. Second household and second server, finished. Server: the device quota enforced at invite
   acceptance (stored and shown today, never checked), refused in the family's words; make e2e
   runs two households with one person in both and reads them back from /api/v1/me; the
   cross-tenant suite extended to any route added since it was written. Apps: one UI test that
   accepts a second invite, switches, and sees each household's own lists; the badge counted
   per household; leaving the last household on a server removes its context.
2. Server: the backup and restore drill. Back up now writes the zip; a documented restore puts
   the DB, the photos directory and secret.key back on an empty data directory and the server
   comes up with every household, every photo and push still working; a script under scripts/
   runs the drill against a throwaway server in CI; README and docs/deploy/ say how.
3. Server: metrics and deploy verified. Every collector the spec lists present and named as it
   says, /readyz failing as specified, the dashboards' queries in docs/deploy/; the compose
   file brought up once on a clean host from the ghcr.io image, by hand and as a Portainer
   stack, setup done through the browser, an invite accepted from a phone; what was wrong fixed
   in the files. Nomad is gone: no job file, no mention.
4. Apps: onboarding polish for a stranger. The first screen, the camera permission text, the
   Paste a link fallback, the first list's one line of help, the empty Homes and Trip tabs, the
   notification ask after joining, every string in English, Dutch and Slovak; nothing a new
   member sees names a server, token or event. A TestFlight build at the end.

Run against make run of the server in this repository and the test host for the drills. Work
on a branch per step and open a PR for each; stop after step 4 and report what the gate needs
from me: a second family, their TestFlight invite and their QR, and a restore of the test
server from its backup. Do not start phase 3. Ask before deviating from the spec or the design
system; if something in it cannot be built as written, say what and propose the smallest change.
```

## 4. History and overviews, phase 3

Written 2026-11-06, the night phase 2 was concluded and 0.5.0 released, as the first phase-3
feature; the user asked about the family's buying habits.

```
Phase 2 is in and 0.5.0 is out: two households on one doma, the device quota, the restore
drill, the deploy checked against the homelab's stack, every word before the first list in
three languages. Now the first phase-3 feature, history and overviews. Re-read CLAUDE.md, then
in docs/design.md "History and quantities" (a purchase is a cleared entry, kept with qty, unit,
note, home, who and when; the overview screens read those rows and make no event), the apps
table and "Testing, milestones, open decisions"; then docs/design-system/README.md for the
rows, the mono face for data and the one left axis.

Build it on the apps alone, both platforms, no server change: the purchases are on every
device already. One screen, History, reached from a row at the foot of the Lists overview on
the phone and from the sidebar on the Mac; one month at a time, stepped back and forth under
the title, the latest month with a purchase first. In the month: per item, most bought first, with how many
times, the totals of qty by unit (an entry without a quantity counts one) and when last; per
home; who shopped, named as the family knows them, this device's person as "You". Numbers,
never a chart. Queries in the store with a logic test for months, items, totals, homes and
people; the screen in the snapshot suite on both platforms with purchases in the fixture; the
strings in the three languages. Write the screen into the spec's apps table and the design
system before the code; tick the phase-3 item when it is in. One branch, one PR, the usual
gates; stop at its gate, the family reading a month and finding it right.
```

## 5. Tasks lists, phase 3

Written 2026-11-07, after History and Not needed, as the user chose the order tasks, then
passkeys and the web client, then flag proposals, with the Watch app and the App Store parked.

```
History is in and a mistaken entry can leave a list without counting. Next, tasks as a third
list kind. Re-read CLAUDE.md, then in docs/design.md the lists section, the data model's lists
row and the event table's list.created row, the apps table and "Testing, milestones, open
decisions"; then docs/design-system/README.md for the overview rows.

One column, lists.kind, '' for shopping and 'tasks' for things to do, set once by list.created
and never changed; the fixture first, then the Go fold, the Swift fold, the schema on both
sides, the event schema. The same list screen with different words: to do, done, last done;
no home chips; what comes up while typing is kept apart by kind, the family's groceries do not
surface while typing a chore; a done task is no purchase, so History, the usual items of a
shopping list and the export's purchases leave it out; a trip cannot shop on a tasks list.
The overview offers Shopping or Tasks when a list is made and marks a tasks list with the
checklist symbol. A logic test for the kind, the names and the purchases, a picture of a tasks
list on both platforms, a UI test that makes one and strikes a task as done, the strings in
the three languages. Write it into the spec and the design system before the code; tick the
phase-3 item when it is in. One branch, one PR, the usual gates.
```

## 6. Passkeys and the web client, phase 3

Written 2026-11-07, after tasks lists, the second of the three features the user asked for in
one go (tasks, passkeys and the web client, flag proposals; the Watch app and the App Store
parked).

```
Tasks lists are in. Next, the member web client with passkeys. Re-read CLAUDE.md, then in
docs/design.md "Web: guest view, admin pages, later web client", the HTTP API's authentication
table, the Security checklist and the credentials row of the data model; then the guest view's
handlers and templates, which are the shape to follow.

Server-rendered htmx pages under /app on the same service layer, no offline support, the sync
endpoint stays the apps' path. Sign-in the first time by the phone: the browser shows a code,
Scan reads it, the app tells the server who sits there with a signed request; then a passkey,
a discoverable WebAuthn credential stored in the credentials table as kind passkey, through
go-webauthn, the one library, pinned. Sessions in memory like the admin's, CSRF on every form
and htmx request, the member cookie its own. Two steps: first the sign-in, the passkeys, Lists
and List with add, strike, Not needed and Clear, the vouch route on the API, Scan handling the
code on both platforms; then Homes, Home, Trip and Family. A Go test drives the whole flow with
a synthetic authenticator; a UI test pastes the code on Scan and sees the browser signed in.
The spec's web section, API tables and Security checklist, the Authelia example's open router,
SECURITY.md, the README and the changelog say it before the code; the phase-3 item is ticked
when the second step is in. One branch and one PR per step, the usual gates.
```

## Later phases

Phase 3 (one designed-for feature at a time; multiple server contexts were pulled forward on
2026-11-04) gets a prompt of the same shape for each feature when phase 2's gate is met: the
feature's task, the defaults, a branch and PR per step, stop at its gate. The App Store is its
last feature: the listing under the qualified name (EUIPO checked first), the privacy labels,
the screenshots from the snapshot harness, the review notes with a demo household and an
invite that stays valid, submission; its gate is a second family installing from the store.
