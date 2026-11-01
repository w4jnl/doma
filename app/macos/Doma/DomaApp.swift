// doma for Mac (docs/design.md, "iPhone and Mac apps"): the same screens as the phone in a
// NavigationSplitView, from step 3 on. Step 1 was the project and the design system; this is
// step 2, the store, the fold, sync and identity. The Mac polls; silent push is the phone's.
import SwiftUI

@main
struct DomaApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var session: Session

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
                        .frame(minWidth: 480, minHeight: 360)
                }
            }
            .environment(session)
        }
        .onChange(of: phase) {
            if phase == .active, session.hasHousehold {
                Task { await session.syncer.sync() }
            }
        }
    }
}
