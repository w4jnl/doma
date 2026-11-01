doma is the family's household app: shared and personal shopping lists, what is at each home,
and what to bring from one home to the other, as one Go server with an event log and native
iPhone and Mac apps. It lives at `github.com/w4jnl/doma` beside flok, vink and nt and shares
their bracket, weights, ground and type. Someone who knows the siblings should recognise doma as
one of them at a glance, and a family member who knows none of them should never notice there is
a system. The name is Slovak: *doma* is "at home", as in "čo máme doma?", what do we have at home.

## Voice

- Write like flok's README: plain, direct, honest about scope. Short sentences, no exclamation
  marks, no emoji.
- The product name is always lowercase: `doma`, never "Doma" or "DOMA", even at the start of a
  sentence. Start the sentence another way if it looks wrong. The one exception is the App Store
  listing, which Apple capitalises and which carries a qualified name (see Favicon and app icon).
- The family vocabulary is the only vocabulary: household, home, spot, item, list, flag, trip,
  member, owner, guest, invite, guest link. Never tenant, token, event, sync, server, credential,
  instance or device key on a screen a family member sees.
- Flags are lowercase words: have, low, out, unknown. Say "out since Tuesday", not "Missing!".
- Buttons are verbs that say what happens: "Add", "Clear", "Invite", "Arrived", "Take photos".
  Confirmations repeat the verb: "Really remove?".
- Errors say what is wrong and how to fix it, next to the thing: "That invite was used already.
  Ask for a new one." No apologies, no codes.
- Times are relative first ("3 wk ago", "yesterday", "in 2 days"), with the absolute time on hover
  on the Mac and in the detail on the phone.
- Strings ship in English, Dutch and Slovak from the first build, in one catalogue; a screen is
  not done until it reads well in all three. Sentence case everywhere; no uppercase labels.

## The mark

A terminal bracket holding a small house. The bracket is the same frame flok, vink and nt use.
flok's chevron is a bird in flight, vink's tick is the bird landed on the line, nt's two lines
are a note being written, each with the cursor under it; doma's glyph is a house drawn in line,
roof, walls and a chimney, and it stands alone. doma is the one mark without the cursor: the house
is the place the prompt went home to.

- Construction is on a 24-unit grid with flok's frame stroke, 1.6. The house is one closed path,
  8.6 wide at the eaves and 8.8 tall, corners rounded 1.0, centred in the bracket with 3.5 units of
  air to the arms on each side, with the chimney a 2.1-unit stroke on the right slope, drawn at 1.9 with round caps and joins. Lighter than the
  siblings' 2.9 glyphs on purpose: a closed outline at 2.9 fills itself in, and the roof alone would
  be flok's chevron. The chimney is what makes it a house, so it is never dropped, not even at
  16px. Thin frame, light house, nothing else.
- Ink: `mark` (cyan `#3FD0D4` on dark grounds, W4J teal `#12999D` on light). On a `brand` tile
  the mark is white.
- Something is out: `doma-mark-alert.svg` fills the frame solid and knocks out the house. At
  16–22px the eye catches value, not detail, so the state lives in the whole icon. The apps use it
  for the notification icon and a future menu-bar item; the web pages swap the favicon to it while
  a staple at the linked home is out.
- Clear space: one bracket width (3.9 units on the 24 grid) on all sides. Minimum size `mark-min`
  (16px); below that use the favicon tile.
- Never place the mark on a ground between `#4A5A5D` and `#A8B4B6` (the frame loses contrast).
  Never fill the house, add a door, a window or the siblings' cursor, remove the chimney, rotate
  it, recolour it per state, or put it outside the bracket.
- Lockups: `doma-lockup.svg` sets the mark beside the wordmark at flok's lockup spacing;
  `doma-lockup-tagline.svg` adds "what to buy, what is there, what to bring"; `doma-wordmark.svg`
  is `[doma]` for places without the mark, its brackets 7 units from the word's ink on both sides
  (placed by ink, not by advance, so the gap is equal whatever the last letter). All text is
  outlined; no font needed.
- In text the mark is `[⌂]`, and `⌈⌂⌉` in a narrow column.

## The w4jnl family

Every w4jnl tool uses the same system: the bracket frame, one glyph inside it, JetBrains Mono,
the `ground` colour, W4J teal (`brand`) as the tie, and a 6px `accent` bar on the left edge of
banners. flok's glyph is the chevron and cursor, vink's the tick and cursor, nt's two lines and
the cursor, doma's the house alone. Keep the bracket geometry identical across tools and
change only the glyph. doma's flag colours carry the same values as vink's states and nt's
(`have` = `up` = `ok`, `low` = `late` = `warn`, `out` = `down` = `alert`), with the same glyph
shapes, so a person who has seen one of them reads the others.

## Colour

- `tokens.json` is the source of truth; `tokens.py` writes `tokens.css` from it, and the apps
  mirror it in `app/shared/Design/Tokens.swift` with a test that fails when the two drift.
- Dark is the brand's home and the first theme; light is complete too. The apps follow the
  system appearance; the web pages follow `prefers-color-scheme`, and `data-theme` forces one.
- `ground` is the screen. `surface` raises a selected row, an open sheet, the match rows under
  the add field. `surface-sunk` recesses text fields and the QR card. `line` separates rows and
  divides open entries from struck ones; it is decorative only.
- Set text in `ink`, secondary text (quantities and notes after an item, who and when, the age of
  a flag) in `ink-muted`, placeholders and struck entries in `ink-faint`.
- `accent` is the only interactive colour: the add button, links, the selected tab, a pressed chip,
  the current household in the switcher, the focus ring. Text on an accent fill is `on-accent`.
  A selected row sits on `accent-soft` with the family's accent bar at its left edge, as in nt.
- Flag colours mean a flag and nothing else: `have`, `low`, `out`, with their `-soft` fills for
  pills and home-card counts. `unknown` is `ink-muted`: an absence, not a state. `out` also marks
  destructive buttons once armed, with `on-out` text.
- Every flag and list state has its own glyph and word, so the UI reads in greyscale and to
  colour-blind people. Never show a flag by colour alone, and never use a flag colour for anything
  that is not a flag (not a tab, not a chart, not a decoration).

| kind | state | glyph | token | colour |
| --- | --- | --- | --- | --- |
| flag | have | `●` | `have` | green |
| flag | low | `◐` | `low` | orange; half a jar left |
| flag | out | `◆` | `out` | red; it is also on the shopping list now |
| flag | unknown | `◌` | `unknown` → `ink-muted` | grey; the home screen asks "Still there?" |
| entry | open | `○` | `ink` | the text in `ink`, the glyph in `ink-muted` |
| entry | struck | `✓` and the text struck through | `ink-faint` | grey; the strike says it |
| entry | for a home | the home's name as a chip after the item | `ink-muted` on `surface` | no colour |
| trip | bring | the item with its from-home flag | its flag colour | the group says what to do |
| trip | buy | the item with an *Add to list* button | `accent` on the button only | |
| trip | check on arrival | `◌` | `unknown` | grey |
| photo | pending upload | the thumbnail at 50% with a small `◌` | `ink-muted` | |
| sync | offline | one small badge in the toolbar: `◌ offline` | `ink-muted` | never an alert; the next sync catches up |

- All text pairs named in the token notes are 4.5:1 or better in both themes; control borders and
  the focus ring 3:1 or better. `ink-faint` is below that by design and only carries struck text
  and placeholders.

## Type

- JetBrains Mono (700 for the wordmark and headlines, 400 for the tagline and data) is the brand
  face, as in the siblings. The three weights ship in `fonts/` (SIL Open Font License); embed
  them and never load them from a CDN.
- In the apps the UI is set in the system face: SF Pro Text 17 for item names and body, SF Pro
  Display semibold for screen titles (28) and section headings (20), 15 for secondary lines, all
  through Dynamic Type so nothing is a fixed point size. UI words are never mono.
- JetBrains Mono, bundled from `fonts/`, for what a person reads as data: quantities and units
  after an item (`2x`, `500 g`), times and ages, the invite code under a QR, anything in Settings
  that is copied. Tabular figures always.
- On the web pages (guest view, admin) the same split: `font-sans` for UI words, `font-mono` for
  data, one `title` per page, sentence case, no uppercase labels.

## iPhone and Mac apps

The simplicity budget: four tabs, at most one list and one detail per screen, no screen with more
than one text field apart from Scan. Anything that does not fit is a long-press item or a Settings
row, not a new screen.

- **Tabs.** Lists, Homes, Trip, Family, in that order, with SF Symbols (see Pictograms). On the
  Mac the same four are sidebar sections. The household name is the title; a switcher appears in
  its place only when the person is in more than one household.
- **A list.** Rows `row-h` (44pt) with hairlines in `line`; no cards, no zebra. The add field sits
  at the top under the title and moves to the bottom in shop mode. Match rows appear under it on
  `surface`, at most eight, the first one preselected on `accent-soft`. An entry row is the glyph,
  the item name in `ink`, then quantity, unit and note in mono `ink-muted`, then a home chip if the
  entry is for a home. Struck rows sink under one `line` divider, newest first, text struck and in
  `ink-faint`. *Recent* is a collapsed group at the foot.
- **Shop mode.** Rows grow to 56pt, type one step larger, the screen stays awake, the add field
  goes to the bottom. Nothing else changes: no new colours, no new controls.
- **A home.** Staples first, grouped by spot where an item is pinned to one, each row the flag
  glyph and word at the right, the item at the left, and the flag's age in mono `ink-muted` once it
  passes half the staleness threshold. An unknown staple shows three small buttons, have / low /
  out, in that row. Spot thumbnails at `thumb` (72pt) and `radius-md` in a horizontal strip above
  the staples; *Take photos* is one button in the toolbar.
- **Trip.** Two pickers in one row, from and to, with the swap control between them; then three
  groups, Bring, Buy, Check on arrival, each a plain list; *Arrived* is the one primary button, at
  the bottom, enabled only while something is packed.
- **Family.** Members as rows with name, role word and last seen; invites and guest links as
  rows with their expiry; *Invite* and *Guest link* in the toolbar. An invite opens a sheet with
  the QR on `surface-sunk` at `radius-md`, the share button under it, and the link in mono.
- **Scan.** The first screen before any household: the camera full-bleed, the mark above it, one
  line of help, *Paste a link* as a text button. It is also Family → Add.
- **States and feedback.** Glyph and word, as everywhere. Optimistic everywhere: the row appears,
  strikes or moves on the tap. A sync failure is one small `◌ offline` badge in the toolbar,
  never an alert. Destructive actions arm in place (*Remove → Really remove?*); no modals except
  the camera and the system share sheet.
- **Keyboard on the Mac.** `⌘N` new list, return adds, space strikes the selected row, `⌘⌫`
  clears, `⌘1`–`⌘4` the sections. Nothing else.
- **Accessibility.** Dynamic Type on every row, VoiceOver labels that say glyph and word
  ("out, olive oil, since Tuesday"), 44pt targets, and a Reduce Motion check before the one
  animation (a struck row sinking).

## Web pages

The guest view and the admin pages are server-rendered with htmx, in vink's structure: load
`tokens.css`, then the page CSS, no framework, no inline styles. They are one column at
`content-max` (720px), left-aligned, on `ground`.

- **Guest view.** The home's name as the title, then *Missing* (staples flagged out, low or unknown
  with glyph, word and age) and the linked list with the same add, strike and clear as the app.
  No top bar beyond the mark and the list's title; a 24-hour cookie after the first open.
- **Admin pages.** vink's settings-tab layout: a top bar with the mark, Households and Server,
  rows in a `Panel`, inline add and edit, one primary per panel. Values the operator does not own
  (a member's role, a family's lists) are counts and metadata only.
- **Setup page.** One card on `ground` with the mark above it, three fields, one button. It never
  renders again.
- Live parts poll only while the tab is visible (the guest list every 10 s) and use `ETag`.

## Pictograms

Monoline icons on a 16 grid, 1.5 strokes, round caps and joins, drawn in `currentColor`, in
`assets/icons/` with a sprite (`doma-icons.svg`) for the web pages and one file per icon for the
asset catalogue. No emoji, no icon fonts. Never an icon without a word or `title` nearby.

| icon | meaning | SF Symbol in the apps |
| --- | --- | --- |
| `have` `low` `out` `unknown` | the four flags | custom symbols from these files, so the shapes match everywhere |
| `open` `done` | a list entry to get, a struck entry or a done task | custom symbols |
| `list` | a shared list; the Lists tab | `list.bullet` |
| `personal` | a personal list | `person` |
| `home` | a home; the Homes tab; the mark's house with its chimney | custom symbol from `home.svg` |
| `spot` | a drawer, shelf or cabinet | `tray` |
| `item` | an item, the jar | custom symbol from `item.svg` |
| `photo` | a spot photo, the departure sweep | `camera` |
| `trip` | the Trip tab | `arrow.right` |
| `family` | the Family tab, members and roles | `person.2` |
| `guest` | a guest on a link | custom symbol from `guest.svg` |
| `basket` | shop mode | `basket` |
| `qr` | an invite or a guest link | `qrcode` |
| `add` | add | `plus` |
| `clear` | clear struck entries | `tray.and.arrow.down` |

The rule: a system symbol wherever Apple's shape says the same thing, so the apps feel native;
a custom symbol only where the shape is the brand's (the flags, the home, the jar, the guest).
Custom symbols are exported from the 16-grid files as SF Symbol templates in two weights.

## Favicon and app icon

- `favicon.svg` is the teal tile with the white mark; `favicon-alert.svg` the `out` tile with the
  white alert mark, for the guest view while a staple at that home is out.
- `doma-appicon.svg` is the Mac and phone app icon: flok's recipe, the cyan mark on a dark
  gradient tile with a heavier frame and house. The App Store wants it flattened without an alpha
  channel; `render.py` writes that PNG. The icon is deliberately the family's, not a cartoon
  house: on a phone full of bright icons it is the quiet dark one.
- The App Store listing is "Doma – lists, homes, trips" (or a variant that passes), because the
  bare name is taken; the icon and every screen still say `doma`.

## Assets

- Logos: marks (`currentColor`, teal, cyan, alert), the lockup, the tagline lockup and the
  wordmark, in `assets/brand/`. They use `currentColor` so docs and templates can tint them.
- Tiles: favicon, favicon-alert, `doma-tile.svg` (avatar 460px and the 512px icon) and the app
  icon, on the `brand` tile at `radius-tile`.
- Banners: the README hero (1280×320) and the social card (1280×640), in the family's layouts on
  `ground` with the 6px `accent` bar.
- Icons: the pictograms in `assets/icons/`, with `icons.png` as the sheet.
- `assets/brand/gen.py` writes every SVG from one geometry; `render.py` renders the PNGs;
  `assets/icons/gen.py` writes the pictograms. See `assets/brand/README.md`.

## Consuming this system

- Go: `tokens.css` and `fonts/` ship in `internal/http/web/static/` by `embed.FS`; the sprite is
  inlined once in the layout template; the admin and guest pages use the `dm-*` classes of one
  hand-written CSS file, in vink's structure. No hex value anywhere outside `tokens.css`.
- Swift: `app/shared/Design/Tokens.swift` holds the colours in both themes as `Color` with dynamic
  providers, the glyph strings, and the sizes; `TokensTests` parses `docs/design-system/tokens.json`
  and fails when the two drift. The custom SF Symbols live in `app/shared/Design/Symbols.xcassets`.
  The apps bundle `fonts/` for data text only.
- `make brand` runs the three generators and `render.py`; it needs Python with fontTools, brotli,
  cairosvg and Playwright's Chromium, and no network.
