// Lists: the shared lists first, then the person's own, each with its glyph, name and how many
// are still to get; + creates one. A long-press or a swipe on a row offers Rename and Archive,
// armed in place; the household's default list can only be renamed.
import SwiftUI

struct ListsView: View {
    @Environment(Session.self) private var session
    @State private var lists: Live<[ListSummary]>?
    @State private var adding = false
    @State private var newName = ""
    @State private var personal = false
    @State private var colour = Tokens.listColours[0]
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?
    @FocusState private var nameFocused: Bool
    @FocusState private var renameFocused: Bool

    var body: some View {
        let all = lists?.value ?? []
        let shared = all.filter { !$0.isPersonal }
        let mine = all.filter(\.isPersonal)
        let open = all.reduce(0) { $0 + $1.openCount }
        List {
            if adding {
                Section {
                    newListRow
                }
            }
            Section {
                ForEach(shared) { l in
                    row(l)
                }
            } header: {
                Text("Shared with everyone")
            }
            Section {
                ForEach(mine) { l in
                    row(l)
                }
                if mine.isEmpty {
                    Text("A list only you see. Tap + and choose Only you.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                        .listRowBackground(Tokens.ground)
                }
            } header: {
                Text("Only yours")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle(session.current?.name ?? "")
        .navigationSubtitle(open == 0 ? Text("Nothing to get") : Text("\(open) to get"))
        .navigationDestination(for: String.self) { id in ListView(listID: id) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    adding.toggle()
                    if adding { nameFocused = true }
                } label: {
                    Label("New list", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .task(id: session.scope) {
            guard let scope = session.scope else { return }
            lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ l: ListSummary) -> some View {
        if renaming == l.id {
            renameRow(l)
        } else {
            NavigationLink(value: l.id) {
                HStack(spacing: Tokens.space3) {
                    ListDot(colour: l.colour)
                    Text(l.name)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    if arming == l.id {
                        Button {
                            arming = nil
                            disarm?.cancel()
                            try? ListActions.archiveList(l.id, in: session)
                        } label: {
                            Text("Really archive?")
                                .foregroundStyle(Tokens.onOut)
                                .padding(.horizontal, Tokens.space2)
                                .padding(.vertical, Tokens.space1)
                                .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                        }
                        .buttonStyle(.borderless)
                    } else if l.openCount > 0 {
                        Text("\(l.openCount) to get")
                            .font(Tokens.mono(.subheadline))
                            .foregroundStyle(Tokens.inkMuted)
                    }
                }
                .rowHeight()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(l.name), \(l.openCount) to get"))
            }
            .listRowBackground(Tokens.ground)
            .listRowSeparatorTint(Tokens.line)
            .contextMenu {
                Button("Rename") { startRename(l) }
                if !l.isDefault {
                    Button("Archive") { arm(l) }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !l.isDefault {
                    Button("Archive") { arm(l) }
                }
                Button("Rename") { startRename(l) }
                    .tint(Tokens.accent)
            }
        }
    }

    private func renameRow(_ l: ListSummary) -> some View {
        HStack {
            TextField("List name", text: $renameText)
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .submitLabel(.done)
                .onSubmit {
                    try? ListActions.renameList(l.id, to: renameText, colour: l.colour, in: session)
                    renaming = nil
                }
            Button("Cancel") { renaming = nil }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
        }
        .rowHeight()
        .listRowBackground(Tokens.surface)
    }

    private func startRename(_ l: ListSummary) {
        renameText = l.name
        renaming = l.id
        renameFocused = true
    }

    /// Archive waits four seconds for the second tap, in the row, as every destructive action.
    private func arm(_ l: ListSummary) {
        arming = l.id
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, arming == l.id { arming = nil }
        }
    }

    // MARK: New list

    private var newListRow: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            Text("New list")
                .font(.headline)
                .foregroundStyle(Tokens.ink)
            TextField("List name", text: $newName)
                .focused($nameFocused)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .padding(Tokens.space2)
                .background(Tokens.surfaceSunk, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                .onSubmit(create)
                .accessibilityLabel(Text("List name"))
            Text("Who sees it")
                .font(.footnote)
                .foregroundStyle(Tokens.inkMuted)
            Picker("Who sees it", selection: $personal) {
                Text("Everyone").tag(false)
                Text("Only you").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Colour")
                .font(.footnote)
                .foregroundStyle(Tokens.inkMuted)
            ColourDots(colour: $colour)
            HStack {
                Button("Cancel") {
                    adding = false
                    newName = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
                Spacer()
                Button("Create list", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, Tokens.space2)
        .listRowBackground(Tokens.surface)
    }

    private func create() {
        guard (try? ListActions.createList(named: newName, personal: personal, colour: colour, in: session)) != nil else { return }
        newName = ""
        adding = false
    }
}
