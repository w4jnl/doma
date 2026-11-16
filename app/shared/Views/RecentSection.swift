// Recent at the foot of a list: collapsed by default, the last cleared items, a tap adds one
// again. A swipe on a row (the row's menu on the Mac) tidies the item as History does: Rename
// and Merge into in the row, and Retire, armed in place, which stops it coming up.

import SwiftUI

struct RecentSection: View {
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let recent: [RecentRow]
    @Binding var shown: Bool
    let add: (String) -> Void

    /// The item being renamed in its row, and the name as typed.
    @State private var renaming: String?
    @State private var renameText = ""
    /// The item being merged into another: its row is a field, the catalog's matches under it.
    @State private var merging: String?
    @State private var mergeText = ""
    @State private var candidates: [Match] = []
    @FocusState private var fieldFocused: Bool
    /// The item whose Retire is armed in its row, and the task that disarms it.
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Section {
            if shown {
                ForEach(recent) { r in
                    if renaming == r.itemID {
                        renameRow(r)
                    } else if merging == r.itemID {
                        mergeRow(r)
                        ForEach(candidates.prefix(5)) { m in
                            candidateRow(m, for: r)
                        }
                    } else {
                        row(r)
                    }
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
        .onChange(of: mergeText) { findCandidates() }
    }

    private func row(_ r: RecentRow) -> some View {
        HStack(spacing: Tokens.space3) {
            Button {
                add(r.itemID)
            } label: {
                HStack {
                    Text(r.name)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    if arming != r.itemID { RelativeText(millis: r.clearedAt) }
                }
                .frame(minHeight: Tokens.rowH)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Adds it again"))
            .accessibilityIdentifier("recent-" + r.name)
            if arming == r.itemID {
                Button {
                    arming = nil
                    disarm?.cancel()
                    try? HomeActions.retireItem(r.itemID, in: session)
                } label: {
                    Text("Really retire?")
                        .font(.footnote)
                        .foregroundStyle(Tokens.onOut)
                        .padding(.horizontal, Tokens.space2)
                        .padding(.vertical, Tokens.space1)
                        .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("retire-" + r.name)
            }
        }
        .transition(.opacity)
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + Tokens.space5 + Tokens.space3 }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Retire", role: .destructive) { arm(r.itemID) }
                .tint(Tokens.out)
            Button("Merge into…") { startMerge(r) }
                .tint(Tokens.inkMuted)
            Button("Rename") { startRename(r) }
                .tint(Tokens.accent)
        }
        #if os(macOS)
        .contextMenu {
            Button("Rename") { startRename(r) }
            Button("Merge into…") { startMerge(r) }
            Button("Retire", role: .destructive) { arm(r.itemID) }
        }
        #endif
    }

    // MARK: Tidying

    private func arm(_ id: String) {
        arming = id
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, arming == id { arming = nil }
        }
    }

    private func startRename(_ r: RecentRow) {
        arming = nil
        merging = nil
        renameText = r.name
        renaming = r.itemID
        fieldFocused = true
    }

    private func startMerge(_ r: RecentRow) {
        arming = nil
        renaming = nil
        mergeText = ""
        candidates = []
        merging = r.itemID
        fieldFocused = true
    }

    private func done() {
        renaming = nil
        merging = nil
        fieldFocused = false
    }

    /// The catalog's matches for the typed name, as under the add bar, without the item itself.
    private func findCandidates() {
        guard let scope = session.scope, let drop = merging else { return }
        let text = mergeText
        candidates = ((try? session.store.read(scope) { db, s in try Queries.matches(db, s, prefix: text) }) ?? []).filter { $0.itemID != drop }
    }

    private func renameRow(_ r: RecentRow) -> some View {
        HStack(spacing: Tokens.space3) {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    try? HomeActions.renameItem(r.itemID, to: renameText, in: session)
                    done()
                }
                .accessibilityIdentifier("rename-item")
            #if os(iOS)
            Button("Cancel") { done() }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
            #endif
        }
        .frame(minHeight: ListView.rowHeight)
        #if os(macOS)
        .onExitCommand { done() }
        #endif
        .listRowBackground(Tokens.surface)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
    }

    private func mergeRow(_ r: RecentRow) -> some View {
        HStack(spacing: Tokens.space3) {
            TextField("Merge \(r.name) into…", text: $mergeText)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit { if candidates.isEmpty { done() } }
                .accessibilityIdentifier("merge-item")
            #if os(iOS)
            Button("Cancel") { done() }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
            #endif
        }
        .frame(minHeight: ListView.rowHeight)
        #if os(macOS)
        .onExitCommand { done() }
        #endif
        .listRowBackground(Tokens.surface)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
    }

    /// One item the dropped one could be merged into, armed in place: merge is one way.
    private func candidateRow(_ m: Match, for r: RecentRow) -> some View {
        HStack(spacing: Tokens.space3) {
            ArmedButton(title: LocalizedStringKey(m.name), armedTitle: "Really merge into \(m.name)?", tint: Tokens.ink) {
                try? HomeActions.mergeItem(r.itemID, into: m.itemID, in: session)
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
