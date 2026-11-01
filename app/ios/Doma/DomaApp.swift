// doma for iPhone (docs/design.md, "iPhone and Mac apps"). The apps' phase 0 lands in steps:
// step 1 was the project and the design system, this is step 2, the store, the fold, sync and
// identity behind the screens that come in step 3.
import SwiftUI

@main
struct DomaApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var phase
    @State private var session: Session
    @State private var away = false

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
                }
            }
            .environment(session)
        }
        .onChange(of: phase) {
            // sync when the person comes back to the app and when they leave it
            switch phase {
            case .active:
                if session.hasHousehold {
                    PushDelegate.enable()
                    Task { await session.syncer.sync() }
                }
                away = false
            case .background:
                away = true
                BackgroundRefresh.schedule()
                Task { await session.syncer.sync() }
            default:
                break
            }
        }
    }
}
