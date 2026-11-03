// A list, one layout at home and in the shop: the open rows, a hairline that says how many are
// got with Clear beside it, the struck rows under it, Recent at the foot, and the add bar pinned
// at the bottom with the catalog's answers above it, nearest the thumb first. A tap strikes the
// row where it is; it stays there for a breath so a second tap can take it back, then it sinks.
// Everything is optimistic: the tap writes the store and the row answers; sync follows. The
// screen stays awake and syncs every 5 s while it is in front.
import GRDB
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ListView: View {
    let listID: String
    /// Set when the list is the Lists tab's root: the title becomes a menu over the lists.
    /// Opens the lists overview, when the list is the Lists tab's root; a pushed list has none.
    var overview: (() -> Void)?
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var summary: Live<ListSummary?>?
    @State private var rows: Live<[EntryRow]>?
    @State private var recent: Live<[RecentRow]>?
    @State private var homes: Live<[HomeRow]>?
    @State private var usual: [Match] = []
    @State private var matches: [Match] = []
    @State private var text = ""
    @State private var flash: String?
    @State private var showRecent = false
    @State private var editing: String?
    @State private var editText = ""
    @State private var editHome: String?
    @State private var held: [String: Hold] = [:]
    @State private var shown: [String: Bool] = [:]
    @State private var release: Task<Void, Never>?
    @State private var strikes = 0
    @State private var clears = 0
    @FocusState private var fieldFocused: Bool
    @FocusState private var editFocused: Bool
    #if os(macOS)
    @State private var selected: String?
    #endif

    /// A row just struck or restored keeps its place for a breath: the group it stays in and
    /// its order there.
    struct Hold: Hashable {
        var open: Bool
        var sort: Double
    }

    static let holdSeconds: Double = 1.5

    /// Entry rows are `row-h-list` under a thumb and `row-h` under a pointer.
    static var rowHeight: CGFloat {
        #if os(macOS)
        Tokens.rowH
        #else
        Tokens.rowHList
        #endif
    }

    var body: some View {
        let all = rows?.value ?? []
        let open = all.filter { held[$0.id]?.open ?? !$0.isChecked }
            .sorted { (held[$0.id]?.sort ?? $0.sort, $0.addedHLC) < (held[$1.id]?.sort ?? $1.sort, $1.addedHLC) }
        let struck = all.filter { !(held[$0.id]?.open ?? !$0.isChecked) }
            .sorted { (held[$0.id]?.sort ?? Self.struckSort($0)) < (held[$1.id]?.sort ?? Self.struckSort($1)) }
        let openCount = all.filter { !$0.isChecked }.count
        list(all: all, open: open, struck: struck)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .background(Tokens.ground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if editing == nil { addBar }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: strikes)
            .sensoryFeedback(.success, trigger: clears)
            .navigationTitle(summary?.value?.name ?? "")
            .navigationSubtitle(subtitle(open: openCount))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #else
            .toolbar(removing: .title)
            .safeAreaInset(edge: .top, spacing: 0) { paneTitle(open: openCount) }
            .frame(maxWidth: Tokens.contentMax)
            .frame(maxWidth: .infinity)
            .background(Tokens.ground)
            #endif
            .toolbar {
                #if os(iOS)
                if let overview {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            // the keyboard stays with this screen; drop it before leaving
                            fieldFocused = false
                            overview()
                        } label: {
                            HStack(spacing: Tokens.space1) {
                                Image(systemName: "list.bullet")
                                Text("Lists")
                            }
                        }
                        .accessibilityIdentifier("all-lists")
                    }
                }
                #endif
                ToolbarItem(placement: .automatic) { OfflineBadge() }
            }
            .onAppear {
                observe()
                session.syncer.setPolling(seconds: 5)
                #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = true
                #else
                fieldFocused = true
                #endif
            }
            .onChange(of: session.scope) { observe() }
            .onDisappear {
                // the keyboard belongs to this screen: it goes when the screen goes
                fieldFocused = false
                session.syncer.setPolling(seconds: nil)
                #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
                #endif
            }
            .onChange(of: rows?.value) { _, now in
                // the store caught up with what the rows already show
                for r in now ?? [] where shown[r.id] == r.isChecked { shown[r.id] = nil }
                loadUsual()
            }
            .task(id: text) {
                // the catalog answers 80 ms after the last keystroke, from a reader connection
                let t = text
                guard !t.isEmpty, let scope = session.scope else { matches = []; return }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                let found = (try? await session.store.db.read { db in try Queries.matches(db, scope, prefix: t) }) ?? []
                if !Task.isCancelled { matches = found }
            }
            #if os(macOS)
            .onKeyPress(.space) { toggleSelected() ? .handled : .ignored }
            .onDeleteCommand { _ = toggleSelected() }
            #endif
    }

    #if os(macOS)
    /// The list's title where the Mac's toolbar would say it small: the name large, the dot and
    /// the count under it, in the pane.
    private func paneTitle(open: Int) -> some View {
        VStack(alignment: .leading, spacing: Tokens.space1) {
            Text(summary?.value?.name ?? "")
                .font(.largeTitle.bold())
                .foregroundStyle(Tokens.ink)
            subtitle(open: open)
                .font(.subheadline)
                .foregroundStyle(Tokens.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.space4)
        .padding(.top, Tokens.space4)
        .padding(.bottom, Tokens.space2)
        .background(Tokens.ground)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Space or ⌫ on the selected row strikes it, or takes it back.
    private func toggleSelected() -> Bool {
        guard let id = selected, let row = (rows?.value ?? []).first(where: { $0.id == id }) else { return false }
        toggle(row)
        return true
    }
    #endif

    /// The list's dot and how many are to get, under the title.
    private func subtitle(open: Int) -> Text {
        let dot = Text(verbatim: "● ").foregroundStyle(Tokens.listColor(summary?.value?.colour ?? ""))
        return dot + (open == 0 ? Text("Nothing to get") : Text("\(open) to get"))
    }

    @ViewBuilder
    private func list(all: [EntryRow], open: [EntryRow], struck: [EntryRow]) -> some View {
        #if os(macOS)
        List(selection: $selected) { sections(all: all, open: open, struck: struck) }
        #else
        List { sections(all: all, open: open, struck: struck) }
        #endif
    }

    @ViewBuilder
    private func sections(all: [EntryRow], open: [EntryRow], struck: [EntryRow]) -> some View {
        if all.isEmpty, text.isEmpty {
            emptyState
        }
        Section {
            ForEach(open) { row in
                entryRow(row)
                    #if os(macOS)
                    .tag(row.id)
                    #endif
            }
            .onMove { from, to in
                try? ListActions.move(all, from: from, to: to, on: listID, in: session)
            }
        }
        if !struck.isEmpty {
            Section {
                ForEach(struck) { row in
                    entryRow(row)
                        #if os(macOS)
                        .tag(row.id)
                        #endif
                }
            } header: {
                dividerRow(count: struck.count)
            }
            .textCase(nil)
        }
        if let recent = recent?.value, !recent.isEmpty {
            recentSection(recent)
        }
    }

    /// A list with nothing on it: the mark and the one thing to know, under the title.
    private var emptyState: some View {
        Section {
            VStack(spacing: Tokens.space3) {
                Mark(size: 32)
                HelpLine(text: "Type what you need. Return adds it.")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.space6)
            .listRowBackground(Tokens.ground)
            .listRowSeparator(.hidden)
        }
    }

    /// The hairline between open and struck rows: how many are got, and Clear, armed in place.
    private func dividerRow(count: Int) -> some View {
        HStack {
            Text("\(count) got")
                .font(Tokens.mono(.footnote))
                .foregroundStyle(Tokens.inkMuted)
            Spacer()
            ArmedButton(title: "Clear", armedTitle: "Really clear?") {
                clear()
            }
            .font(.subheadline)
            .accessibilityIdentifier("clear")
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.vertical, Tokens.space2)
    }

    // MARK: The add bar, its matches and the usual items

    private var addBar: some View {
        VStack(spacing: 0) {
            if !text.isEmpty {
                suggestionRows
            } else if fieldFocused, !usual.isEmpty {
                usualChips
            }
            Rectangle()
                .fill(Tokens.line)
                .frame(height: 1)
                .accessibilityHidden(true)
            HStack(spacing: Tokens.space3) {
                ZStack {
                    Circle()
                        .fill(Tokens.accent)
                        .frame(width: Tokens.space5, height: Tokens.space5)
                    Image(systemName: "plus")
                        .font(.footnote.bold())
                        .foregroundStyle(Tokens.onAccent)
                }
                .accessibilityHidden(true)
                TextField("Add", text: $text)
                    .accessibilityIdentifier("add-field")
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .submitLabel(.return)
                    .onSubmit(addTyped)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text("Add an item"))
            }
            .padding(.horizontal, Tokens.space4)
            .frame(minHeight: ListView.rowHeight)
        }
        .background(Tokens.ground)
    }

    /// The catalog's answers above the bar, the best nearest the thumb; the row nearest the bar
    /// is what Return does: the exact item when the name exists, the typed line as new otherwise.
    private var suggestionRows: some View {
        let norm = Norm.name(text)
        let exact = matches.contains { Norm.name($0.name) == norm }
        return VStack(spacing: 0) {
            ForEach(Array(matches.prefix(5).reversed().enumerated()), id: \.element.id) { i, m in
                let nearest = exact && i == min(matches.count, 5) - 1
                Button {
                    add(itemID: m.itemID)
                } label: {
                    HStack {
                        Text(m.name)
                            .foregroundStyle(Tokens.ink)
                        Spacer()
                        if let last = m.lastBought {
                            HStack(spacing: Tokens.space1) {
                                Text("last bought")
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.inkMuted)
                                RelativeText(millis: last)
                            }
                        }
                    }
                    .padding(.horizontal, Tokens.space4)
                    .frame(minHeight: Tokens.rowH)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(nearest ? Tokens.accentSoft : Tokens.surface)
                Rectangle().fill(Tokens.line).frame(height: 1)
            }
            if !exact {
                Button(action: addTyped) {
                    HStack(spacing: Tokens.space2) {
                        Image(systemName: "plus")
                            .foregroundStyle(Tokens.accent)
                        Text(text)
                            .foregroundStyle(Tokens.ink)
                        Spacer()
                        Text("new")
                            .font(.footnote)
                            .foregroundStyle(Tokens.inkMuted)
                    }
                    .padding(.horizontal, Tokens.space4)
                    .frame(minHeight: Tokens.rowH)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Tokens.accentSoft)
            }
        }
    }

    /// The household's usual items as one row of chips while the field is empty: Saturday's
    /// list in eight taps.
    private var usualChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.space2) {
                ForEach(usual) { m in
                    Button {
                        add(itemID: m.itemID)
                    } label: {
                        Text(m.name)
                            .font(.footnote)
                            .foregroundStyle(Tokens.ink)
                            .padding(.horizontal, Tokens.space3)
                            .frame(height: Tokens.chipH)
                            .background(Tokens.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Tokens.line))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Tokens.space4)
            .padding(.vertical, Tokens.space2)
        }
    }

    private func addTyped() {
        let t = text
        // return takes the typed text as is: an exact name reuses the item, anything else makes one
        guard let outcome = try? ListActions.add(t, to: listID, in: session) else { return }
        after(outcome)
    }

    private func add(itemID: String) {
        guard let outcome = try? ListActions.add(itemID: itemID, to: listID, in: session) else { return }
        after(outcome)
    }

    private func after(_ outcome: AddOutcome) {
        text = ""
        matches = []
        fieldFocused = true
        if case .alreadyOpen(let entryID) = outcome {
            flash = entryID
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                if flash == entryID { flash = nil }
            }
        }
    }

    // MARK: Strike, hold, clear

    private func toggle(_ row: EntryRow) {
        let wasOpen = shown[row.id].map { !$0 } ?? !row.isChecked
        // a second tap within the hold keeps the place the first tap kept
        let hold = held[row.id] ?? Hold(open: !row.isChecked, sort: row.isChecked ? Self.struckSort(row) : row.sort)
        held[row.id] = hold
        shown[row.id] = wasOpen
        guard (try? ListActions.toggle(row, on: listID, in: session)) != nil else {
            held[row.id] = nil
            shown[row.id] = nil
            return
        }
        strikes += 1
        release?.cancel()
        release = Task {
            try? await Task.sleep(for: .seconds(Self.holdSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { held = [:] }
        }
    }

    private static func struckSort(_ row: EntryRow) -> Double {
        -Double(row.checkedHLC?.wall ?? 0)
    }

    private func clear() {
        guard (try? ListActions.clear(listID, in: session)) != nil else { return }
        clears += 1
        release?.cancel()
        held = [:]
    }

    // MARK: Rows

    @ViewBuilder
    private func entryRow(_ row: EntryRow) -> some View {
        if editing == row.id {
            editRow(row)
        } else {
            let checked = shown[row.id] ?? row.isChecked
            Button {
                toggle(row)
            } label: {
                EntryRowView(row: row, checked: checked)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("entry-" + row.name)
            .listRowBackground(flash == row.id ? Tokens.accentSoft : Tokens.ground)
            .listRowSeparatorTint(Tokens.line)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: flash == row.id)
            #if os(iOS)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Edit") { startEdit(row) }
                    .tint(Tokens.accent)
            }
            #else
            .contextMenu {
                Button(checked ? "Put back" : "Got it") { toggle(row) }
                Button("Edit") { startEdit(row) }
                if let homes = homes?.value, !homes.isEmpty {
                    Menu("For a home") {
                        ForEach(homes) { h in
                            Button(h.name) { try? ListActions.setHome(row, h.id, on: listID, in: session) }
                        }
                        if row.forHomeID != nil {
                            Button("No home") { try? ListActions.setHome(row, nil, on: listID, in: session) }
                        }
                    }
                }
                if let scope = session.scope, let others = try? session.store.read(scope, { db, s in try Queries.otherItems(db, s, listID: listID, except: row.itemID) }), !others.isEmpty {
                    Menu("Merge with…") {
                        ForEach(others) { o in
                            Button(o.name) { try? ListActions.merge(row, into: o.itemID, in: session) }
                        }
                    }
                }
            }
            #endif
        }
    }

    private func startEdit(_ row: EntryRow) {
        editText = row.detail.isEmpty ? row.name : row.name + " " + row.quantity
        if !row.note.isEmpty { editText += " " + row.note }
        editHome = row.forHomeID
        editing = row.id
        editFocused = true
    }

    /// Edit, in the row: the line as it would be typed, and the home when the household has
    /// homes. The add bar steps aside so one field is live.
    private func editRow(_ row: EntryRow) -> some View {
        HStack(spacing: Tokens.space3) {
            TextField("Name", text: $editText)
                .textFieldStyle(.plain)
                .focused($editFocused)
                .submitLabel(.done)
                .onSubmit {
                    try? ListActions.editLine(row, text: editText, home: editHome, on: listID, in: session)
                    editing = nil
                }
            if let homes = homes?.value, !homes.isEmpty {
                Menu {
                    Button("No home") { editHome = nil }
                    ForEach(homes) { h in
                        Button(h.name) { editHome = h.id }
                    }
                } label: {
                    Text(homes.first { $0.id == editHome }?.name ?? String(localized: "Home"))
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                        .padding(.horizontal, Tokens.space2)
                        .frame(height: Tokens.chipH)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusXS))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.radiusXS).strokeBorder(Tokens.line))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
            Button("Cancel") { editing = nil }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
        }
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.surface)
    }

    private func recentSection(_ recent: [RecentRow]) -> some View {
        Section {
            if showRecent {
                ForEach(recent) { r in
                    Button {
                        add(itemID: r.itemID)
                    } label: {
                        HStack {
                            Text(r.name)
                                .foregroundStyle(Tokens.inkMuted)
                            Spacer()
                            RelativeText(millis: r.clearedAt)
                        }
                        .frame(minHeight: Tokens.rowH)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Tokens.ground)
                    .listRowSeparatorTint(Tokens.line)
                    .accessibilityHint(Text("Adds it again"))
                }
            }
        } header: {
            Button {
                showRecent.toggle()
            } label: {
                HStack(spacing: Tokens.space1) {
                    Text("Recent")
                        .font(.subheadline)
                    Image(systemName: showRecent ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Tokens.inkFaint)
                }
                .foregroundStyle(Tokens.inkMuted)
                .padding(.vertical, Tokens.space2)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showRecent ? Text("open") : Text("collapsed"))
        }
        .textCase(nil)
    }

    // MARK: Reading

    /// The lives are made on appear, before the first frame, so the screen never shows empty.
    private func observe() {
        guard let scope = session.scope else { return }
        let id = listID
        summary = Live(session.store, initial: nil) { db in try Queries.list(db, scope, id: id) }
        rows = Live(session.store, initial: []) { db in try Queries.entries(db, scope, listID: id) }
        recent = Live(session.store, initial: []) { db in try Queries.recent(db, scope, listID: id) }
        homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
        loadUsual()
    }

    private func loadUsual() {
        guard let scope = session.scope else { return }
        let id = listID
        Task {
            let found = (try? await session.store.db.read { db in try Queries.usual(db, scope, listID: id) }) ?? []
            usual = found
        }
    }
}

/// One entry: the glyph in its column, the item in ink, the note in mono ink-muted after it, the
/// home chip and the quantity in a mono column at the right; struck, the text goes ink-faint
/// under a line that draws across it and the glyph pops once in accent. VoiceOver reads glyph
/// and word.
struct EntryRowView: View {
    var row: EntryRow
    var checked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop = false

    var body: some View {
        HStack(spacing: Tokens.space3) {
            Text(verbatim: checked ? Tokens.Glyph.done : Tokens.Glyph.open)
                .foregroundStyle(pop ? Tokens.accent : (checked ? Tokens.inkFaint : Tokens.inkMuted))
                .scaleEffect(pop ? 1.2 : 1)
                .frame(width: Tokens.space5)
                .accessibilityHidden(true)
            Text(row.name)
                .foregroundStyle(checked ? Tokens.inkFaint : Tokens.ink)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Tokens.inkMuted)
                        .frame(height: 1)
                        .scaleEffect(x: checked ? 1 : 0, anchor: .leading)
                        .accessibilityHidden(true)
                }
            if !row.note.isEmpty {
                Text(row.note)
                    .font(Tokens.mono(.subheadline))
                    .foregroundStyle(checked ? Tokens.inkFaint : Tokens.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.space2)
            if let home = row.homeName {
                Text(home)
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
                    .padding(.horizontal, Tokens.space2)
                    .frame(height: Tokens.chipH)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusXS))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.radiusXS).strokeBorder(Tokens.line))
            }
            if !row.quantity.isEmpty {
                Text(row.quantity)
                    .font(Tokens.mono(.subheadline))
                    .foregroundStyle(checked ? Tokens.inkFaint : Tokens.inkMuted)
            }
        }
        .frame(minHeight: ListView.rowHeight)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: checked)
        .onChange(of: checked) { _, now in
            guard now, !reduceMotion else { return }
            withAnimation(.spring(duration: 0.15)) { pop = true }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.easeOut(duration: 0.2)) { pop = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(checked ? "checked, \(row.name) \(row.detail)" : "\(row.name) \(row.detail)"))
    }
}
