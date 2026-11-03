// doma for Mac (docs/design.md, "iPhone and Mac apps"): the same screens as the phone in a
// NavigationSplitView, from step 3 on. Step 1 was the project and the design system; this is
// step 2, the store, the fold, sync and identity. The Mac polls; silent push is the phone's.
import SwiftUI

@main
struct DomaApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var session: Session
    @State private var nav = MacNav()

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        _session = State(initialValue: testing ? Session(store: try! DomaStore.inMemory()) : Session.live())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    // the tests' host: nothing to launch
                    Color.clear
                } else {
                    RootView()
                        .frame(minWidth: 720, minHeight: 440)
                }
            }
            .environment(session)
            .environment(nav)
        }
        .defaultSize(width: 960, height: 640)
        .onChange(of: phase) {
            if phase == .active, session.hasHousehold {
                Task { await session.syncer.sync() }
            }
        }
        .commands {
            // every shortcut is in the menu bar, where a Mac user learns it
            CommandGroup(replacing: .newItem) {
                Button("New List") { nav.newList += 1 }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!session.hasHousehold)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Got It") { nav.toggleSelected += 1 }
                    .disabled(!nav.hasSelectedEntry)
                Button("Edit Item") { nav.editSelected += 1 }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!nav.hasSelectedEntry)
                Button("Clear Got Items") { nav.clear += 1 }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!nav.hasStruck)
            }
        }
        // ⌘, : the person's devices, the flags setting and About, as a window, never a sheet
        Settings {
            if session.hasHousehold {
                SettingsView(model: FamilyModel(session: session))
                    .environment(session)
                    .environment(nav)
            }
        }
    }
}
