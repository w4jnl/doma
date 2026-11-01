// RootView is the first screen before any household, Scan, and the household's screens after:
// two tabs on the phone (Lists, Family; Homes and Trip come in phase 1), a sidebar on the Mac.
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
        .onOpenURL { url in
            // doma://invite#<token> from the invite page
            Task { try? await session.accept(url.absoluteString, displayName: session.context?.displayName ?? "") }
        }
    }
}
