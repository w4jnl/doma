<p align="center"><img src="assets/brand/doma-hero.png" alt="doma: what to buy, what is there, what to bring" width="800"></p>

[![ci](https://github.com/w4jnl/doma/actions/workflows/ci.yml/badge.svg)](https://github.com/w4jnl/doma/actions/workflows/ci.yml)

doma is the family's household app: shared and personal shopping lists, what is at each home,
and what to bring from one home to the other. One Go binary with SQLite serves the iPhone and
Mac apps and a guest page, and nothing leaves your network except a silent push through Apple,
and that only when you turn it on.

A phone types "melk", taps the match, strikes it in the shop, clears the list; every other phone
in the household shows the same list a few seconds later, and keeps working in a basement
without signal. Homes carry a flag per item, have, low or out, and a trip from one home to the
other turns the flags into a bring list and a buy list.

## Setup

Not released yet; phase 0 runs from source. Linux on amd64 and arm64 for the server.

1. Run it. With Docker, on a named volume for `/data`:
   ```sh
   docker run -d --name doma -p 8080:8080 -v doma-data:/data -e DOMA_SERVER_BASE_URL=https://doma.example.com ghcr.io/w4jnl/doma
   ```
   Or from source, with Go 1.27 or newer and no cgo:
   ```sh
   make build && ./bin/doma serve      # listens on :8080, writes doma.db and secret.key in the working directory
   ```
2. Open the address in a browser. The first visit shows the setup page: a name and a password
   for the admin pages, three fields, once.
3. Create the household on the Households page: a name, a time zone, the first home. Open it
   and make the owner invite: a QR code, shown once.
4. Scan the QR with the doma app. The phone is in, as owner. Owners invite the rest of the
   family from the app's Family screen; the lists appear on each phone as it joins. A Mac joins
   the same way: `brew install --cask w4jnl/tap/doma`, then an invite from Settings, Add a device.

Put the server behind the reverse proxy you already run, terminating TLS. doma authenticates
every route itself, and the invite and guest links must open from a phone on mobile data, so
the proxy's own sign-in, if you want one, goes in front of the admin pages only; with
`admin.auth = "proxy"` doma then takes the admin from the proxy's `Remote-User` instead of asking
for its own password. `docs/deploy/` has a systemd unit, a compose file (which is also what a Portainer stack takes), a Traefik
snippet, and under `authelia/` a compose stack with Traefik and Authelia that does exactly that.

## Why doma

The problem:

- A shared list app is where the family's buying habits live, and they live on someone else's
  server, in someone else's format, until the app goes away.
- Two homes mean the same olive oil is bought twice or forgotten, and nobody remembers what was
  in the cabin's fridge in October.
- Household apps grow screens; the family uses one list.

What doma does about it:

- One append-only log per household and one fold on every side, so phones work offline and
  merge without conflicts, and the purchase history is kept from the first day without the list
  ever growing.
- Flags, not counts: whoever notices says have, low or out; silence fades a flag to unknown; a
  trip moves the flags along with the boxes.
- Onboarding by QR: no accounts, no passwords, no URLs typed, no command line for anyone but
  the operator, who gets three fields and a browser.
- Your server, your SQLite file, an export in JSON, CSV and Markdown whenever you like.

## Features

- **Lists** with the mechanics of the app the family already knows: type, match against
  everything ever typed, tap to add, tap to strike, clear. Quantities and units are read from
  the line ("1,5 l melk"); anything else stays in a note. Shared lists for the household,
  personal lists that nobody else can see, even through the log.
- **History** from day one: every cleared entry keeps item, quantity, who and when, for the
  export now and for overviews later.
- **Homes, spots, flags, trips**: a flag per item per home, have, low or out, fading to unknown
  when nobody has looked for a while; staples a home should always have; out puts the item on
  the list for that home. A spot keeps a picture, taken before leaving, scaled and stripped on
  the server, five per spot within the household's quota. A trip from one home to the other is
  derived from the two homes' flags: bring, buy, check on arrival; Arrived moves the flags in
  one go. The guest page shows a home's missing staples.
- **Guest links**: an owner gives the cleaner or a visiting relative a link to one home and one
  list, valid a week, revocable, with add, strike and clear and nothing else about the family.
- **Admin pages** for the operator: households as counts and metadata, the owner invite,
  quotas, export, backup, the APNs key, a second step on sign-in. Never the family's content.
- **Sync** with a device key per phone, five hundred events a page, snapshots for a phone that
  was away too long, retention of the log without losing a single purchase.
- **Push**: one silent notification per phone per thirty seconds through Apple, behind
  `push.enabled`, and provably no outbound connection when it is off.

## Scope and status

doma is one family's app, published in the shape of its siblings. Phase 0, the server and the
lists in the iPhone and Mac apps under `app/`, is in the family's hands; phase 1, homes, flags,
photos and trips, is built and waits for its gate, one trip between two homes with nothing
bought twice and nothing missing. Then a second family, from TestFlight; the App Store comes last. The roadmap and every design decision are in [`docs/design.md`](docs/design.md); the
brand and UI rules in [`docs/design-system/`](docs/design-system/README.md).

## How it works

Every change a person makes is one event: `entry.added`, `flag.set`, `trip.arrived`. The phone
writes it to its outbox and folds it into its own tables in the same transaction, so the screen
is right before any network. `POST /sync/v1` carries the outbox up; the server validates the
event, appends it to the household's log with a sequence number, folds it into the same tables
with the same rules, and tells the other phones to pull. Ordering is by a hybrid logical clock,
never a phone's wall time, and the fold gives the same tables whatever order events arrive in,
which is what lets two phones strike the same list in the same shop. The materialised tables are
a cache: a test rebuilds them from the log.

Households are the tenant. Every query on family data filters on the household, personal lists
add the person, a guest adds the home and the list, and anything outside the caller's households
is a 404, never a 403.

## API

Three surfaces on one router: `POST /sync/v1` for the apps, `/api/v1` for everything that is not
an event (members, invites, guest links, devices, export), and the pages. App requests carry a
signature over method, path, timestamp and body with the phone's Ed25519 or P-256 key. Errors
are RFC 7807 problem documents. The specification is served at `/api/v1/openapi.yaml` and
checked against the router by a test.

## Configuration

`doma.toml`, every key overridable as `DOMA_SECTION_KEY`, and a string value of the form
`env:NAME` read from the environment. `docs/deploy/doma.toml.example` lists every key with its
default; `/admin/server` shows the effective, redacted configuration. The defaults put the
database in the working directory with the photos, the snapshots and the key files next to it.

## Security

The attack surface is named in [`SECURITY.md`](SECURITY.md): the device signature, the invite
and guest tokens, the photo upload and the admin login, and what stands in the way of each. The
server makes no outbound connection except to APNs, and none at all when `push.enabled` is
false; CI greps for dials, and a test runs the whole process from setup to a synced event with
every dialer wired to fail.

## Development

`make build`, `make test`, `make lint`, `make e2e`. [`CLAUDE.md`](CLAUDE.md) has the layout, the
house conventions and the gates; [`CONTRIBUTING.md`](CONTRIBUTING.md) what is welcome.

## Credits and licence

doma is MIT licensed (see `LICENSE`). The list mechanics are ShopShop's, which the family used
for years. htmx (Zero-Clause BSD) and JetBrains Mono (SIL OFL) are vendored with their licences.
