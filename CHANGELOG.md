# Changelog

User-facing changes per release, newest first. `scripts/release.sh` refuses to tag a version
that has no section here and uses the section as the GitHub release notes, so every release
updates this file first. Dates are the tag dates.

## Unreleased

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
