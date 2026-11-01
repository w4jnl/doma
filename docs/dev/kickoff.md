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

## Later phases

Phase 1 (homes, flags, photos, trips, guest links), phase 2 (public install) and phase 3 (one
designed-for feature at a time) each get a prompt of the same shape when their predecessor's gate
is met: the phase's task list, the defaults, a branch and PR per step, stop at the gate.
