// The Mac: a sidebar with the lists, the homes, Trip and Family, the screen in the main pane.
// New list sits at the foot of the sidebar and opens into a small form there, no sheet; a
// right-click on a list offers Rename, Colour, Share with the family on a personal list, and
// Archive, armed in place like everywhere. Keyboard: ⌘N new list, return adds, space or ⌫
// strikes the selected row, ⌘⌫ clears, ⌘1 to ⌘4 the sections.
#if os(macOS)
import SwiftUI

struct MacMainView: View {
    @Environment(Session.self) private var session
    @Environment(MacNav.self) private var nav
    @State private var lists: Live<[ListSummary]>?
    @State private var marks: Live<[OpenMark]>?
    @State private var homes: Live<[HomeRow]>?
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
        case homes
        case home(String)
        case trip
        case family
        case history
        case cards
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
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(Selection.history)
                    Label("Cards", systemImage: "creditcard")
                        .tag(Selection.cards)
                }
                Section {
                    ForEach(homes?.value ?? []) { h in
                        Label { Text(h.name) } icon: { Symbol.home.image }
                            .tag(Selection.home(h.id))
                    }
                    Label("All homes", systemImage: "plus")
                        .tag(Selection.homes)
                } header: {
                    Text("Homes")
                }
                Section {
                    Label("Trip", systemImage: "suitcase")
                        .tag(Selection.trip)
                    Label("Family", systemImage: "person.2")
                        .tag(Selection.family)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .navigationTitle(session.current?.name ?? "doma")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFoot
            }
            .onChange(of: nav.newList) { startAdding() }
            .onChange(of: nav.showCards) { selection = .cards }
        } detail: {
            switch selection {
            case .list(let id):
                NavigationStack { ListView(listID: id) }
                    .id(id)
            case .homes:
                NavigationStack { HomesView(pick: { selection = .home($0) }) }
            case .home(let id):
                NavigationStack { HomeView(homeID: id) }
                    .id(id)
            case .trip:
                NavigationStack { TripsView() }
            case .family:
                NavigationStack { FamilyView() }
            case .history:
                NavigationStack { HistoryView() }
            case .cards:
                NavigationStack { CardsView() }
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
            marks = Live(session.store, initial: []) { db in try Queries.openMarks(db, scope) }
            homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
            if case .lists = selection {
                // the list or screen last in front in this household, else the first list
                let remembered = UITestHooks.testing ? nil : UserDefaults.standard.string(forKey: "mac.selection." + scope.serverID + "/" + scope.householdID)
                if remembered == "family" {
                    selection = .family
                } else if remembered == "trip" {
                    selection = .trip
                } else if remembered == "homes" {
                    selection = .homes
                } else if remembered == "history" {
                    selection = .history
                } else if remembered == "cards" {
                    selection = .cards
                } else if let r = remembered, r.hasPrefix("home:"), homes?.value.contains(where: { $0.id == String(r.dropFirst(5)) }) == true {
                    selection = .home(String(r.dropFirst(5)))
                } else if let id = remembered, lists?.value.contains(where: { $0.id == id }) == true {
                    selection = .list(id)
                } else if let first = lists?.value.first {
                    selection = .list(first.id)
                }
            }
        }
        .onChange(of: selection) { _, now in
            guard let h = session.currentRef?.key else { return }
            switch now {
            case .list(let id): UserDefaults.standard.set(id, forKey: "mac.selection." + h)
            case .home(let id): UserDefaults.standard.set("home:" + id, forKey: "mac.selection." + h)
            case .homes: UserDefaults.standard.set("homes", forKey: "mac.selection." + h)
            case .trip: UserDefaults.standard.set("trip", forKey: "mac.selection." + h)
            case .family: UserDefaults.standard.set("family", forKey: "mac.selection." + h)
            case .cards: UserDefaults.standard.set("cards", forKey: "mac.selection." + h)
            case .history: UserDefaults.standard.set("history", forKey: "mac.selection." + h)
            default: break
            }
        }
        .onChange(of: lists?.value) { _, now in
            // an archived list leaves the screen; the pane follows
            if case .list(let id) = selection, let now, !now.contains(where: { $0.id == id }) {
                selection = now.first.map { .list($0.id) }
            }
        }
        .onChange(of: homes?.value) { _, now in
            if case .home(let id) = selection, let now, !now.contains(where: { $0.id == id }) {
                selection = .homes
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            // ⌘1 the lists, ⌘2 the homes, ⌘3 Trip, ⌘4 Family
            Button("") { if let first = lists?.value.first { selection = .list(first.id) } }
                .keyboardShortcut("1", modifiers: .command)
                .hidden()
            Button("") { selection = (homes?.value.first).map { .home($0.id) } ?? .homes }
                .keyboardShortcut("2", modifiers: .command)
                .hidden()
            Button("") { selection = .trip }
                .keyboardShortcut("3", modifiers: .command)
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
                    .overlay(alignment: .topTrailing) {
                        if unseen(l) > 0 { UnseenDot().offset(x: Tokens.space1, y: -Tokens.space1) }
                    }
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
                }
            }
            .badge(arming == l.id || l.openCount == 0 ? Text(verbatim: "") : Text(verbatim: String(l.openCount)).font(Tokens.mono(.footnote)))
            .help(l.isTasks ? (unseen(l) > 0 ? Text("\(l.openCount) to do, \(unseen(l)) new") : Text("\(l.openCount) to do"))
                            : (unseen(l) > 0 ? Text("\(l.openCount) to get, \(unseen(l)) new") : Text("\(l.openCount) to get")))
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
                    if l.isPersonal {
                        Button("Share with the family") {
                            if let id = try? ListActions.shareList(l, in: session) { selection = .list(id) }
                        }
                    }
                    Divider()
                    Button("Archive") { arm(l) }
                }
            }
        }
    }

    /// Entries others added to a list since it was last in front here.
    private func unseen(_ l: ListSummary) -> Int {
        guard let h = session.currentHouseholdID else { return 0 }
        return session.unseen(household: h, in: marks?.value ?? [])[l.id] ?? 0
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

    /// New list at the foot: a click makes a household list, the menu offers Just me; the form
    /// is one field, return creates, escape cancels.
    @ViewBuilder
    private var sidebarFoot: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            Divider()
            if adding {
                HStack(spacing: Tokens.space2) {
                    ListDot(colour: ListActions.nextColour(lists?.value ?? []))
                        .frame(width: Tokens.space5)
                    TextField(personal ? "Just me" : "List name", text: $newName)
                        .textFieldStyle(.plain)
                        .focused($newNameFocused)
                        .onSubmit(create)
                        .onExitCommand { stopAdding() }
                        .accessibilityIdentifier("new-list-name")
                }
                .padding(.vertical, Tokens.space1)
                .transition(Motion.arrive(false, from: .bottom))
            } else {
                Menu {
                    Button("For the household") { startAdding(personal: false) }
                    Button("Just me") { startAdding(personal: true) }
                } label: {
                    Label("New list", systemImage: "plus")
                        .foregroundStyle(Tokens.accent)
                } primaryAction: {
                    startAdding(personal: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .padding(.vertical, Tokens.space1)
                .contentShape(Rectangle())
                .accessibilityIdentifier("new-list")
                .help(Text("A new list; the menu offers one only you see"))
            }
        }
        .padding(.horizontal, Tokens.space3)
        .padding(.vertical, Tokens.space2)
        .animation(Motion.base, value: adding)
    }

    private func startAdding(personal mine: Bool = false) {
        personal = mine
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
