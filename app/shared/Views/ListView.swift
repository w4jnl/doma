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
    @Environment(\.scenePhase) private var scenePhase
    /// On screen, between appear and disappear.
    @State private var visible = false
    #if os(macOS)
    @Environment(MacNav.self) private var nav
    @State private var hovered: String?
    #endif
    @State private var summary: Live<ListSummary?>?
    /// Things to do rather than to buy: the words change, homes and purchases do not apply.
    private var isTasks: Bool { summary?.value?.isTasks ?? false }
    @State private var rows: Live<[EntryRow]>?
    @State private var recent: Live<[RecentRow]>?
    @State private var homes: Live<[HomeRow]>?
    @State private var usual: [Match] = []
    @State private var matches: [Match] = []
    @State private var text = ""
    /// Where the add field's insertion point is: after the words the mic puts in.
    @State private var selection: TextSelection?
    /// Rows to show on `accentSoft` for a moment: one just added, one already on the list, or
    /// ones that arrived from another device. Entry ids.
    @State private var flashed: Set<String> = []
    /// The item just added here, so its row flashes and scrolls into view when it arrives, and
    /// is not taken for a remote one.
    @State private var justAdded: String?
    @State private var showRecent = false
    @State private var editing: String?
    @State private var editText = ""
    @State private var editHome: String?
    @State private var held: [String: Hold] = [:]
    @State private var shown: [String: Bool] = [:]
    @State private var release: Task<Void, Never>?
    /// The list's seen mark when this visit began: rows others added after it wear a dot for
    /// the whole visit, while the mark itself moves on so the icon and the overview settle.
    @State private var visitMark: String?
    @State private var strikes = 0
    @State private var restores = 0
    @State private var adds = 0
    @State private var repeats = 0
    @State private var clears = 0
    @State private var micTaps = 0
    /// What the mic could not do, under the add field until the next try.
    @State private var voiceProblem: String?
    @FocusState private var fieldFocused: Bool
    @FocusState private var editFocused: Bool
    #if os(macOS)
    @State private var selected: String?
    #else
    /// When the list, or doma, last came to the front: a tap right after is no strike.
    @State private var front = Date.distantPast
    @AppStorage(StrikeGuard.key) private var guardSeconds = StrikeGuard.defaultSeconds
    #endif

    /// A row just struck or restored keeps its place for a breath: the group it stays in and
    /// its order there.
    struct Hold: Hashable {
        var open: Bool
        var sort: Double
    }

    static let holdSeconds: Double = 2.5

    /// Entry rows are `row-h-list` under a thumb and `row-h-compact` under a pointer.
    static var rowHeight: CGFloat {
        #if os(macOS)
        Tokens.rowHCompact
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
        let ids = open.map(\.id) + ["|"] + struck.map(\.id)
        ScrollViewReader { proxy in
            list(all: all, open: open, struck: struck, openCount: openCount)
                .onChange(of: ids) { before, now in arrived(before: before, now: now, rows: all, proxy: proxy) }
        }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            // the rows come from the store's observation, not from the tap: the list animates
            // on their identity, so an add, a sink and a clear move instead of redraw
            .animation(Motion.of(reduceMotion, Motion.base), value: ids)
            .animation(Motion.of(reduceMotion, .easeInOut(duration: Tokens.motionQuick)), value: editing)
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .background(Tokens.ground)
            #if os(iOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if editing == nil {
                    addBar
                        .transition(Motion.arrive(reduceMotion, from: .bottom))
                }
            }
            #endif
            // a strike and a restore are felt as hard as the engine goes, so a blind tap is noticed
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: strikes)
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1), trigger: restores)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: adds)
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.5), trigger: repeats)
            .sensoryFeedback(.success, trigger: clears)
            // the mic taps back at once, then says when it listens and when it stops
            .sensoryFeedback(.impact(weight: .light), trigger: micTaps)
            .sensoryFeedback(trigger: session.dictation.busy) { _, now in now ? .start : .stop }
            .navigationTitle(summary?.value?.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #else
            .toolbar(removing: .title)
            .safeAreaInset(edge: .top, spacing: 0) { paneTitle(open: openCount) }
            .modifier(MacPane())
            .modifier(MacMenu(struck: !struck.isEmpty, selected: selected != nil, onToggle: { _ = toggleSelected() }, onEdit: { _ = editSelected() }, onClear: clear))
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
                            // the toolbar drops a Label's word; this keeps it
                            HStack(spacing: Tokens.space1) {
                                Image(systemName: "list.bullet")
                                Text("Lists")
                            }
                        }
                        .accessibilityIdentifier("all-lists")
                    }
                }
                if summary?.value?.isTasks != true {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: CardsRoute()) {
                            Label("Cards", systemImage: "creditcard")
                        }
                        .accessibilityIdentifier("cards")
                    }
                }
                ToolbarItem(placement: .automatic) { OfflineBadge() }
                    .sharedBackgroundVisibility(.hidden)
                #else
                if summary?.value?.isTasks != true {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            nav.showCards += 1
                        } label: {
                            Label("Cards", systemImage: "creditcard")
                        }
                        .help("The family's cards")
                        .accessibilityIdentifier("cards")
                    }
                }
                ToolbarItem(placement: .automatic) { OfflineBadge() }
                #endif
            }
            .onAppear {
                observe()
                visible = true
                beginVisit()
                session.syncer.setPolling(seconds: 5)
                #if os(iOS)
                front = .now
                UIApplication.shared.isIdleTimerDisabled = true
                #else
                nav.listInFront = true
                if (rows?.value ?? []).isEmpty { fieldFocused = true }
                #endif
            }
            .onChange(of: session.scope) { observe() }
            .onChange(of: rows?.value) { markSeen() }
            // back from the background with the list in front: what came while away is new
            .onChange(of: scenePhase) { _, now in
                if now == .active, visible { beginVisit() }
                if now == .background { stopDictation() }
                #if os(iOS)
                if now == .active { front = .now }
                #endif
            }
            .onDisappear {
                visible = false
                stopDictation()
                // the keyboard belongs to this screen: it goes when the screen goes
                fieldFocused = false
                session.syncer.setPolling(seconds: nil)
                #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
                #else
                nav.listInFront = false
                nav.hasSelectedEntry = false
                nav.hasStruck = false
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
                let tasks = isTasks
                let found = (try? await session.store.db.read { db in try Queries.matches(db, scope, prefix: t, tasks: tasks) }) ?? []
                if !Task.isCancelled { matches = found }
            }
            #if os(macOS)
            .modifier(MacKeys(onToggle: toggleSelected, onEdit: editSelected, onType: startTyping))
            #endif
    }

    #if os(macOS)
    /// The list's title where the Mac's toolbar would say it small: the name large, the dot and
    /// the count under it, in the pane.
    private func paneTitle(open: Int) -> some View {
        VStack(alignment: .leading, spacing: Tokens.space1) {
            Text(summary?.value?.name ?? "")
                .font(.title.weight(.semibold))
                .foregroundStyle(Tokens.ink)
            countRow(open: open)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.space4)
        .padding(.top, Tokens.space5)
        .padding(.bottom, Tokens.space3)
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

    /// Return, a double click or Edit Item opens the selected row in place.
    @discardableResult
    private func editSelected() -> Bool {
        guard let id = selected, let row = (rows?.value ?? []).first(where: { $0.id == id }) else { return false }
        startEdit(row)
        return true
    }

    /// Typing with the list in front starts an entry, as Finder finds and Things adds.
    private func startTyping(_ characters: String) -> Bool {
        guard !fieldFocused, editing == nil else { return false }
        text = characters
        fieldFocused = true
        return true
    }

    /// The add row under the last open item: the plus in the glyph column, the field after it,
    /// the matches as rows beneath, best first, and the usual chips while the field is empty.
    @ViewBuilder
    private var addRowMac: some View {
        HStack(spacing: Tokens.space3) {
            Image(systemName: "plus")
                .font(.title3)
                .imageScale(.large)
                .foregroundStyle(Tokens.accent)
                .frame(width: Tokens.space5)
                .accessibilityHidden(true)
            TextField("Add", text: $text, selection: $selection)
                .accessibilityIdentifier("add-field")
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(addTyped)
                .onExitCommand { fieldFocused = false; text = "" }
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Add an item"))
                .overlay(alignment: .leading) { hearing }
            MicButton(listener: session.dictation, tap: toggleDictation, pick: dictate(in:))
        }
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.ground)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        if let voiceProblem {
            ProblemLine(text: voiceProblem)
                .padding(.leading, Tokens.space5 + Tokens.space3)
                .listRowBackground(Tokens.ground)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: Tokens.space2, trailing: Tokens.space4))
        }
        if !text.isEmpty {
            ForEach(Array(matches.prefix(5).enumerated()), id: \.element.id) { i, m in
                let exact = matches.contains { Norm.name($0.name) == Norm.name(text) }
                Button { add(itemID: m.itemID) } label: {
                    HStack {
                        Text(m.name).foregroundStyle(Tokens.ink)
                        Spacer()
                        if let last = m.lastBought {
                            HStack(spacing: Tokens.space1) {
                                (isTasks ? Text("last done") : Text("last bought")).font(.footnote).foregroundStyle(Tokens.inkMuted)
                                RelativeText(millis: last)
                            }
                        }
                    }
                    .padding(.leading, Tokens.space5 + Tokens.space3)
                    .frame(minHeight: ListView.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(exact && i == 0 ? Tokens.accentSoft : Tokens.surface)
                .listRowSeparatorTint(Tokens.line)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                .transition(.opacity)
            }
            if !matches.contains(where: { Norm.name($0.name) == Norm.name(text) }) {
                Button(action: addTyped) {
                    HStack(spacing: Tokens.space2) {
                        Text(text).foregroundStyle(Tokens.ink)
                        Spacer()
                        Text("new").font(.footnote).foregroundStyle(Tokens.inkMuted)
                    }
                    .padding(.leading, Tokens.space5 + Tokens.space3)
                    .frame(minHeight: ListView.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Tokens.accentSoft)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                .transition(.opacity)
            }
        } else if fieldFocused, !usual.isEmpty {
            usualChips
                .listRowBackground(Tokens.ground)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4 + Tokens.space5 + Tokens.space3, bottom: 0, trailing: Tokens.space4))
                .transition(.opacity)
        }
    }
    #endif

    /// The list's dot and how many are to get, under the title: the number rolls when it
    /// changes, which is also how a change from another phone shows itself.
    private func countRow(open: Int) -> some View {
        HStack(spacing: Tokens.space2) {
            ListDot(colour: summary?.value?.colour ?? "")
            Group {
                if isTasks {
                    open == 0 ? Text("Nothing to do") : Text("\(open) to do")
                } else {
                    open == 0 ? Text("Nothing to get") : Text("\(open) to get")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Tokens.inkMuted)
            .contentTransition(.numericText(countsDown: true))
            .animation(Motion.of(reduceMotion, Motion.base), value: open)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func list(all: [EntryRow], open: [EntryRow], struck: [EntryRow], openCount: Int) -> some View {
        #if os(macOS)
        List(selection: $selected) { sections(all: all, open: open, struck: struck, openCount: openCount) }
        #else
        List { sections(all: all, open: open, struck: struck, openCount: openCount) }
        #endif
    }

    @ViewBuilder
    private func sections(all: [EntryRow], open: [EntryRow], struck: [EntryRow], openCount: Int) -> some View {
        #if os(iOS)
        countRow(open: openCount)
            .listRowBackground(Tokens.ground)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
            .frame(minHeight: Tokens.space5)
        #endif
        if all.isEmpty, text.isEmpty {
            emptyState
                .transition(.opacity.animation(.easeOut(duration: Tokens.motionBase).delay(Tokens.motionQuick)))
        }
        Section {
            ForEach(open) { row in
                entryRow(row)
                    .transition(Motion.arrive(reduceMotion, from: .bottom))
                    #if os(macOS)
                    .tag(row.id)
                    #endif
            }
            .onMove { from, to in
                try? ListActions.move(all, from: from, to: to, on: listID, in: session)
            }
            #if os(macOS)
            if editing == nil { addRowMac }
            #endif
        }
        if !struck.isEmpty {
            Section {
                dividerRow(count: struck.count)
                    .transition(.opacity)
                    .listRowBackground(Tokens.ground)
                    .listRowSeparator(.hidden, edges: .bottom)
                    .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                ForEach(struck) { row in
                    entryRow(row)
                        .transition(.opacity)
                        #if os(macOS)
                        .tag(row.id)
                        #endif
                }
            }
        }
        if let recent = recent?.value, !recent.isEmpty {
            recentSection(recent)
                .transition(.opacity.animation(.easeOut(duration: Tokens.motionBase).delay(Tokens.motionQuick)))
        }
    }

    /// Rows that arrived: the one added here scrolls into view; the others came from another
    /// device and flash the same way, without a scroll or a haptic.
    private func arrived(before: [String], now: [String], rows: [EntryRow], proxy: ScrollViewProxy) {
        let fresh = Set(now).subtracting(before).subtracting(["|"])
        guard !fresh.isEmpty else { return }
        var remote = fresh
        if let item = justAdded, let mine = rows.first(where: { $0.itemID == item && fresh.contains($0.id) }) {
            remote.remove(mine.id)
            justAdded = nil
            if reduceMotion {
                proxy.scrollTo(mine.id, anchor: .bottom)
            } else {
                withAnimation(.snappy(duration: Tokens.motionSettle)) { proxy.scrollTo(mine.id, anchor: .bottom) }
            }
            flash([mine.id], for: Tokens.motionBase + Tokens.motionSettle)
        }
        if !remote.isEmpty, before.count > 1 {
            // not on the first load, which arrives whole
            flash(remote, for: Tokens.motionBase + Tokens.motionSettle)
        }
    }

    /// A visit begins: what others added after the last visit's mark is new for this one.
    private func beginVisit() {
        visitMark = session.seenMark(household: session.currentHouseholdID ?? "", list: listID) ?? ""
        markSeen()
    }

    /// Everything on the list has been in front: the seen mark moves to the newest entry. Only
    /// while the app is active and the list on screen; a sync in the background marks nothing.
    private func markSeen() {
        guard visible, scenePhase == .active, let h = session.currentHouseholdID else { return }
        let newest = (rows?.value ?? []).map(\.addedHLC).max()
        guard let newest else { return }
        session.markSeen(household: h, list: listID, upTo: newest.description)
        session.refreshBadge()
    }

    /// Someone else added it after this visit began from the last seen mark.
    private func isNew(_ row: EntryRow) -> Bool {
        guard let mark = visitMark, row.addedBy != session.context?.personID else { return false }
        return row.addedHLC.description > mark
    }

    private func flash(_ ids: Set<String>, for seconds: Double) {
        flashed.formUnion(ids)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            flashed.subtract(ids)
        }
    }

    /// A list with nothing on it: the mark and the one thing to know, under the title.
    private var emptyState: some View {
        Section {
            VStack(spacing: Tokens.space3) {
                Mark(size: 32)
                HelpLine(text: isTasks ? "Type what needs doing. Return adds it." : "Type what you need. Return adds it.")
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
            (isTasks ? Text("\(count) done") : Text("\(count) got"))
                .font(Tokens.mono(.footnote))
                .foregroundStyle(Tokens.inkMuted)
                .contentTransition(.numericText())
                .animation(Motion.of(reduceMotion, Motion.base), value: count)
            Spacer()
            ArmedButton(title: "Clear", armedTitle: "Really clear?", tint: Tokens.accent) {
                clear()
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("clear")
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.top, Tokens.space4)
        .padding(.bottom, Tokens.space2)
    }

    // MARK: The add bar, its matches and the usual items

    @ViewBuilder
    private var addBar: some View {
        #if os(iOS)
        // the one glass in the app: the bar floats like the tab bar it sits over, the matches
        // and chips in the same glass above it
        GlassEffectContainer(spacing: Tokens.space2) {
            VStack(spacing: Tokens.space2) {
                if !text.isEmpty {
                    suggestionRows
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusMD))
                        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.radiusMD))
                        .transition(Motion.arrive(reduceMotion, from: .bottom))
                } else if fieldFocused, !usual.isEmpty {
                    usualChips
                        .transition(Motion.arrive(reduceMotion, from: .bottom))
                }
                if let voiceProblem {
                    ProblemLine(text: voiceProblem)
                        .padding(.horizontal, Tokens.space4)
                        .padding(.vertical, Tokens.space2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.radiusMD))
                        .transition(Motion.arrive(reduceMotion, from: .bottom))
                }
                addField
                    .padding(.horizontal, Tokens.space4)
                    .frame(minHeight: ListView.rowHeight)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal, Tokens.space4)
            .padding(.bottom, Tokens.space2)
        }
        .animation(Motion.of(reduceMotion, Motion.quick), value: matches.map(\.id))
        .animation(Motion.of(reduceMotion, Motion.quick), value: text.isEmpty)
        .animation(Motion.of(reduceMotion, Motion.quick), value: fieldFocused && !usual.isEmpty)
        .animation(Motion.of(reduceMotion, Motion.quick), value: voiceProblem)
        #else
        VStack(spacing: 0) {
            if !text.isEmpty {
                suggestionRows
                    .transition(Motion.arrive(reduceMotion, from: .bottom))
            } else if fieldFocused, !usual.isEmpty {
                usualChips
                    .transition(Motion.arrive(reduceMotion, from: .bottom))
            }
            Rectangle()
                .fill(Tokens.line)
                .frame(height: 1)
                .accessibilityHidden(true)
            addField
                .padding(.horizontal, Tokens.space4)
                .frame(minHeight: ListView.rowHeight)
        }
        .background(Tokens.ground)
        .animation(Motion.of(reduceMotion, Motion.quick), value: matches.map(\.id))
        .animation(Motion.of(reduceMotion, Motion.quick), value: text.isEmpty)
        .animation(Motion.of(reduceMotion, Motion.quick), value: fieldFocused && !usual.isEmpty)
        #endif
    }

    /// The accent disc and the field with no box.
    private var addField: some View {
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
            TextField("Add", text: $text, selection: $selection)
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
                .overlay(alignment: .leading) { hearing }
            MicButton(listener: session.dictation, tap: toggleDictation, pick: dictate(in:))
        }
    }

    /// The words the model may still change, faint after what is in the field; the field's own
    /// text sits under them unseen so they start where it ends.
    @ViewBuilder
    private var hearing: some View {
        let volatile = session.dictation.heard.volatile
        if session.dictation.busy, !volatile.isEmpty {
            HStack(spacing: text.isEmpty ? 0 : Tokens.space1) {
                Text(text).opacity(0)
                Text(volatile)
                    .foregroundStyle(Tokens.inkFaint)
                    .lineLimit(1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Saying an item

    /// The mic's tap: listen in the language last chosen, or stop. Each piece the model settles
    /// lands in the field as if typed, the matches answer it, and a pause adds it as return
    /// would. Stopping keeps the words in the field.
    private func toggleDictation() {
        let listener = session.dictation
        micTaps += 1
        if listener.busy {
            stopDictation()
            return
        }
        voiceProblem = nil
        listener.lines = false
        listener.words = { piece in
            text = Heard.item(Heard.join(text, piece))
            // the insertion point follows the words, so typing goes on after them
            selection = TextSelection(insertionPoint: text.endIndex)
        }
        listener.paused = {
            if !text.isEmpty { addSpoken() }
        }
        Task {
            await listener.start(Language.remembered)
            if case .failed(let why) = listener.state { voiceProblem = why }
        }
    }

    /// The pause's add: the spoken line split into the items it names, by the catalog's names
    /// and the separators said, each added as return would. Nothing said is lost: what no rule
    /// splits is one item.
    private func addSpoken() {
        guard let scope = session.scope else { return }
        let names = (try? session.store.read(scope) { db, s in try Queries.itemNames(db, s) }) ?? []
        let pieces = Spoken.split(text, language: Language.remembered, names: names)
        guard !pieces.isEmpty else { text = ""; return }
        for piece in pieces {
            guard let outcome = try? ListActions.add(piece, to: listID, in: session) else { continue }
            after(outcome)
        }
    }

    /// The language chosen under the mic: remembered, and listened in from now.
    private func dictate(in language: Language) {
        Language.remembered = language
        let listener = session.dictation
        Task {
            if listener.busy { await listener.stop() }
            toggleDictation()
        }
    }

    private func stopDictation() {
        let listener = session.dictation
        guard listener.busy else { return }
        Task { await listener.stop() }
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
                                (isTasks ? Text("last done") : Text("last bought"))
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
                .transition(.opacity)
                #if os(macOS)
                Rectangle().fill(Tokens.line).frame(height: 1)
                #else
                if i < min(matches.count, 5) - 1 || !exact { Rectangle().fill(Tokens.line).frame(height: 1) }
                #endif
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
                            .contentShape(Capsule())
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
        // the keyboard stays for the next tap; a spoken add does not call it up
        if !session.dictation.busy { fieldFocused = true }
        switch outcome {
        case .added(let itemID):
            // the row arrives through the store's observation; `arrived` scrolls to it and
            // flashes it, a soft tap says it took
            justAdded = itemID
            adds += 1
            if let row = (rows?.value ?? []).first(where: { $0.itemID == itemID }) {
                // a struck row restored by the add is there already
                justAdded = nil
                flash([row.id], for: Tokens.motionBase + Tokens.motionSettle)
            }
        case .alreadyOpen(let entryID):
            // it was there: a harder tap than an add, and the row shows itself longer
            repeats += 1
            flash([entryID], for: 0.9)
        case .nothingTyped:
            break
        }
    }

    // MARK: Strike, hold, clear

    private func toggle(_ row: EntryRow) {
        #if os(iOS)
        // a tap in the first moment after the list or doma came to the front is a pocket or a
        // pickup, not a strike; the UI tests tap at once
        guard UITestHooks.testing || StrikeGuard(since: front, seconds: guardSeconds).allows(.now) else { return }
        #endif
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
        if wasOpen { strikes += 1 } else { restores += 1 }
        release?.cancel()
        release = Task {
            try? await Task.sleep(for: .seconds(Self.holdSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.of(reduceMotion, Motion.settle)) { held = [:] }
        }
    }

    private static func struckSort(_ row: EntryRow) -> Double {
        -Double(row.checkedHLC?.wall ?? 0)
    }

    private func clear() {
        guard (try? ListActions.clear(listID, in: session)) != nil else { return }
        clears += 1
        release?.cancel()
        withAnimation(Motion.of(reduceMotion, .easeOut(duration: Tokens.motionBase))) { held = [:] }
    }

    // MARK: Rows

    @ViewBuilder
    private func entryRow(_ row: EntryRow) -> some View {
        if editing == row.id {
            editRow(row)
        } else {
            let checked = shown[row.id] ?? row.isChecked
            let gotBy = checked ? session.name(of: row.checkedBy) : nil
            let fresh = !checked && isNew(row)
            #if os(iOS)
            Button {
                toggle(row)
            } label: {
                EntryRowView(row: row, checked: checked, gotBy: gotBy, isNew: fresh, held: held[row.id] != nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("entry-" + row.name)
            .listRowBackground(flashed.contains(row.id) ? Tokens.accentSoft : Tokens.ground)
            .listRowSeparatorTint(Tokens.line)
            .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
            .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + Tokens.space5 + Tokens.space3 }
            .animation(.easeOut(duration: Tokens.motionBase), value: flashed.contains(row.id))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Not needed") { try? ListActions.remove(row, on: listID, in: session) }
                    .tint(Tokens.inkMuted)
                Button("Edit") { startEdit(row) }
                    .tint(Tokens.accent)
            }
            #else
            // a click selects, the symbol strikes, a double click or return edits
            EntryRowView(row: row, checked: checked, gotBy: gotBy, isNew: fresh, held: held[row.id] != nil, hovered: hovered == row.id) { toggle(row) }
                .accessibilityIdentifier("entry-" + row.name)
                .onTapGesture(count: 2) { startEdit(row) }
                .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: Tokens.radiusSM)
                        .fill(selected == row.id || flashed.contains(row.id) ? Tokens.accentSoft : (hovered == row.id ? Tokens.surface : .clear))
                        .padding(.horizontal, Tokens.space2)
                        .animation(.easeOut(duration: Tokens.motionQuick), value: hovered == row.id)
                        .animation(.easeOut(duration: Tokens.motionBase), value: flashed.contains(row.id))
                )
                .listRowSeparatorTint(Tokens.line)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + Tokens.space5 + Tokens.space3 }
            .contextMenu {
                Button(checked ? "Put back" : "Got it") { toggle(row) }
                Button("Edit") { startEdit(row) }
                Button("Not needed") { try? ListActions.remove(row, on: listID, in: session) }
                if !isTasks, let homes = homes?.value, !homes.isEmpty {
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
            if !isTasks, let homes = homes?.value, !homes.isEmpty {
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
            #if os(iOS)
            Button("Cancel") { editing = nil }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
            #endif
        }
        .frame(minHeight: ListView.rowHeight)
        #if os(macOS)
        .onExitCommand { editing = nil }
        #endif
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
                                .foregroundStyle(Tokens.ink)
                            Spacer()
                            RelativeText(millis: r.clearedAt)
                        }
                        .frame(minHeight: Tokens.rowH)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .listRowBackground(Tokens.ground)
                    .listRowSeparatorTint(Tokens.line)
                    .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                    .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + Tokens.space5 + Tokens.space3 }
                    .accessibilityHint(Text("Adds it again"))
                }
            }
        } header: {
            Button {
                withAnimation(Motion.of(reduceMotion, .easeInOut(duration: Tokens.motionQuick + 0.05))) { showRecent.toggle() }
            } label: {
                HStack(spacing: Tokens.space1) {
                    Text("Recent")
                        .font(.subheadline)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showRecent ? 90 : 0))
                }
                .foregroundStyle(Tokens.inkMuted)
                .padding(.top, Tokens.space4)
                .padding(.bottom, Tokens.space2)
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

/// One entry: the open or done symbol in its column, the item in ink, the note after it in the
/// system face, the home chip and the quantity in a mono column at the right; struck, the text
/// goes ink-faint under a line that draws across it and the symbol pops once in accent.
/// VoiceOver reads glyph and word.
struct EntryRowView: View {
    var row: EntryRow
    var checked: Bool
    /// Who struck it, when it was someone else and the household has more than one member.
    var gotBy: String?
    /// Someone else added it since the list was last in front: a dot on the symbol this visit.
    var isNew: Bool = false
    /// Just struck or restored and keeping its place for a breath: the word for the second
    /// tap sits at the row's edge, so what happened reads and the way back has a name.
    var held: Bool = false
    /// Under a pointer the row is hovered and the symbol is the strike control.
    var hovered: Bool = false
    var strike: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop = false

    private var symbolColour: Color {
        if pop || hovered { return Tokens.accent }
        return checked ? Tokens.inkFaint : Tokens.inkMuted
    }

    var body: some View {
        HStack(spacing: Tokens.space3) {
            Group {
                if let strike {
                    Button(action: strike) {
                        symbol
                    }
                    .buttonStyle(.plain)
                    .help(checked ? Text("Put back") : Text("Got it"))
                    .accessibilityLabel(checked ? Text("Put back") : Text("Got it"))
                } else {
                    symbol
                        .accessibilityHidden(true)
                }
            }
            .frame(width: Tokens.space5)
            .overlay(alignment: .topTrailing) {
                if isNew { UnseenDot().transition(.opacity) }
            }
            Text(row.name)
                .font(.body)
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
                    .font(.subheadline)
                    .foregroundStyle(checked ? Tokens.inkFaint : Tokens.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let gotBy {
                Text(gotBy)
                    .font(.caption)
                    .foregroundStyle(Tokens.inkFaint)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: Tokens.space2)
            if held {
                Text(checked ? "Put back" : "Got it")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Tokens.accent)
                    .padding(.horizontal, Tokens.space2)
                    .frame(height: Tokens.space5)
                    .background(Tokens.accentSoft, in: Capsule())
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            if let home = row.homeName {
                Text(home)
                    .font(.caption)
                    .foregroundStyle(Tokens.inkMuted)
                    .padding(.horizontal, Tokens.space2)
                    .frame(height: Tokens.space5)
                    .background(Tokens.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Tokens.line))
                    .help(Text("For \(home)"))
            }
            if !row.quantity.isEmpty {
                Text(row.quantity)
                    .font(Tokens.mono(.subheadline))
                    .foregroundStyle(checked ? Tokens.inkFaint : Tokens.inkMuted)
                    .frame(minWidth: Tokens.space7, alignment: .trailing)
            }
        }
        .frame(minHeight: ListView.rowHeight)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: checked)
        .animation(.easeOut(duration: Tokens.motionQuick), value: hovered)
        .animation(.easeOut(duration: Tokens.motionQuick), value: held)
        .onChange(of: checked) { _, now in
            guard now, !reduceMotion else { return }
            withAnimation(.spring(duration: Tokens.motionQuick)) { pop = true }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.easeOut(duration: 0.2)) { pop = false }
            }
        }
        .accessibilityElement(children: strike == nil ? .ignore : .contain)
        .accessibilityLabel(Text(checked ? "checked, \(row.name) \(row.detail)\(gotBy.map { ", got by \($0)" } ?? "")" : "\(isNew ? "new, " : "")\(row.name) \(row.detail)"))
        .accessibilityHint(held ? Text(checked ? "Tap again to put back" : "Tap again to strike") : Text(""))
    }

    private var symbol: some View {
        (checked ? Symbol.done : Symbol.open).image
            .font(.title3)
            .imageScale(.large)
            .foregroundStyle(symbolColour)
            .scaleEffect(pop ? 1.2 : 1)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
    }
}

#if os(macOS)
/// The Mac's keys over the list: space or delete strikes the selected row, return edits it,
/// letters start an entry. Kept apart so the compiler types the list's body in one breath.
private struct MacKeys: ViewModifier {
    var onToggle: () -> Bool
    var onEdit: () -> Bool
    var onType: (String) -> Bool

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space) { onToggle() ? .handled : .ignored }
            .onKeyPress(.return) { onEdit() ? .handled : .ignored }
            .onDeleteCommand { _ = onToggle() }
            .onKeyPress(characters: .alphanumerics, phases: .down) { (press: KeyPress) -> KeyPress.Result in
                onType(press.characters) ? .handled : .ignored
            }
    }
}

/// The pane hangs off the left at content-max.
private struct MacPane: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: Tokens.contentMax, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Tokens.space4)
            .background(Tokens.ground)
    }
}

/// The menu bar's commands land on the list in front, and the list says what the menu may offer.
private struct MacMenu: ViewModifier {
    @Environment(MacNav.self) private var nav
    var struck: Bool
    var selected: Bool
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onClear: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: nav.toggleSelected) { onToggle() }
            .onChange(of: nav.editSelected) { onEdit() }
            .onChange(of: nav.clear) { if struck { onClear() } }
            .onChange(of: selected, initial: true) { nav.hasSelectedEntry = selected }
            .onChange(of: struck, initial: true) { nav.hasStruck = struck }
    }
}
#endif

/// The phone's guard against a blind strike: a tap on a row in the first moment after the
/// list, or doma, came to the front is a pocket or a pickup and is ignored. How long is the
/// Settings choice, off or up to two seconds, half a second unless changed.
struct StrikeGuard: Equatable {
    static let key = "strike.guard"
    static let defaultSeconds = 0.5
    static let choices: [Double] = [0, 0.5, 1, 2]

    var since: Date
    var seconds: Double

    func allows(_ now: Date) -> Bool {
        seconds <= 0 || now.timeIntervalSince(since) >= seconds
    }

    static func title(_ seconds: Double) -> LocalizedStringKey {
        switch seconds {
        case 0: "Off"
        case 0.5: "Half a second"
        case 1: "1 second"
        default: "2 seconds"
        }
    }
}
