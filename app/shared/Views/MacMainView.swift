// The Mac: a sidebar with the lists and Family, the list in the main pane. New list sits at the
// foot of the sidebar and opens into a small form there, no sheet; a right-click on a list
// offers Rename, Colour and Archive, armed in place like everywhere. Keyboard: ⌘N new list,
// return adds, space or ⌫ strikes the selected row, ⌘⌫ clears, ⌘1 and ⌘4 the sections (⌘2 and
// ⌘3 arrive with Homes and Trip).
#if os(macOS)
import SwiftUI

struct MacMainView: View {
    @Environment(Session.self) private var session
    @State private var lists: Live<[ListSummary]>?
    @State private var selection: Selection? = .lists
    @State private var adding = false
    @State private var newName = ""
    @State private var personal = false
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?
    @FocusState private var newNameFocused: Bool
    @FocusState private var renameFocused: Bool

    enum Selection: Hashable {
        case lists
        case list(String)
        case family
    }

    var body: some View {
        let all = lists?.value ?? []
        let shared = all.filter { !$0.isPersonal }
        let own = all.filter(\.isPersonal)
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(shared) { l in listRow(l) }
                } header: {
                    Text("Household")
                }
                if !own.isEmpty {
                    Section {
                        ForEach(own) { l in listRow(l) }
                    } header: {
                        Text("Just me")
                    }
                }
                Section {
                    Label("Family", systemImage: "person.2")
                        .tag(Selection.family)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(session.current?.name ?? "doma")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFoot
            }
            .background {
                // ⌘N opens the form at the foot
                Button("") { startAdding() }
                    .keyboardShortcut("n", modifiers: .command)
                    .hidden()
            }
        } detail: {
            switch selection {
            case .list(let id):
                NavigationStack { ListView(listID: id) }
                    .id(id)
            case .family:
                NavigationStack { FamilyView() }
            default:
                VStack(spacing: Tokens.space3) {
                    Mark(size: 40)
                    Text("Choose a list")
                        .foregroundStyle(Tokens.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.ground)
            }
        }
        .task(id: session.scope) {
            guard let scope = session.scope else { return }
            lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
            if case .lists = selection, let first = lists?.value.first {
                selection = .list(first.id)
            }
        }
        .onChange(of: lists?.value) { _, now in
            // an archived list leaves the screen; the pane follows
            if case .list(let id) = selection, let now, !now.contains(where: { $0.id == id }) {
                selection = now.first.map { .list($0.id) }
            }
        }
        .background {
            // ⌘1 the lists, ⌘4 Family
            Button("") { if let first = lists?.value.first { selection = .list(first.id) } }
                .keyboardShortcut("1", modifiers: .command)
                .hidden()
            Button("") { selection = .family }
                .keyboardShortcut("4", modifiers: .command)
                .hidden()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func listRow(_ l: ListSummary) -> some View {
        if renaming == l.id {
            HStack(spacing: Tokens.space2) {
                ListDot(colour: l.colour)
                TextField("List name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(l) }
                    .onExitCommand { renaming = nil }
            }
            .tag(Selection.list(l.id))
        } else {
            HStack {
                ListDot(colour: l.colour)
                    .frame(width: Tokens.space5)
                Text(l.name)
                Spacer()
                if arming == l.id {
                    Button {
                        arming = nil
                        disarm?.cancel()
                        try? ListActions.archiveList(l.id, in: session)
                    } label: {
                        Text("Really archive?")
                            .font(.footnote)
                            .foregroundStyle(Tokens.onOut)
                            .padding(.horizontal, Tokens.space2)
                            .padding(.vertical, Tokens.space1)
                            .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                    }
                    .buttonStyle(.plain)
                } else if l.openCount > 0 {
                    Text(verbatim: String(l.openCount))
                        .font(Tokens.mono(.footnote))
                        .foregroundStyle(Tokens.inkMuted)
                        .contentTransition(.numericText())
                        .animation(Motion.base, value: l.openCount)
                }
            }
            .tag(Selection.list(l.id))
            .contextMenu {
                Button("Rename") { startRename(l) }
                if !l.isDefault {
                    Menu("Colour") {
                        ForEach(Tokens.listColours, id: \.self) { c in
                            Button {
                                try? ListActions.renameList(l.id, to: l.name, colour: c, in: session)
                            } label: {
                                if c == l.colour {
                                    Label { ColourDots.name(c) } icon: { Image(systemName: "checkmark") }
                                } else {
                                    ColourDots.name(c)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Archive") { arm(l) }
                }
            }
        }
    }

    private func startRename(_ l: ListSummary) {
        renameText = l.name
        renaming = l.id
        renameFocused = true
    }

    private func commitRename(_ l: ListSummary) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != l.name {
            try? ListActions.renameList(l.id, to: name, colour: l.colour, in: session)
        }
        renaming = nil
    }

    /// Archive waits four seconds for the second click, in the row, as every destructive action.
    private func arm(_ l: ListSummary) {
        arming = l.id
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, arming == l.id { arming = nil }
        }
    }

    // MARK: New list, at the foot of the sidebar

    @ViewBuilder
    private var sidebarFoot: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            Divider()
            if adding {
                TextField("List name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($newNameFocused)
                    .onSubmit(create)
                    .onExitCommand { stopAdding() }
                    .accessibilityIdentifier("new-list-name")
                Picker("Who sees it", selection: $personal) {
                    Text("Household").tag(false)
                    Text("Just me").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    Button("Cancel") { stopAdding() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.inkMuted)
                    Spacer()
                    Button("Create list", action: create)
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button {
                    startAdding()
                } label: {
                    Label("New list", systemImage: "plus")
                        .foregroundStyle(Tokens.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("new-list")
            }
        }
        .padding(.horizontal, Tokens.space3)
        .padding(.vertical, Tokens.space2)
        .animation(Motion.base, value: adding)
    }

    private func startAdding() {
        adding = true
        newNameFocused = true
    }

    private func stopAdding() {
        adding = false
        newName = ""
        personal = false
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = try? ListActions.createList(named: name, personal: personal, colour: ListActions.nextColour(lists?.value ?? []), in: session) {
            selection = .list(id)
        }
        stopAdding()
    }
}
#endif
