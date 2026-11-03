// All lists, one level under the list on screen: the household's lists first, then the person's
// own, each with its dot, name and how many are to get; + creates one, with the next free colour.
// A long-press or a swipe on a row offers Rename and Archive, armed in place; the household's
// default list can only be renamed. Rename also offers the colour.
import SwiftUI

struct ListsView: View {
    /// Set when the overview is pushed from the Lists tab: a tap picks the list and pops back.
    var pick: ((String) -> Void)?
    @Environment(Session.self) private var session
    @State private var lists: Live<[ListSummary]>?
    @State private var adding = false
    @State private var newName = ""
    @State private var personal = false
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var renameColour = ""
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
                SectionHeader("Household")
            }
            Section {
                ForEach(mine) { l in
                    row(l)
                }
                if mine.isEmpty {
                    Text("A list only you see. Tap + and choose Just me.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                        .listRowBackground(Tokens.ground)
                }
            } header: {
                SectionHeader("Just me")
            }
        }
        .listStyle(.plain)
        .textCase(nil)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle("Lists")
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ l: ListSummary) -> some View {
        if renaming == l.id {
            renameRow(l)
        } else {
            Group {
                if let pick {
                    Button {
                        pick(l.id)
                    } label: {
                        rowContent(l)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: l.id) {
                        rowContent(l)
                    }
                }
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

    private func rowContent(_ l: ListSummary) -> some View {
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(l.name), \(l.openCount) to get"))
    }

    private func renameRow(_ l: ListSummary) -> some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            HStack {
                TextField("List name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .submitLabel(.done)
                    .onSubmit { commitRename(l) }
                Button("Cancel") { renaming = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.inkMuted)
            }
            .rowHeight()
            if !l.isDefault {
                ColourDots(colour: $renameColour)
                    .onChange(of: renameColour) { commitRename(l, keepEditing: true) }
            }
        }
        .padding(.vertical, Tokens.space1)
        .listRowBackground(Tokens.surface)
    }

    private func startRename(_ l: ListSummary) {
        renameText = l.name
        renameColour = l.colour
        renaming = l.id
        renameFocused = true
    }

    private func commitRename(_ l: ListSummary, keepEditing: Bool = false) {
        try? ListActions.renameList(l.id, to: renameText, colour: l.isDefault ? l.colour : renameColour, in: session)
        if !keepEditing { renaming = nil }
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
                .overlay(RoundedRectangle(cornerRadius: Tokens.radiusSM).strokeBorder(Tokens.line))
                .onSubmit(create)
                .accessibilityLabel(Text("List name"))
            Text("Who sees it")
                .font(.footnote)
                .foregroundStyle(Tokens.inkMuted)
            Picker("Who sees it", selection: $personal) {
                Text("Household").tag(false)
                Text("Just me").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
        let colour = ListActions.nextColour(lists?.value ?? [])
        guard let id = try? ListActions.createList(named: newName, personal: personal, colour: colour, in: session) else { return }
        newName = ""
        adding = false
        pick?(id)
    }
}
