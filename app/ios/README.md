# doma for iPhone

The family's lists on the phone: a full copy of the household in a local store, every tap an
event folded at once and sent when the network allows. The spec is `docs/design.md`, "iPhone and
Mac apps"; the server is this repository's Go code. It ships through TestFlight during phases 0
and 1 and from the App Store from phase 2.

## Build

Needs Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install
xcodegen`). GRDB is fetched by Swift Package Manager at the pinned version.

```sh
make ios-build       # the project, then a simulator build (iPhone 17; IOS_SIM= picks another)
make ios-test        # the unit and snapshot tests in the simulator
make ui-test         # the UI tests and the live test, against a throwaway doma it starts
make snapshots       # record the screen pictures the tests compare against, after a screen changes
make ios-device      # build, install and launch on a connected iPhone
make ios-testflight  # archive and upload to App Store Connect, for TestFlight
```

`make ios-project` writes an empty `Local.xcconfig`; put your team id in it (see
`Local.xcconfig.example`) for a device build, and an App Store Connect API key for uploads
without Xcode's account. Simulator builds are signed ad hoc, so the Keychain, which holds the
device key, works there.

## TestFlight

Once, in App Store Connect: Apps › New App, iOS, bundle id `nl.w4j.doma`, a name the store
accepts (the bare name is taken; "Doma – lists, homes, trips" or a variant). Then
`make ios-testflight` archives a Release build, exports it with `ExportOptions.plist` (Xcode
raises the build number when the one in `project.yml` is taken) and uploads it. Export
compliance is declared in the Info.plist: only https and signatures, which are exempt. Add the
family as internal testers.

## The first run

Scan the invite the owner shows, or paste its link, and give your name as the family sees it.
The phone makes its key, the server registers the device, and the household's lists come down.
From then on the app talks to that one doma and nothing else.

## Voice

The mic at the end of the add field says an item instead of typing it: each piece the model
settles lands in the field as if typed, the words it may still change shown faintly after it,
and a pause adds what was said as return would. A tap again stops it and keeps the words.
Holding the mic chooses the language, English, Nederlands or Slovenčina, whose code shows under
it; the choice is remembered on the phone. Apple's SpeechAnalyzer does the work on the phone:
SpeechTranscriber for English, DictationTranscriber, the keyboard's model, for Dutch and Slovak;
iOS fetches a language's model the first time it is used. Only the words are kept, never the
sound. The simulator has no speech models, so `make voice` runs the same Listener on the Mac,
on a sentence in each language that `say` speaks.

## What is where

`app/shared` is DomaKit, compiled into this app and the Mac app: `Model` (stamps, ids, the
typed line, events and rows), `Fold` (the port of the server's fold, tested against the same
fixture), `Store` (GRDB, what the screens read and write), `Identity` (the device key, invites,
the session), `Sync` (the signed client, the syncer, background refresh and push), `Voice`
(speech to words on the device and the mic), `Views`
(the screens, the string catalogue in English, Dutch and Slovak) and `Design` (the tokens, the
mark, the custom symbols). `Doma/` here holds only the entry point, the icon and the
entitlements; `DomaTests` and `DomaUITests` the tests this platform runs.
