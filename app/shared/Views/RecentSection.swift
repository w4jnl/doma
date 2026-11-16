// Recent at the foot of a list: collapsed by default, the last cleared items, a tap adds one
// again. A swipe on a row tidies the item as History does: Rename
// and Merge into in the row, and Retire, armed in place, which stops it coming up.

import SwiftUI

struct RecentSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let recent: [RecentRow]
    @Binding var shown: Bool
    /// Told where each row is on screen, so a tapped item's name can fly from there.
    var place: (String, CGRect) -> Void = { _, _ in }
    let add: (String) -> Void

    var body: some View {
        Section {
            if shown {
                ForEach(recent) { r in
                    TidyRow(itemID: r.itemID, name: r.name, indent: true) { armed in
                        Button {
                            add(r.itemID)
                        } label: {
                            HStack {
                                Text(r.name)
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if !armed { RelativeText(millis: r.clearedAt) }
                            }
                            .frame(minHeight: Tokens.rowH)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place(r.itemID, $0) }
                        .accessibilityHint(Text("Adds it again"))
                        .accessibilityIdentifier("recent-" + r.name)
                    }
                    .transition(.opacity)
                }
            }
        } header: {
            Button {
                withAnimation(Motion.of(reduceMotion, .easeInOut(duration: Tokens.motionQuick + 0.05))) { shown.toggle() }
            } label: {
                HStack(spacing: Tokens.space1) {
                    Text("Recent")
                        .font(.subheadline)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(shown ? 90 : 0))
                }
                .foregroundStyle(Tokens.inkMuted)
                .padding(.top, Tokens.space4)
                .padding(.bottom, Tokens.space2)
            }
            .buttonStyle(.plain)
            .accessibilityValue(shown ? Text("open") : Text("collapsed"))
        }
        .textCase(nil)
    }
}
