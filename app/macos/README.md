# doma for Mac

```sh
brew install --cask w4jnl/tap/doma   # macOS 26 or later, notarized
```

The same screens as the phone in a split view: the lists and Family in the sidebar, the list in
the main pane. ⌘N makes a list, return adds, space strikes the selected row, ⌘⌫ clears, ⌘1 and
⌘4 go to the lists and to Family. An invite is pasted as a link, or scanned with the camera.
The mic at the end of the add row says an item, in English, Dutch or Slovak (right-click it to
choose); the words are made on the Mac and the sound is never kept.

```sh
make mac-build   # the project, then a Debug build
make mac-test    # the unit and snapshot tests
make mac-run     # open the built app
```

Needs Xcode 26 or later and XcodeGen. The app is sandboxed, talks to the configured doma only,
hears the microphone when asked, and is signed ad hoc for a build that runs on this Mac; `Local.xcconfig` takes a team id for
more. The Mac polls; silent push is the phone's.

## Releasing

`make mac-release V=0.2.0` builds the app for both architectures, signs it with the team's
Developer ID, has Apple notarize it, staples the ticket, wraps it in a DMG with a link to
Applications, notarizes and staples that too, and checks both as Gatekeeper would. It needs
the Developer ID Application certificate in the keychain and the App Store Connect API key
`Local.xcconfig` or `app/ios/Local.xcconfig` names. `scripts/release.sh` runs it before every
tag, adds the DMG to the GitHub release and writes `Casks/doma.rb` in w4jnl/homebrew-tap, so
`brew upgrade --cask doma` follows each release.

## Signing a debug build

By default a debug build is signed ad hoc and runs on this Mac only. Every ad hoc build is a new
app to the Keychain, so the device key the last build stored is denied to the next one and the
app has to join the family again. Set `DOMA_MAC_IDENTITY = Apple Development` next to
`DOMA_TEAM_ID` in `Local.xcconfig` to sign with your developer identity instead; the key then
survives rebuilds.
