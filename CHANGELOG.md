# Changelog

User-facing changes per release, newest first. `scripts/release.sh` refuses to tag a version
that has no section here and uses the section as the GitHub release notes, so every release
updates this file first. Dates are the tag dates.

## Unreleased

- **Tidy the items from History.** A swipe on an item row in History (the row's menu on the
  Mac) offers Rename and Merge into. Rename changes the name on every list, at every home and in
  every past month. Merge into folds a misspelled or duplicate item into the one to keep, picked
  by typing its name, armed in place; its purchases count under the kept item from then on and the
  old spelling still finds it while typing. Merge was a Mac-only action on a list row until now.
- **Retire an item.** The third action on a History row, armed in place. A retired item leaves
  typing, the usual items, Recent and History; its purchases stay in the export and come back
  with it when someone types its name again in full. A new event, `item.archived`,
  with its fold rule in both folds and the fixture.
- **A blind strike is harder.** A strike and a restore are felt as a firm tap, the row keeps its
  place for two and a half seconds with *Put back* or *Got it* at its edge, and on the phone a tap
  in the first half second after the list or doma comes to the front is ignored. Settings, under
  Lists, turns that off or makes it one or two seconds.

## 0.6.1 (2026-11-07)

- **Fixed: the admin pages behind the proxy on a server that never had a password admin.** With
  `admin.auth = "proxy"` from the first day, the root page sent the admin to Set up doma and the
  Server page failed, both because the password admin's row was missing. The root goes to the
  admin pages, Set up is gone, and the Server page renders without the row.

## 0.6.0 (2026-11-07)

- **From the pictures.** Behind `vision.enabled`, a vision model the server is pointed at looks
  at each new photo of a spot and suggests which staples look low or out. The home screen shows
  the suggestions first, each with Accept and Keep. Off by default; nothing reaches the model
  otherwise. The model is an OpenAI-compatible endpoint, in your own network or not, or Claude
  with `vision.provider = "anthropic"` and an API key.
- **The web client.** The family's lists in a browser at `/app`: the first sign-in by scanning
  the browser's code with the app, or with the camera, whose page hands the code to doma with
  one tap, then a passkey. Lists and a list with add, strike, Not needed
  and Clear; homes with their staples and flags; trips planned, derived and arrived; Family with
  invites, guest links and the person's devices.
- **Tasks lists.** A new list can be for tasks instead of shopping: the same typing, striking
  and clearing, with done instead of got, its own names while typing, and no purchases in
  History or the export. The overview marks it with the checklist symbol.
- **Not needed.** The swipe on a list row, next to Edit, takes an entry off the list without
  counting it as bought, for the mistakes and the changed minds. History, Recent and the usual
  items no longer see them. On the Mac it is in the row's menu.
- **History.** At the foot of the Lists overview, a month at a time: what was bought, how many
  times and how much per unit, for which home, and who shopped. Read from the purchases every
  phone already keeps; nothing new is sent.
## 0.5.0 (2026-11-06)

Phase 2, a second family: a household's devices have a quota, the admin can delete any
household, a backup restores with one script and the drill proves it, the deploy files are
checked against a running stack, and every word a stranger meets before the first list is in
the three languages. On the home, staples are typed, said and dragged as entries are on a list.

- **Pictures pass a proxy sign-in.** The Authelia example's open router gains the photo
  paths, which it and its test had missed: on a host with Authelia in front, pictures could
  neither go up nor come down. A stack built from the example needs the same line.
- **Metrics documented and held to the spec.** `docs/deploy/metrics.md` has the scrape
  config, a dashboard's queries and the alerts; a test keeps every collector's name and
  labels as the spec lists them. The compose file was brought up from the published image
  and walked through setup, a household, an invite, the probes, the metrics and a restart.
- **The permission questions speak Dutch and Slovak.** The camera, microphone and speech
  questions the phone asks on the first scan and the first spoken item follow the app's
  language, as every other word before the first list already did.
- **Restore is drilled.** `scripts/restore.sh` puts a backup zip onto an empty data
  directory, the README says when and how, and `make e2e` backs a live server up, restores
  it and finds every household, device, photo and the admin's second step working.
- **The admin can delete a household with members.** Asked twice on the household's page;
  everything goes, and members left with no household go with their devices. A phone whose
  household is gone keeps its other households syncing, and *Leave this household* removes
  the deleted one from it.
- **A household's devices have a quota.** When the admin has set one, an invite that would
  bring one device too many is refused with a plain message; a rejoin takes no seat and a
  removed device frees one. The e2e smoke now joins a second household with the same key, and
  a UI test joins one from Family and switches.
- **Staples drag into order.** A long press on a staple moves it, as on a list; a new staple
  lands at the end. The home's rows now sit as a list's do.
- **A staple can be said.** The home's add bar has the list's mic: the words land in the
  field, a pause adds them, and one spoken line splits into the staples it names the way a
  list's does. A quantity said or typed with a staple is dropped from its name.
- **A home edits like a list.** No Edit button: a staple is typed into the bar at the bottom,
  with the catalog's matches above it, and a swipe or a long-press on its row offers Rename
  and Remove, armed in place. Renaming a staple renames the item everywhere. The spots' pictures
  moved below the staples, with a `+` at the end of the strip for a new spot and Rename and
  Remove on a long-press.
- **The Nomad job is gone.** The homelab runs compose, by hand or as a Portainer stack; `docs/deploy/`
  keeps the systemd unit, the compose file, the Traefik snippet and the Authelia stack.

## 0.4.1 (2026-11-05)

Planned trips, for the phase-1 gate: a trip is from, to, a date and a list, shared with the
household, and reads only its own list.

- **Trips are planned and shared.** The Trip tab lists the upcoming trips by date and the past
  ones under History; `+` plans one: from, to, a date and the list it shops on, kept in the
  household's log like everything else, so every phone sees the same itinerary. A to-home's
  needs show on the nearest upcoming trip to that home and nowhere else; Add to list goes to
  the trip's list, a long-press offers the others, and only the trip's list says what is on
  it, so the regular groceries on another list stay out of the trip; a trip is cancelled from
  its row, armed in place, and Arrived moves it to History. A trip nobody planned, arrived from
  an older app, keeps the arrival as its date.
- **The apps' store gets every migration.** A migration registered in a `defer` after the
  migrator was already copied out never ran; the entries index it carried arrives now, with the
  trips table's new columns.
- **An item's use count stays right when a name changes hands.** Two items that swapped an
  entry during a rename could leave one of them counted a purchase too many, depending on the
  order the changes arrived in; both are counted again once every row is where it belongs.

## 0.4.0 (2026-11-05)

Phase 1: homes, flags, photos and trips. The gate is one trip between two homes with nothing
bought twice and nothing missing.

- **Homes, flags and trips in the apps.** Two new tabs. Homes shows each home with what it
  misses and its spots' pictures, and makes a home. A home lists its staples with the flag as
  glyph and word, the age once it passes half the staleness, three small buttons on a staple
  nobody has answered for, then the other items flagged there and the trips through it; Edit
  adds staples and spots and removes them; Take photos walks the spots with the camera and the
  pictures go up once their event is accepted. Trip derives Bring, Buy and Check on arrival
  from two homes' flags, adds what to buy to the list, and Arrived moves the packed items'
  flags in one go. The Mac has the same screens in its sidebar, with ⌘2 and ⌘3. Settings'
  staleness is 14 to 365 days. Every new word in Dutch and Slovak.
- **Photos of a spot reach the server.** A picture taken for a spot is kept by the server once
  its photo.added is accepted: decoded and written again as a JPEG with nothing but the pixels,
  at most 1600 px on the long side, with a 320 px thumbnail; a spot keeps the newest five and
  the household's photo quota holds before and after the upload. Members fetch a picture with
  their device's signature or through a link the server signs for an hour; the export carries
  the pictures under photos/ and the admin's pages show what a household's photos take.
- **Settings speaks for the doma in front.** With two domas on one device, Last refreshed and
  any trouble line in Settings are those of the household in front's doma, not the last doma the
  app happened to reach.
- **Lighter on the server.** A device that only pulls no longer waits in the writer's queue,
  and its last-seen is written once a minute instead of on every request; with many devices
  those two were most of the writes the server made and the slow tail of a sync.
## 0.3.0 (2026-11-05)

Two families' domas on one device, and items said with a breath between them.

- **Items said with a breath between them come apart.** The words are timed, so a short
  silence between two of them parts them like a comma; names said in one go stay whole.
- **Two families' domas on one device.** An invite from another doma no longer bounces: the app
  joins it next to the first, with the same device key, and the household switcher groups
  households under each doma's address. A bare invite code goes to the doma of the household in
  front; the name is asked once more for a new doma, filled in with the one used so far. Leaving
  the last household on a doma leaves that doma.
## 0.2.1 (2026-11-04)

The Mac app from Homebrew, and one sign-in behind your proxy.

- **One sign-in behind your proxy.** `admin.auth = "proxy"` hands the admin's sign-in to the
  reverse proxy in front (Authelia): doma takes the name from `Remote-User`, believed only from the
  proxy's addresses with a shared secret, and serves no password form. The default stays doma's
  own password. `docs/deploy/authelia/` is set up that way.
- **doma for Mac from Homebrew.** `brew install --cask w4jnl/tap/doma` installs the Mac app,
  signed with a Developer ID and notarized, on macOS 26 or later; every release updates the cask.

## 0.2.0 (2026-11-04)

Speech, sharing, and a place for the proxy's sign-in.

- **Say an item.** A mic at the end of the add field, on the phone and the Mac: a tap listens,
  what you say lands in the field as the words settle, and a pause adds it as return would. Hold
  it (right-click on the Mac) to choose English, Nederlands or Slovenčina; the choice is kept.
  The words are made on the device and the sound is never kept. One breath can name several
  items: "apples, oranges and bread" is three rows, and names the household already uses are
  told apart from the rest, so "olive oil" stays one.
- **Admin pages behind your proxy's sign-in.** `docs/deploy/authelia/` is a compose stack with
  Traefik and Authelia that puts the setup and admin pages behind Authelia, gated by an LLDAP
  group, and leaves the family's invite and guest links, the apps' paths and the probes open. doma
  keeps its own admin password behind it. A test holds the open paths to the routes.
- **Share a personal list.** Rename's neighbours on a personal list gain *Share with the family*:
  a household list of the same name takes what is still open, and the personal one is archived
  with its history.

## 0.1.0 (2026-11-04)

The first build: phase 0 of the plan, the family's shared lists on doma.

- **Quieter words, your choice of them, and a lock.** A warmer chime. Spoken pushes come at
  most every two minutes per device and then say everything since. Settings gains a switch per
  shared list and one for clears, kept on the server, which composes the words; and a lock
  that covers the app on a return after a chosen time away, from at once to until tomorrow,
  and asks Face ID, Touch ID or the passcode. The flags setting, which belongs to Homes, waits
  for the Homes tab.
- **Each device's own push gateway.** A device says whether its token is a development one when
  it registers it, and the server sends each push to the matching Apple host, so one server
  serves a build from Xcode and the family's TestFlight builds alike. The `push.sandbox` config
  key is gone.
- **The badge while away, and a chime.** A spoken push carries the number of entries others
  added since the phone last spoke to the server, so the icon shows it while the app is away,
  and the app counts for itself after every sync, in the background too. Seen marks move only
  while the app is active and the list on screen, so what came while the phone was locked is
  still new when it is opened. Spoken pushes play the app's own soft two-note chime.
- **Every change pushes.** The guest page's adds, strikes and clears and the server's own events
  (a member removed, a device revoked) now tell the push side the household changed, as the
  apps' sync always did; before, a guest's add reached the phones only on their next poll.
- **Where you left off.** The apps open on the household and the screen last in front: the tab
  on the phone, the list or Family in the Mac's sidebar, the list within a household as before.
  A device that has lost its key says so in Settings and wears the offline badge instead of
  looking fine and never syncing; a device that joins again follows its new key. A Mac debug
  build can sign with a named identity (`DOMA_MAC_IDENTITY` in Local.xcconfig) so the Keychain
  keeps its key across rebuilds.
- **Unseen, not open.** The icon's badge counts what this device has not seen: entries others
  added since each list was last in front, falling as lists are opened. The overview and the
  Mac's sidebar put an accent dot before a list's count while it holds unseen entries, and in
  the list the rows others added since the last visit wear a dot on their symbol for that
  visit. Your own adds never count; the marks live on the device.
- **A word from the family.** A push carries words when someone else added to a list or cleared
  it: "Sam added melk and brood" under the list's name, threaded per list, composed on the
  server from the events since the device was last pushed; your own changes stay silent, and
  checks never speak. The phone asks once after joining; Settings shows whether notifications
  are on and where to change it. Nothing shows while the app is in front, it just syncs.
- **Presence, small.** A struck row names who got it when it was someone else; the offline badge
  says since when after a minute; About carries the lockup. The family's names come with the
  members the Family screen and the foreground refresh already fetch, held in memory only.
- **The Mac's mechanics.** A click selects a row, the symbol strikes it, a double click or
  return edits it, escape leaves a field for the list and typing starts an entry; the add row
  sits under the last open item with its matches beneath; rows are 32pt with hairlines from the
  text, a hovered row on surface, the selected row on accent-soft, the pane left-aligned under
  a title-weight header; mono at the Mac's own sizes. The sidebar shows counts as badges and New
  list as a menu with Just me; every shortcut is in the menu bar; Settings is a window on ⌘,;
  an invite or guest link is a popover; the window opens at 960 by 640. Tooltips throughout.
- **The phone's material.** The add bar is a glass capsule floating over the tab bar, matches
  and chips in the same glass; the tab bar shrinks on scroll. The Lists overview, Family and
  Settings are grouped inset lists with help as footers; the new-list form is two rows with
  Cancel and Create in the toolbar. Invite is the one prominent button; Guest link and Settings
  are plain; Remove and Revoke sit behind a swipe and a long press and arm in the row. Settings,
  an invite and a guest link open one level down instead of as sheets. The divider is a row,
  the first frame is the brand's ground.
- **Rows and motion.** The entry row carries the brand's own open and done symbols, hairlines
  from the name, a quantity column and the note in the system face; the title has a real dot and
  a count that rolls. The list animates: an add scrolls into view with a flash and a soft tap, a
  row from another phone flashes the same way, matches rise from the bar, a put back feels
  lighter than a strike, the sink settles instead of flying, Clear fades the group, armed
  buttons warn and spring, the Recent chevron turns. The offline badge waits for a second
  failure, fades, and says caught up once when the spell ends. Reduce Motion keeps opacity and
  haptics only. Three motion tokens; the dark hairline and surface a step lighter.
- **Open source.** The repository is public under the MIT licence, as vink.
- **The apps, phase 0, step 1.** The iPhone and Mac projects under `app/` from XcodeGen, with
  GRDB pinned, the design tokens in Swift with a test against `tokens.json`, the brand's custom
  symbols exported from the pictograms, and the `mac-*` and `ios-*` make targets.
- **The apps, phase 0, step 2.** DomaKit under `app/shared`: the local store with the household
  tables, the log, the outbox and the cursor; the Swift fold, the same rules as the server's and
  tested against the same fixture in every order, with a base for devices that join through a
  snapshot; the device key in the Keychain and the signed client; invite acceptance; the syncer
  with its triggers, background refresh and silent push on the phone.
- **The apps, phase 0, step 3.** The screens: Scan with the camera and Paste a link; Lists;
  the List with the add field and its matches, strike and restore, Clear and shake to clear,
  Recent, shop mode, reorder, and the long-press menu (For a home, Bought, Rename, Merge with);
  Family with members, invites as a QR with Share, guest links, Remove and Leave armed in
  place; Settings; the Mac in a split view with its keyboard. English, Dutch and Slovak.
- **The apps, phase 0, step 4.** The UI tests against a throwaway doma (`make ui-test`): join
  from a QR picture, add, strike and clear, add while offline and then sync, the invite's QR;
  the snapshots of every screen in light and dark at two Dynamic Type sizes on both platforms
  (`make snapshots` records, the test suites compare).
- **The apps, phase 0, step 5.** The TestFlight path: the push entitlement for device builds,
  `make ios-testflight` with the App Store Connect export, and the apps' READMEs.
- **The server, phase 0.** `doma serve` with `doma.toml` and `DOMA_*` overrides; the setup page
  that shows once; households with their default list and first home; the owner invite as a QR;
  invites and roles; device keys with a signature on every app request; `POST /sync/v1` with
  cursors, paging and snapshots; the fold that gives the same tables in any order of events, with
  the fixture the apps share; nightly snapshots and retention; the export zip; silent push behind
  `push.enabled` with the APNs key encrypted at rest; the admin pages (households, devices,
  quotas, export, backup, log level, a second step on sign-in); guest links and the guest view.
  The apps are next.
- **Reinstall keeps the seat.** A phone whose key already belongs to the household, after the
  app was reinstalled, gets its membership back from any valid invite instead of "you are
  already in this household"; the invite stays unused.
- **Lists you can read and manage.** The Lists screen says how many items are still to get,
  under the household name and per list; the new-list form says what it makes and who will see
  it; a long-press or swipe on a list offers Rename and Archive, armed in place. Invite and
  Guest link are words in the Family toolbar; the flags setting waits for the first home. A
  strike and a clear answer with a haptic, struck rows sink, and an empty list shows the mark
  and one line of help.
- **Lists have a colour.** Six list colours in the design system, chosen as a row of dots
  when a list is made; the dot sits before the list's name on the phone and in the Mac sidebar.
  The default list wears the accent.
- **A tap lands in the same frame.** The local store is a WAL pool: screens read on their own
  connections and refresh after a commit instead of inside it, the syncer never holds a frame,
  a clear replays only the keys it can close, the catalog answers 80 ms after the last
  keystroke off the main thread, and a screen makes its observations before its first frame.
- **The list, redesigned.** One layout at home and in the shop, no shop mode: rows at 52pt, the
  add bar pinned at the bottom with the catalog's matches above it and the usual items as chips,
  the screen awake while a list is in front. A tap strikes the row where it is, with a pop and a
  haptic, and it keeps its place for a breath so a second tap takes it back; then it sinks under
  a divider that counts the got and holds Clear. Swipe left to edit the line; long-press drags.
  Shake-to-clear and the long-press menu are gone from the phone.
- **A second device.** Settings has *Add a device*: a QR valid for a day that a Mac or a new
  phone scans to join as the same person, with its own key and every household the person is in,
  instead of becoming a second member. The invites table gains `for_person_id`; the accept answer
  carries the person's name.
- **The Mac, usable.** New list sits at the foot of the sidebar and opens a small form there,
  so it no longer hides in the toolbar's overflow; a right-click on a list offers Rename, Colour
  and Archive; the sidebar selects in the accent; the list pane carries its own title, rows no
  wider than a readable column, the field live from the start, Got it and Put back in the
  row's menu, and the delete key strikes the selected row.
- **Open into the list.** The Lists tab opens the last-used list; a Lists button at the top left
  and a second tap on the tab open the overview. Sections read Household and Just me, a new list
  takes the next free colour, Family has its own title with the household under it, Settings is
  plain rows like every other screen, and Remove, Revoke and Leave stay quiet until armed.
