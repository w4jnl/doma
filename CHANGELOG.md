# Changelog

User-facing changes per release, newest first. `scripts/release.sh` refuses to tag a version
that has no section here and uses the section as the GitHub release notes, so every release
updates this file first. Dates are the tag dates.

## Unreleased

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
- **The server, phase 0.** `doma serve` with `doma.toml` and `DOMA_*` overrides; the setup page
  that shows once; households with their default list and first home; the owner invite as a QR;
  invites and roles; device keys with a signature on every app request; `POST /sync/v1` with
  cursors, paging and snapshots; the fold that gives the same tables in any order of events, with
  the fixture the apps share; nightly snapshots and retention; the export zip; silent push behind
  `push.enabled` with the APNs key encrypted at rest; the admin pages (households, devices,
  quotas, export, backup, log level, a second step on sign-in); guest links and the guest view.
  The apps are next.
