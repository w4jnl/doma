// doma for Mac (docs/design.md, "iPhone and Mac apps"): the same screens as the phone in a
// NavigationSplitView, from step 3 on. This is step 1, the project and the design system.
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
                    .frame(minWidth: 480, minHeight: 360)
            }
        }
    }
}
