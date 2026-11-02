// RootView is what the app shows. In this step it is the mark and the tagline; the Scan screen
// takes its place when the store, the fold and sync are in (prompt 1, steps 2 and 3).
import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: Tokens.space4) {
            Mark(size: 64)
            Text(verbatim: "doma")
                .font(.title.weight(.semibold))
                .foregroundStyle(Tokens.ink)
            Text(verbatim: "what to buy, what is there, what to bring")
                .font(.subheadline)
                .foregroundStyle(Tokens.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.ground)
    }
}

#Preview {
    RootView()
}
