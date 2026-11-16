// A row for one item that can be tidied where it is seen: a swipe
// offers Rename and Merge into, in the row, and Retire, armed in place. Recent under a list
// and All items use it; History has the same three in its own rows.

import SwiftUI

struct TidyRow<Content: View>: View {
    @Environment(Session.self) private var session
    let itemID: String
    let name: String
    /// The separator starts under the name of the rows above, as a list's rows do.
    var indent = false
    /// The row as it is shown; `armed` is true while Retire asks once more at its end.
    @ViewBuilder let content: (_ armed: Bool) -> Content

    private enum Mode { case row, rename, merge }
    @State private var mode = Mode.row
    @State private var text = ""
    @State private var candidates: [Match] = []
    @State private var armed = false
    @State private var disarm: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        switch mode {
        case .row:
            row
        case .rename:
            field("Name", id: "rename-item") {
                try? HomeActions.renameItem(itemID, to: text, in: session)
                done()
            }
        case .merge:
            field("Merge \(name) into…", id: "merge-item") {
                if candidates.isEmpty { done() }
            }
            .onChange(of: text) { findCandidates() }
            ForEach(candidates.prefix(5)) { m in
                candidateRow(m)
            }
        }
    }

    private var row: some View {
        HStack(spacing: Tokens.space3) {
            content(armed)
            if armed {
                Button {
                    armed = false
                    disarm?.cancel()
                    try? HomeActions.retireItem(itemID, in: session)
                } label: {
                    Text("Really retire?")
                        .font(.footnote)
                        .foregroundStyle(Tokens.onOut)
                        .padding(.horizontal, Tokens.space2)
                        .padding(.vertical, Tokens.space1)
                        .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("retire-" + name)
            }
        }
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + (indent ? Tokens.space5 + Tokens.space3 : 0) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Retire", role: .destructive) { arm() }
                .tint(Tokens.out)
            Button("Merge into…") { start(.merge, with: "") }
                .tint(Tokens.inkMuted)
            Button("Rename") { start(.rename, with: name) }
                .tint(Tokens.accent)
        }
    }

    private func arm() {
        armed = true
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { armed = false }
        }
    }

    private func start(_ mode: Mode, with text: String) {
        armed = false
        candidates = []
        self.text = text
        self.mode = mode
        focused = true
    }

    private func done() {
        mode = .row
        focused = false
    }

    /// The catalog's matches for the typed name, as under the add bar, without the item itself.
    private func findCandidates() {
        guard let scope = session.scope else { return }
        let typed = text
        candidates = ((try? session.store.read(scope) { db, s in try Queries.matches(db, s, prefix: typed) }) ?? []).filter { $0.itemID != itemID }
    }

    private func field(_ prompt: LocalizedStringKey, id: String, submit: @escaping () -> Void) -> some View {
        HStack(spacing: Tokens.space3) {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(submit)
                .onAppear { focused = true }
                .accessibilityIdentifier(id)
            Button("Cancel") { done() }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
        }
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.surface)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
    }

    /// One item this one could be merged into, armed in place: merge is one way.
    private func candidateRow(_ m: Match) -> some View {
        HStack(spacing: Tokens.space3) {
            ArmedButton(title: LocalizedStringKey(m.name), armedTitle: "Really merge into \(m.name)?", tint: Tokens.ink) {
                try? HomeActions.mergeItem(itemID, into: m.itemID, in: session)
                done()
            }
            .accessibilityIdentifier("merge-into-" + m.name)
            Spacer(minLength: Tokens.space2)
        }
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.surface)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space5 + Tokens.space3, bottom: 0, trailing: Tokens.space4))
    }
}
