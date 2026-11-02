// doma for iPhone (docs/design.md, "iPhone and Mac apps"). The apps' phase 0 lands in steps:
// this is step 1, the project and the design system. The store, the fold and sync (step 2) and
// the screens (step 3) follow.
import SwiftUI

@main
struct DomaApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                // the tests' host: nothing to launch
                Color.clear
            } else {
                RootView()
            }
        }
    }
}
