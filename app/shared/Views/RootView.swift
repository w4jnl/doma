// RootView is the first screen before any household, Scan, and the household's screens after:
// four tabs on the phone (Lists, Homes, Trip, Family), a sidebar on the Mac.
import SwiftUI

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            if session.hasHousehold {
                #if os(macOS)
                MacMainView()
                #else
                MainView()
                #endif
            } else {
                ScanView()
            }
        }
        .tint(Tokens.accent)
        .background(Tokens.ground)
        .lockable()
        .onOpenURL { url in
            // doma://invite#<token> from the invite page
            Task { try? await session.accept(url.absoluteString, displayName: session.context?.displayName ?? "") }
        }
    }
}
