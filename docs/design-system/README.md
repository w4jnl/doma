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
- A list has one of six colours, `list-1` to `list-6` (teal, sky, violet, plum, gold, moss),
  chosen when it is made and carried on its events; the default list wears `accent`. It shows
  as the dot before the list's name and nowhere else. The six keep at least 15 degrees of hue
  from every flag colour and 4.7:1 or better on both grounds, so a list is never read as a state.
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
| list | any | a dot before the name | `list-1` to `list-6`, the default list `accent` | which list, never a state |
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
  Mac the same four are sidebar sections. The Lists tab opens into the last-used list, with a
  *Lists* button at its top left for the overview; a second tap on the tab does the same. The
  icon's badge counts what this device has not seen (entries others added since each list was
  last in front); the overview and the sidebar put an 8pt `accent` dot before a list's count
  while it holds unseen entries, and a list dots the symbol of each new row for that visit. The
  household name is
  the Family screen's subtitle and a switcher over households takes the title's place only when
  the person is in more than one. Section words are subheadline in `ink-muted`, never capitals.
  The list itself is a plain list on `ground`; the Lists overview, Family and Settings are the
  phone's grouped inset lists, rows on `surface`, help lines as section footers, and plain
  lists on the Mac. The accent belongs to what makes something: Add, New list, Invite, the
  selected tab; one prominent button per screen at most (Invite on Family), everything else a
  plain toolbar item. Remove and Revoke live behind a swipe and the long-press menu and arm in
  the row (*Really remove?* on `out`); Leave is a row, an `ink-muted` word until armed. On the
  phone Settings, an invite and a guest link open one level down, never as a sheet; the phone's
  first frame is the launch colour, the `ground` token.
- **A list.** Entry rows `row-h-list` (52pt) with hairlines in `line`; no cards, no zebra. On
  the phone the add bar is a glass capsule floating at the bottom over the tab bar, the one
  glass in the app: an `accent` disc with a `+` in `on-accent` at its left, the field with no
  box, the mic at its end with the language code (EN, NL, SK) in mono under it: `accent` at
  rest, `mic.fill` pulsing in `out` while it listens, a small spinner while the model is fetched
  once; a tap of it is a light impact, then the start haptic when it listens and the stop one
  when it stops; the match rows and the usual chips stack above it in the same glass. On the Mac the bar
  is pinned under a hairline on `ground`. Match rows are at most five, the best nearest the bar
  on `accent-soft`; with the field empty, one row of chips with the usual items. The divider
  between open and struck rows is a row, never a pinned header.
  An entry row is the custom `open` or `done` symbol in a 24pt column in `ink-muted` (never the
  glyph as a text character), the item name in `ink`, the note after it in the system face in
  `ink-muted` (a note is words, not data), a home chip (`surface` capsule with a `line` ring,
  24pt tall, caption text) and the quantity in a mono `ink-muted` column of at least 48pt at the
  right. Hairlines start under the name, not under the symbol: every screen keeps one left axis,
  a 24pt column, a 12pt gap, text at 52pt. Under the title sits the list's dot and "N to get" in
  subheadline, on both platforms; the number rolls when it changes. A strike pops the symbol
  once in `accent`, draws a line in `ink-muted` across the name and turns the text `ink-faint`;
  the row stays put for 1.5 s and then sinks under the divider, which reads the got count in
  mono at the left and *Clear* in `accent` semibold at the right, present only while something
  is struck. *Recent* is a collapsed group
  at the foot in `ink-muted`. A list with nothing on it shows the mark small and one line of
  help under the title; the title's subtitle says how many are still to get. There is no shop
  mode: one layout, the screen awake while a list is in front.
- **History.** A row at the foot of the Lists overview, the clock-arrow symbol in the 24pt column
  and this month's count in mono, opens it. Under the title, the month between two chevrons in
  `accent` (a chevron `ink-faint` when there is nowhere to go), the title's subtitle "N bought".
  Then Items, each row the name in `ink` with "N times, last …" in footnote `ink-muted` under it
  and the totals per unit in mono `ink-muted` at the right; Homes and Who shopped as name and a
  mono count. Rows take the list's height, insets and `ground`; an empty month is one line of
  help. Numbers only, never a chart: the family reads what was bought, it does not analyse it.
- **A home.** Staples first, in their order, in rows of a list's height and insets on `ground`,
  each row the flag glyph and word at the right, the item at the left, and the flag's age in mono
  `ink-muted` once it passes half the staleness threshold. An unknown staple shows three small
  buttons, have / low / out, in that row. A staple is typed into the same add bar a list has, its
  row offers Rename and Remove on a swipe and a long press drags it into place; there is no Edit
  mode. Spot thumbnails at `thumb`
  (72pt) and `radius-md` in a horizontal strip below the staples, a dashed `+` tile at its end;
  *Take photos* is one button in the toolbar.
- **Trip.** The tab is the trips: upcoming by date, nearest first, each row "Gouda → Hut", the
  date and how many to bring and to buy; the past ones under History with what moved; `+` plans
  one. A trip opens into two pickers in one row, from and to, with the swap control between
  them, the date and the list; then three groups, Bring, Buy, Check on arrival, each a plain
  list; *Arrived* is the one primary button, at the bottom, enabled only while something is
  packed.
- **Family.** Members as rows with name, role word and last seen; invites and guest links as
  rows with their expiry; *Invite* prominent and *Guest link* plain in the toolbar. An invite
  opens one level down on the phone and a sheet on the Mac, with the QR on `surface-sunk` at
  `radius-md`, the share button under it, and the link in mono on one line.
- **Scan.** The first screen before any household: the camera full-bleed, the mark above it, one
  line of help, *Paste a link* as a text button. It is also Family → Add.
- **States and feedback.** Glyph and word, as everywhere. Optimistic everywhere: the row appears,
  strikes or moves on the tap. The haptics say how much changed: a soft tap for an add, a firmer
  one when the item was on the list already, a light impact for a strike, a selection tick for
  a put back, a warning when a destructive button arms and a medium impact when it fires, a
  success on a clear; nothing on scroll, drag or navigation, and nothing for what another
  device did. The Mac has no haptics; the symbol, the rolling count and the flash carry it. A
  row that arrives, yours or another phone's, shows on `accent-soft` for a breath; yours also
  scrolls into view. A struck row names who got it, in caption `ink-faint` after the item, when
  it was someone else and the household has more than one member; never who is shopping now.
  The family's doma out of reach is one small `◌ offline` badge in the toolbar after the second
  failed exchange, never an alert; after a minute it says since when; when the spell ends and
  something went up, the badge says `✓ caught up` once, for 1.5 s. Settings' About row is the
  one place the wordmark appears: the mark, `doma` in mono bold, the version in mono muted. A
  notification, when the person allows them, says who added what to which list or who cleared
  it, in the same words as the row, under the list's name; never for the person's own changes,
  never a check, and nothing of the app's own while it is in front. Its sound is the app's own
  soft two-note chime (`chime.caf`, A4 then E5, a second and a half, slow attack, long decay),
  the only sound in doma; the app itself stays silent. Words come at most every two minutes per
  device and then cover everything since; Settings has a switch per shared list and one for
  clears, so a chatty list can be quiet. The lock, when asked for, is the ground with the mark
  and one *Unlock* button, nothing of the lists behind it; *Lock after* says how long away
  counts, from at once to until tomorrow. Seen marks move only while the app is active and the list on screen,
  so what arrives while the phone is locked is still new when it is opened, and the badge is
  counted from the store after every sync, not from a screen. Nothing moves on a timer. Destructive
  actions arm in place (*Remove → Really remove?*), the pill springing in and fading back after
  4 s; no modals except the camera and the system share sheet.
- **Motion.** Three durations and nothing else: `motion-quick` (150 ms) for a crossfade, a
  chip or match row, a label; `motion-base` (250 ms) for a row arriving or leaving, a count
  rolling, a badge, an armed button; `motion-settle` (350 ms) for rows closing a gap. A row
  arrives from below and leaves by fading; a struck row fades out where it is and in under the
  divider, never flying; Clear fades the struck group, then Recent or the empty state follows
  after a quick delay; the match stack grows and shrinks from the bar; the Recent chevron turns.
  Not animated: tab switches and pushes beyond the system's, the Mac pane on a sidebar click, the
  1.5 s hold (no countdown), scrolling, polling, the glyphs' shapes, reorder beyond the system's
  lift, and never a cascade: the list arrives whole.
- **The Mac.** The sidebar lists the household's lists, then *Just me* when there are any, then
  Family, selection in `accent` (the app's accent colour is the token, in the asset catalogue, so
  the system draws it), the open count as the system's badge in mono; *New list* at the
  sidebar's foot is a plain accent button whose menu offers *Just me*; it opens one field in the
  sidebar, return creates, escape cancels. A right-click on a list offers *Rename* (in the row),
  *Colour* (the six names), *Share with the family* on a personal list, and *Archive*, armed in
  place. The pane hangs off the left at
  `content-max`: the list's name in title weight with the dot and count under it, rows at
  `row-h-compact` (32pt) with hairlines from the text column, a hovered row on `surface`, the
  selected row on `accent-soft`. A click selects a row, the symbol strikes it (and turns
  `accent` under the pointer), a double click or return edits it in the row, escape leaves a
  field for the list. The add row is the last row of the open items, the plus in the symbol
  column and the field after it; matches drop down under it, best first; the field is live only
  on an empty list, and typing with the list in front starts an entry. A right-click on a row
  offers *Got it* or *Put back*, then *Edit*. Settings is the Settings window (`⌘,`); the Family
  toolbar has no gear on the Mac, and an invite or a guest link opens as a popover from its
  button. Tooltips say what a symbol does. Mono sizes follow the platform's text styles: the
  Mac's body is 13pt, subheadline 11, footnote 10.
- **Keyboard on the Mac.** `⌘N` new list, return adds or edits the selected row, escape leaves a
  field for the list, space or `⌫` strikes the selected row, `⌘E` edits, `⌘⌫` clears, `⌘1`–`⌘4`
  the sections, `⌘,` Settings. Every shortcut is in the menu bar. Nothing else.
- **Accessibility.** Dynamic Type on every row, VoiceOver labels that say glyph and word
  ("out, olive oil, since Tuesday"), 44pt targets. Reduce Motion removes displacement and scale
  and keeps opacity and haptics: nothing slides, sinks, grows or pops; what remains is a
  `motion-quick` crossfade or an instant swap, and every haptic still fires.

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
| `basket` | reserved; shop mode is gone | `basket` |
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
