// A home: the staples with their flag as glyph and word, the age in mono once it passes half
// the staleness, three small buttons on a staple nobody has answered for; then every other item
// flagged here; then the spots' pictures in a strip; then the trips through this home. A staple
// is typed or said into the bar at the bottom, as an entry is on a list, with the same mic and
// the same split of a spoken line into the items it names; a swipe or a long-press on its row
// offers Rename and Remove; a spot comes from the + at the end of the strip, and its
// long-press offers the same two, as does the More menu on its own screen. Take photos walks
// the spots with the camera.
import SwiftUI

struct HomeView: View {
    var homeID: String
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var home: Live<HomeCard?>?
    @State private var rows: Live<[FlagRow]>?
    @State private var trips: Live<[TripRow]>?
    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var matches: [Match] = []
    @State private var proposals: Live<[ProposalRow]>?
    @State private var micTaps = 0
    @State private var voiceProblem: String?
    /// The staple whose row is a field now, and what it says.
    @State private var renaming: String?
    @State private var renameText = ""
    /// The field under the strip: a new spot, or the spot being renamed.
    @State private var spotField: SpotField?
    @State private var spotText = ""
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?
    @State private var sweeping = false
    @State private var spotShown: SpotRow?
    @FocusState private var fieldFocused: Bool
    @FocusState private var renameFocused: Bool
    @FocusState private var spotFocused: Bool

    private enum SpotField: Hashable {
        case new
        case rename(String)
    }

    private var staleness: Staleness { Staleness(days: session.current?.stalenessDays, now: RelativeText.now()) }

    var body: some View {
        let card = home?.value ?? nil
        let all = rows?.value ?? []
        let staples = all.filter(\.isStaple)
        let others = all.filter { !$0.isStaple }
        List {
            if let ps = proposals?.value, !ps.isEmpty {
                // what the pictures suggested, each answered in its row
                Section {
                    ForEach(ps) { p in
                        proposalRow(p)
                    }
                } header: {
                    SectionHeader("From the pictures")
                }
            }
            Section {
                ForEach(staples) { row in
                    if renaming == row.itemID {
                        renameRow(row)
                    } else {
                        stapleRow(row)
                    }
                }
                .onMove { from, to in
                    try? HomeActions.moveStaples(all, from: from, to: to, home: homeID, in: session)
                }
                #if os(macOS)
                if renaming == nil {
                    addRowMac
                    if let voiceProblem {
                        ProblemLine(text: voiceProblem)
                            .listRowBackground(Tokens.ground)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(matches.prefix(5)) { m in
                        matchButton(m)
                            .listRowBackground(Tokens.accentSoft)
                    }
                }
                #endif
            } header: {
                SectionHeader("Staples")
            } footer: {
                if staples.isEmpty {
                    Text("Staples are what this home should always have. Type one below; when one runs out, flag it and it goes on the list.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { row in
                        flagRow(row)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button("Make a staple") { try? HomeActions.addStaple(itemID: row.itemID, home: homeID, in: session) }
                                    .tint(Tokens.accent)
                            }
                    }
                } header: {
                    SectionHeader("Also here")
                }
            }
            if let card {
                Section {
                    spotStrip(card.spots)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    if spotField != nil {
                        spotFieldRow
                    }
                } header: {
                    SectionHeader("Spots")
                }
            }
            if let ts = trips?.value, !ts.isEmpty {
                Section {
                    ForEach(ts) { t in
                        TripHistoryRow(trip: t)
                            .listRowBackground(Tokens.ground)
                            .listRowSeparatorTint(Tokens.line)
                    }
                } header: {
                    SectionHeader("Trips")
                }
            }
        }
        .listStyle(.plain)
        .textCase(nil)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, ListView.rowHeight)
        .background(Tokens.ground)
        .navigationTitle(card?.name ?? "")
        .navigationSubtitle(subtitle(card))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // the bar steps aside while a row is a field, so one field is live
            if renaming == nil, spotField == nil {
                addBar
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
            if let card, !card.spots.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button {
                        sweeping = true
                    } label: {
                        Label("Take photos", systemImage: "camera")
                    }
                    .accessibilityIdentifier("take-photos")
                }
            }
        }
        .navigationDestination(isPresented: $sweeping) {
            if let card { SweepView(home: card) }
        }
        .navigationDestination(item: $spotShown) { spot in PhotoView(spot: spot) }
        // the mic taps back at once, then says when it listens and when it stops
        .sensoryFeedback(.impact(weight: .light), trigger: micTaps)
        .sensoryFeedback(trigger: session.dictation.busy) { _, now in now ? .start : .stop }
        .onChange(of: scenePhase) { _, now in
            if now == .background { stopDictation() }
        }
        .onDisappear { stopDictation() }
        .animation(Motion.of(reduceMotion, Motion.base), value: renaming)
        .animation(Motion.of(reduceMotion, Motion.base), value: spotField)
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
        .onChange(of: text) { _, t in
            guard !t.trimmingCharacters(in: .whitespaces).isEmpty, let scope = session.scope else { matches = []; return }
            matches = (try? session.store.read(scope) { db, s in try Queries.matches(db, s, prefix: t) }) ?? []
        }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        let staleness = self.staleness
        let id = homeID
        home = Live(session.store, initial: nil) { db in try Queries.homeCards(db, scope, staleness: staleness).first { $0.id == id } }
        rows = Live(session.store, initial: []) { db in try Queries.flagRows(db, scope, homeID: id, staleness: staleness) }
        trips = Live(session.store, initial: []) { db in try Queries.trips(db, scope, homeID: id) }
        proposals = Live(session.store, initial: []) { db in try Queries.proposals(db, scope, homeID: id, staleness: staleness) }
    }

    private func subtitle(_ card: HomeCard?) -> Text {
        guard let card, card.staples > 0 else { return Text("") }
        return card.missing == 0 ? Text("All there") : Text("\(card.missing) missing")
    }

    // MARK: Adding a staple

    #if os(iOS)
    /// The bar at the bottom, as on a list: the matches in the same glass above the field.
    private var addBar: some View {
        GlassEffectContainer(spacing: Tokens.space2) {
            VStack(spacing: Tokens.space2) {
                if !matches.isEmpty {
                    VStack(spacing: 0) {
                        // the best match nearest the bar, as on a list
                        ForEach(Array(matches.prefix(5).reversed())) { m in
                            matchButton(m)
                                .background(Tokens.surface)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusMD))
                    .glassEffect(.regular, in: .rect(cornerRadius: Tokens.radiusMD))
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
                    .frame(minHeight: Tokens.rowH)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal, Tokens.space4)
            .padding(.bottom, Tokens.space2)
        }
        .animation(Motion.of(reduceMotion, Motion.quick), value: matches.map(\.id))
        .animation(Motion.of(reduceMotion, Motion.quick), value: voiceProblem)
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
            TextField("Add a staple", text: $text, selection: $selection)
                .accessibilityIdentifier("new-staple")
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.return)
                .onSubmit(addTyped)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .overlay(alignment: .leading) { hearing }
            MicButton(listener: session.dictation, tap: toggleDictation, pick: dictate(in:))
        }
    }
    #else
    /// The Mac's add row, at the end of the staples as on a list.
    private var addRowMac: some View {
        HStack(spacing: Tokens.space3) {
            Image(systemName: "plus")
                .font(.title3)
                .imageScale(.large)
                .foregroundStyle(Tokens.accent)
                .frame(width: Tokens.space5)
                .accessibilityHidden(true)
            TextField("Add a staple", text: $text, selection: $selection)
                .accessibilityIdentifier("new-staple")
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(addTyped)
                .onExitCommand { fieldFocused = false; text = "" }
                .autocorrectionDisabled()
                .overlay(alignment: .leading) { hearing }
            MicButton(listener: session.dictation, tap: toggleDictation, pick: dictate(in:))
        }
        .frame(minHeight: Tokens.rowH)
        .listRowBackground(Tokens.ground)
        .listRowSeparator(.hidden)
    }
    #endif

    private func matchButton(_ m: Match) -> some View {
        Button {
            try? HomeActions.addStaple(itemID: m.itemID, home: homeID, in: session)
            text = ""
        } label: {
            Text(m.name)
                .foregroundStyle(Tokens.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.space4)
                .frame(minHeight: Tokens.rowH)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func addTyped() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        _ = try? HomeActions.addStaple(t, home: homeID, in: session)
        text = ""
        matches = []
    }

    // MARK: Saying a staple

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

    /// The mic's tap, as on a list: listen in the language last chosen, or stop. Each piece the
    /// model settles lands in the field as if typed, the matches answer it, and a pause adds
    /// it as return would. Stopping keeps the words in the field.
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

    /// The pause's add: the spoken line split into the staples it names, by the catalog's
    /// names and the separators said. What no rule splits is one staple.
    private func addSpoken() {
        guard let scope = session.scope else { return }
        let names = (try? session.store.read(scope) { db, s in try Queries.itemNames(db, s) }) ?? []
        let pieces = Spoken.split(text, language: Language.remembered, names: names)
        for piece in pieces {
            _ = try? HomeActions.addStaple(piece, home: homeID, in: session)
        }
        text = ""
        matches = []
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

    // MARK: Spots

    private func spotStrip(_ spots: [SpotRow]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Tokens.space3) {
                ForEach(spots) { spot in
                    spotTile(spot)
                }
                Button {
                    spotText = ""
                    spotField = .new
                } label: {
                    VStack(spacing: Tokens.space1) {
                        RoundedRectangle(cornerRadius: Tokens.radiusMD)
                            .strokeBorder(Tokens.line, style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .frame(width: Tokens.thumb, height: Tokens.thumb)
                            .overlay {
                                Image(systemName: "plus")
                                    .foregroundStyle(Tokens.accent)
                            }
                        Text("Add a spot")
                            .font(.caption)
                            .foregroundStyle(Tokens.inkMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: Tokens.thumb)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add a spot"))
                .accessibilityIdentifier("add-spot")
            }
            .padding(.horizontal, Tokens.space4)
            .padding(.vertical, Tokens.space2)
        }
        .scrollIndicators(.hidden)
    }

    /// A spot's picture and name; a long-press offers Rename and Remove, and Remove arms in
    /// the caption.
    private func spotTile(_ spot: SpotRow) -> some View {
        VStack(spacing: Tokens.space1) {
            Button {
                spotShown = spot
            } label: {
                SpotThumb(spot: spot, size: Tokens.thumb, named: arming != spot.id)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("spot-" + spot.name)
            .contextMenu {
                Button("Rename") {
                    spotText = spot.name
                    spotField = .rename(spot.id)
                }
                Button("Remove", role: .destructive) { arm(spot.id) }
            }
            if arming == spot.id {
                Button {
                    arming = nil
                    disarm?.cancel()
                    try? HomeActions.archiveSpot(spot.id, in: session)
                } label: {
                    Text("Really remove?")
                        .font(.caption)
                        .foregroundStyle(Tokens.onOut)
                        .padding(.horizontal, Tokens.space2)
                        .padding(.vertical, Tokens.space1)
                        .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                }
                .buttonStyle(.borderless)
            }
        }
        .animation(Motion.of(reduceMotion, Motion.quick), value: arming == spot.id)
    }

    /// The field under the strip: a new spot's name, or a spot's new name.
    private var spotFieldRow: some View {
        let placeholder: LocalizedStringKey = spotField == .new ? "New spot, like pantry or fridge" : "Name"
        return HStack(spacing: Tokens.space3) {
            TextField(placeholder, text: $spotText)
                .textFieldStyle(.plain)
                .focused($spotFocused)
                .submitLabel(.done)
                .onSubmit(commitSpot)
                .accessibilityIdentifier("new-spot")
                .onAppear { spotFocused = true }
            Button("Cancel") { spotField = nil }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
        }
        .frame(minHeight: Tokens.rowH)
        #if os(macOS)
        .onExitCommand { spotField = nil }
        #endif
        .listRowBackground(Tokens.surface)
    }

    private func commitSpot() {
        let t = spotText.trimmingCharacters(in: .whitespaces)
        let field = spotField
        spotField = nil
        spotText = ""
        guard !t.isEmpty else { return }
        switch field {
        case .new:
            _ = try? HomeActions.createSpot(named: t, home: homeID, in: session)
        case .rename(let id):
            try? HomeActions.renameSpot(id, to: t, in: session)
        case nil:
            break
        }
    }

    // MARK: Rows

    /// A staple: the flag row with Rename and Remove on a swipe; a long press drags it into
    /// place, as on a list. On the Mac the menu has both and a double click renames.
    private func stapleRow(_ row: FlagRow) -> some View {
        flagRow(row)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Remove", role: .destructive) { arm(row.itemID) }
                    .tint(Tokens.out)
                Button("Rename") { startRename(row) }
                    .tint(Tokens.accent)
            }
            #if os(macOS)
            .contextMenu {
                Button("Rename") { startRename(row) }
                Button("Remove", role: .destructive) { arm(row.itemID) }
            }
            .onTapGesture(count: 2) { startRename(row) }
            #endif
    }

    /// One proposal: the suggested flag, the item, the flag as it stands, Accept and Keep.
    private func proposalRow(_ p: ProposalRow) -> some View {
        HStack(spacing: Tokens.space3) {
            FlagMark(state: p.state)
                .frame(minWidth: Tokens.space7, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.name)
                    .foregroundStyle(Tokens.ink)
                HStack(spacing: Tokens.space1) {
                    Text("now")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                    FlagMark(state: p.current)
                        .font(.footnote)
                }
            }
            Spacer(minLength: Tokens.space2)
            Button("Accept") { try? HomeActions.accept(p, home: homeID, in: session) }
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.accent)
                .accessibilityIdentifier("accept-" + p.name)
            Button("Keep") { try? HomeActions.decline(p, home: homeID, in: session) }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .foregroundStyle(Tokens.inkMuted)
                .accessibilityIdentifier("keep-" + p.name)
        }
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("proposal-" + p.name)
    }

    private func startRename(_ row: FlagRow) {
        renameText = row.name
        renaming = row.itemID
    }

    /// Rename, in the row: the item's name, which is its name on every list and at every home.
    private func renameRow(_ row: FlagRow) -> some View {
        HStack(spacing: Tokens.space3) {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .submitLabel(.done)
                .onSubmit {
                    try? HomeActions.renameItem(row.itemID, to: renameText, in: session)
                    renaming = nil
                }
                .accessibilityIdentifier("rename-staple")
                .onAppear { renameFocused = true }
            #if os(iOS)
            Button("Cancel") { renaming = nil }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
            #endif
        }
        .frame(minHeight: ListView.rowHeight)
        #if os(macOS)
        .onExitCommand { renaming = nil }
        #endif
        .listRowBackground(Tokens.surface)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
    }

    @ViewBuilder
    private func flagRow(_ row: FlagRow) -> some View {
        HStack(spacing: Tokens.space3) {
            Text(row.name)
                .foregroundStyle(Tokens.ink)
            Spacer(minLength: Tokens.space2)
            if arming == row.itemID {
                Button {
                    arming = nil
                    disarm?.cancel()
                    try? HomeActions.removeStaple(itemID: row.itemID, home: homeID, in: session)
                } label: {
                    Text("Really remove?")
                        .font(.footnote)
                        .foregroundStyle(Tokens.onOut)
                        .padding(.horizontal, Tokens.space2)
                        .padding(.vertical, Tokens.space1)
                        .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                }
                .buttonStyle(.borderless)
            } else if row.state == .unknown, row.isStaple {
                // nobody has said: the three answers in the row
                HStack(spacing: Tokens.space1) {
                    ForEach(FlagState.settable, id: \.self) { s in
                        Button {
                            try? HomeActions.setFlag(s, home: homeID, item: row.itemID, in: session)
                        } label: {
                            FlagMark(state: s, word: false)
                                .padding(.horizontal, Tokens.space2)
                                .padding(.vertical, Tokens.space1)
                                .background(Tokens.surfaceSunk, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(s.word))
                        .accessibilityIdentifier("flag-\(s.rawValue)-" + row.name)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Still there?"))
            } else {
                Menu {
                    ForEach(FlagState.settable, id: \.self) { s in
                        Button {
                            try? HomeActions.setFlag(s, home: homeID, item: row.itemID, in: session)
                        } label: {
                            Label { Text(s.word) } icon: { s.symbol.image }
                        }
                    }
                } label: {
                    HStack(spacing: Tokens.space2) {
                        if row.ageShown, let at = row.setAt {
                            RelativeText(millis: at)
                        }
                        FlagMark(state: row.state)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityIdentifier("flag-" + row.name)
            }
        }
        .frame(minHeight: ListView.rowHeight)
        .contentShape(Rectangle())
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        .animation(Motion.of(reduceMotion, Motion.quick), value: arming == row.itemID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility(row))
    }

    private func accessibility(_ row: FlagRow) -> Text {
        if row.ageShown, let at = row.setAt {
            return Text("\(Text(row.state.word)), \(row.name), \(RelativeText.string(for: Date(timeIntervalSince1970: Double(at) / 1000), locale: Locale.current))")
        }
        return Text("\(Text(row.state.word)), \(row.name)")
    }

    private func arm(_ id: String) {
        arming = id
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, arming == id { arming = nil }
        }
    }
}

/// A flag as glyph and word in its colour; never colour alone.
struct FlagMark: View {
    var state: FlagState
    var word = true

    var body: some View {
        HStack(spacing: Tokens.space1) {
            state.symbol.image
                .imageScale(.small)
            if word {
                Text(state.word)
                    .font(.subheadline)
            }
        }
        .foregroundStyle(state.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(state.word))
    }
}

/// One trip that is over: from and to, when it arrived or was cancelled, and what moved.
struct TripHistoryRow: View {
    var trip: TripRow
    @Environment(Session.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space1) {
            HStack {
                Text(verbatim: trip.fromName + " → " + trip.toName)
                    .foregroundStyle(Tokens.ink)
                Spacer()
                if trip.cancelledAt != nil {
                    Text("cancelled")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                } else {
                    RelativeText(millis: trip.arrivedAt ?? trip.date)
                }
            }
            if !trip.moved.isEmpty {
                Text(trip.moved.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
        }
        .padding(.vertical, Tokens.space1)
        .accessibilityElement(children: .combine)
    }
}
