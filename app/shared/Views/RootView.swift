// RootView is the first screen before any household, Scan, and the household's screens after:
// four tabs on the phone (Lists, Homes, Trip, Family), a sidebar on the Mac.
import SwiftUI

struct RootView: View {
    @Environment(Session.self) private var session
    /// A browser's code the system handed to doma, shown on Scan while the phone vouches.
    @State private var openedCode: OpenedCode?

    struct OpenedCode: Identifiable {
        let id = UUID()
        let text: String
    }

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
            // doma://vouch/<host>#<code> from the browser's Almost page: Scan takes it and says
            // how it went; doma://invite#<token> from the invite page joins
            if VouchLink(url.absoluteString) != nil {
                openedCode = OpenedCode(text: url.absoluteString)
                return
            }
            Task { try? await session.accept(url.absoluteString, displayName: session.context?.displayName ?? "") }
        }
        .sheet(item: $openedCode) { code in
            NavigationStack { ScanView(asSheet: true, opened: code.text) }
        }
    }
}
