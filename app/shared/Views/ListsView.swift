// All lists, one level under the list on screen: the household's lists first, then the person's
// own, each with its dot, name and how many are to get; + creates one, with the next free colour.
// A long-press or a swipe on a row offers Rename and Archive, armed in place; the household's
// default list can only be renamed. Rename also offers the colour. A personal list also offers
// Share with the family: a household list of the same name takes what is open on it.
import SwiftUI

struct ListsView: View {
    /// Set when the overview is pushed from the Lists tab: a tap picks the list and pops back.
    var pick: ((String) -> Void)?
    @Environment(Session.self) private var session
    @State private var lists: Live<[ListSummary]>?
    @State private var marks: Live<[OpenMark]>?
    @State private var adding = false
    @State private var newName = ""
    @State private var personal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                newListSection
                    .transition(Motion.arrive(reduceMotion, from: .top))
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
            } header: {
                SectionHeader("Just me")
            } footer: {
                if mine.isEmpty {
                    Text("A list only you see. Tap + and choose Just me.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
        .animation(Motion.of(reduceMotion, Motion.base), value: adding)
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
            if adding {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        adding = false
                        newName = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create list", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    // the system's glass circle carries the shape; the accent tint says it makes something
                    Button {
                        adding = true
                        nameFocused = true
                    } label: {
                        Label("New list", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
        marks = Live(session.store, initial: []) { db in try Queries.openMarks(db, scope) }
    }

    /// Entries others added to a list since it was last in front here.
    private func unseen(_ l: ListSummary) -> Int {
        guard let h = session.currentHouseholdID else { return 0 }
        return session.unseen(household: h, in: marks?.value ?? [])[l.id] ?? 0
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
            .listRowBackground(Self.rowGround)
            .listRowSeparatorTint(Tokens.line)
            .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
            .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + Tokens.space5 + Tokens.space3 }
            .contextMenu {
                Button("Rename") { startRename(l) }
                if l.isPersonal {
                    Button("Share with the family") { share(l) }
                }
                if !l.isDefault {
                    Button("Archive") { arm(l) }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !l.isDefault {
                    Button("Archive") { arm(l) }
                }
                if l.isPersonal {
                    Button("Share with the family") { share(l) }
                        .tint(Tokens.inkMuted)
                }
                Button("Rename") { startRename(l) }
                    .tint(Tokens.accent)
            }
        }
    }

    private func rowContent(_ l: ListSummary) -> some View {
        HStack(spacing: Tokens.space3) {
            ListDot(colour: l.colour)
                .frame(width: Tokens.space5)
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
                // the bare number, as the sidebar says it; a dot in accent before it when
                // someone added something you have not seen; VoiceOver keeps the words
                if unseen(l) > 0 {
                    UnseenDot()
                }
                Text(verbatim: String(l.openCount))
                    .font(Tokens.mono(.subheadline))
                    .foregroundStyle(Tokens.inkMuted)
                    .contentTransition(.numericText())
                    .animation(Motion.base, value: l.openCount)
            }
        }
        .rowHeight()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unseen(l) > 0 ? Text("\(l.name), \(l.openCount) to get, \(unseen(l)) new") : Text("\(l.name), \(l.openCount) to get"))
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
        .listRowBackground(Self.rowGround)
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

    /// The personal list becomes a household one, and the screen follows it when it can.
    private func share(_ l: ListSummary) {
        guard let id = try? ListActions.shareList(l, in: session) else { return }
        pick?(id)
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

    /// Two rows while a list is being made: the name and who sees it; Cancel and Create live
    /// in the toolbar, as the system does it.
    private var newListSection: some View {
        Section {
            TextField("List name", text: $newName)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(create)
                .accessibilityLabel(Text("List name"))
                .listRowBackground(Self.rowGround)
            Picker("Who sees it", selection: $personal) {
                Text("Household").tag(false)
                Text("Just me").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Self.rowGround)
        } header: {
            SectionHeader("New list")
        }
    }

    /// Rows sit on `surface` in the phone's grouped list and on `ground` in the Mac's plain one.
    static var rowGround: Color {
        #if os(iOS)
        Tokens.surface
        #else
        Tokens.ground
        #endif
    }

    private func create() {
        let colour = ListActions.nextColour(lists?.value ?? [])
        guard let id = try? ListActions.createList(named: newName, personal: personal, colour: colour, in: session) else { return }
        newName = ""
        adding = false
        pick?(id)
    }
}
