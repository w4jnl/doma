// A list: the add field under the title, the match rows under it, the open rows, one hairline,
// the struck rows newest first, Recent collapsed at the foot. Clear and Shop mode in the
// toolbar, the long-press menu on a row. Everything is optimistic: the tap writes the store
// and the row moves; sync follows.
import SwiftUI

struct ListView: View {
    let listID: String
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var summary: Live<ListSummary?>?
    @State private var rows: Live<[EntryRow]>?
    @State private var recent: Live<[RecentRow]>?
    @State private var homes: Live<[HomeRow]>?
    @State private var matches: [Match] = []
    @State private var text = ""
    @State private var flash: String?
    @State private var showRecent = false
    @State private var shop = false
    @State private var editing: Editing?
    @State private var editText = ""
    @State private var selected: String?
    @FocusState private var fieldFocused: Bool
    @FocusState private var editFocused: Bool

    enum Editing: Hashable {
        case bought(String)
        case rename(String)
    }

    private var shopKey: String { "shop." + listID }

    var body: some View {
        VStack(spacing: 0) {
            if !shop { addField }
            List(selection: $selected) {
                if !shop, !matches.isEmpty, !text.isEmpty {
                    matchRows
                }
                let all = rows?.value ?? []
                let open = all.filter { !$0.isChecked }
                let struck = all.filter(\.isChecked)
                if all.isEmpty, text.isEmpty {
                    emptyState
                }
                Section {
                    ForEach(open) { row in
                        entryRow(row)
                            .tag(row.id)
                    }
                    .onMove { from, to in
                        try? ListActions.move(all, from: from, to: to, on: listID, in: session)
                    }
                }
                if !struck.isEmpty {
                    // the struck rows sink under one line: the last open row's separator, after a breath
                    Section {
                        ForEach(struck) { row in
                            entryRow(row)
                                .tag(row.id)
                        }
                    } header: {
                        Color.clear
                            .frame(height: Tokens.space2)
                            .accessibilityHidden(true)
                    }
                    .textCase(nil)
                }
                if let recent = recent?.value, !recent.isEmpty {
                    recentSection(recent)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, shop ? Tokens.rowHShop : Tokens.rowH)
            // the sink: on after the first strike here, so a screen never animates its first load
            .animation(reduceMotion || strikes == 0 ? nil : .easeOut(duration: 0.25), value: rows?.value)
            if shop { addField }
        }
        .background(Tokens.ground)
        .sensoryFeedback(.impact(weight: .light), trigger: strikes)
        .sensoryFeedback(.success, trigger: clears)
        .navigationTitle(summary?.value?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) { OfflineBadge() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    setShop(!shop)
                } label: {
                    if shop {
                        Label("Shop mode", systemImage: "basket")
                            .labelStyle(.titleAndIcon)
                    } else {
                        Label("Shop mode", systemImage: "basket")
                    }
                }
                .transaction { $0.animation = nil }
                .accessibilityValue(shop ? Text("on") : Text("off"))
                ArmedButton(title: "Clear", armedTitle: "Really clear?") {
                    clear()
                }
                .accessibilityIdentifier("clear")
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled((rows?.value ?? []).allSatisfy { !$0.isChecked })
            }
        }
        .onAppear {
            shop = UserDefaults.standard.bool(forKey: shopKey)
            applyShop()
        }
        .onDisappear {
            session.syncer.setPolling(seconds: nil)
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
        .task(id: text) {
            // the catalog answers 80 ms after the last keystroke, from a reader connection
            let t = text
            guard !t.isEmpty, let scope = session.scope else { matches = []; return }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let found = (try? await session.store.db.read { db in try Queries.matches(db, scope, prefix: t) }) ?? []
            if !Task.isCancelled { matches = found }
        }
        #if os(iOS)
        .onShake {
            // shake to clear, with the same armed confirm as the button
            if !(rows?.value ?? []).allSatisfy({ !$0.isChecked }) { shakeArmed = true }
        }
        .alert("Clear the struck items?", isPresented: $shakeArmed) {
            Button("Clear", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) {}
        }
        #endif
        .onKeyPress(.space) {
            guard let id = selected, let row = (rows?.value ?? []).first(where: { $0.id == id }) else { return .ignored }
            toggle(row)
            return .handled
        }
    }

    @State private var shakeArmed = false
    @State private var strikes = 0
    @State private var clears = 0

    // MARK: The add field and its matches

    private var addField: some View {
        HStack(spacing: Tokens.space2) {
            Image(systemName: "plus")
                .foregroundStyle(Tokens.accent)
                .accessibilityHidden(true)
            TextField("Add", text: $text)
                .accessibilityIdentifier("add-field")
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(addTyped)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Add an item"))
        }
        .font(shop ? .title3 : .body)
        .padding(.horizontal, Tokens.space3)
        .frame(minHeight: shop ? Tokens.rowHShop : Tokens.rowH)
        .background(Tokens.surfaceSunk, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
        .padding(.horizontal, Tokens.space4)
        .padding(.vertical, Tokens.space2)
    }

    private var matchRows: some View {
        Section {
            ForEach(Array(matches.enumerated()), id: \.element.id) { i, m in
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
                    .rowHeight()
                }
                .buttonStyle(.plain)
                .listRowBackground(i == 0 ? Tokens.accentSoft : Tokens.surface)
                .listRowSeparatorTint(Tokens.line)
            }
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

    private func toggle(_ row: EntryRow) {
        guard (try? ListActions.toggle(row, on: listID, in: session)) != nil else { return }
        strikes += 1
    }

    private func clear() {
        guard (try? ListActions.clear(listID, in: session)) != nil else { return }
        clears += 1
    }

    /// A list with nothing on it: the mark and the one thing to know.
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

    // MARK: Rows

    @ViewBuilder
    private func entryRow(_ row: EntryRow) -> some View {
        let isFlash = flash == row.id
        Group {
            if editing == .bought(row.id) || editing == .rename(row.id) {
                editRow(row)
            } else {
                Button {
                    toggle(row)
                } label: {
                    EntryRowView(row: row, shop: shop)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("entry-" + row.name)
            }
        }
        .listRowBackground(isFlash ? Tokens.accentSoft : Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: isFlash)
        .contextMenu {
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
            if row.isChecked {
                Button("Bought…") {
                    editText = row.detail
                    editing = .bought(row.id)
                    editFocused = true
                }
            }
            Button("Rename") {
                editText = row.name
                editing = .rename(row.id)
                editFocused = true
            }
            if let scope = session.scope, let others = try? session.store.read(scope, { db, s in try Queries.otherItems(db, s, listID: listID, except: row.itemID) }), !others.isEmpty {
                Menu("Merge with…") {
                    ForEach(others) { o in
                        Button(o.name) { try? ListActions.merge(row, into: o.itemID, in: session) }
                    }
                }
            }
        }
    }

    private func editRow(_ row: EntryRow) -> some View {
        HStack {
            if editing == .bought(row.id) {
                Text(row.name)
                    .foregroundStyle(Tokens.ink)
            }
            TextField(editing == .bought(row.id) ? "Quantity" : "Name", text: $editText)
                .textFieldStyle(.plain)
                .focused($editFocused)
                .font(editing == .bought(row.id) ? Tokens.mono(.body) : .body)
                .onSubmit {
                    if editing == .bought(row.id) {
                        try? ListActions.edit(row, text: editText, on: listID, in: session)
                    } else {
                        try? ListActions.rename(row, to: editText, in: session)
                    }
                    editing = nil
                }
            Button("Cancel") { editing = nil }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
        }
        .rowHeight(shop: shop)
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
                        .rowHeight(shop: shop)
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
                HStack {
                    Text("Recent")
                    Image(systemName: showRecent ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .foregroundStyle(Tokens.inkMuted)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showRecent ? Text("open") : Text("collapsed"))
        }
        .textCase(nil)
    }

    // MARK: Shop mode

    private func setShop(_ on: Bool) {
        shop = on
        UserDefaults.standard.set(on, forKey: shopKey)
        applyShop()
    }

    /// The lives are made on appear, before the first frame, so the screen never shows empty.
    private func observe() {
        guard let scope = session.scope else { return }
        let id = listID
        summary = Live(session.store, initial: nil) { db in try Queries.list(db, scope, id: id) }
        rows = Live(session.store, initial: []) { db in try Queries.entries(db, scope, listID: id) }
        recent = Live(session.store, initial: []) { db in try Queries.recent(db, scope, listID: id) }
        homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
    }

    private func applyShop() {
        session.syncer.setPolling(seconds: shop ? 5 : 10)
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = shop
        #endif
    }
}

/// One entry: the glyph, the item in ink, the quantity, unit and note in mono ink-muted, the
/// home chip; struck text through and in ink-faint. VoiceOver reads glyph and word.
struct EntryRowView: View {
    var row: EntryRow
    var shop = false

    var body: some View {
        HStack(spacing: Tokens.space3) {
            Text(verbatim: row.isChecked ? Tokens.Glyph.done : Tokens.Glyph.open)
                .foregroundStyle(row.isChecked ? Tokens.inkFaint : Tokens.inkMuted)
                .accessibilityHidden(true)
            Text(row.name)
                .strikethrough(row.isChecked, color: Tokens.inkFaint)
                .foregroundStyle(row.isChecked ? Tokens.inkFaint : Tokens.ink)
            if !row.detail.isEmpty {
                Text(row.detail)
                    .font(Tokens.mono(shop ? .body : .subheadline))
                    .foregroundStyle(row.isChecked ? Tokens.inkFaint : Tokens.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let home = row.homeName {
                Text(home)
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
                    .padding(.horizontal, Tokens.space2)
                    .frame(height: Tokens.chipH)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusXS))
            }
        }
        .font(shop ? .title3 : .body)
        .rowHeight(shop: shop)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.isChecked ? "checked, \(row.name) \(row.detail)" : "\(row.name) \(row.detail)"))
    }
}
