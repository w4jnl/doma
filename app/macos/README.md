# doma for Mac

The same screens as the phone in a split view: the lists and Family in the sidebar, the list in
the main pane. ⌘N makes a list, return adds, space strikes the selected row, ⌘⌫ clears, ⌘1 and
⌘4 go to the lists and to Family. An invite is pasted as a link, or scanned with the camera.

```sh
make mac-build   # the project, then a Debug build
make mac-test    # the unit and snapshot tests
make mac-run     # open the built app
```

Needs Xcode 26 or later and XcodeGen. The app is sandboxed, talks to the configured doma only,
and is signed ad hoc for a build that runs on this Mac; `Local.xcconfig` takes a team id for
more. The Mac polls; silent push is the phone's.
