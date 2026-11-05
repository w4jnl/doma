// A home: its spots' pictures in a strip, then the staples with their flag as glyph and word,
// the age in mono once it passes half the staleness, three small buttons on a staple nobody
// has answered for, then every other item flagged here, then the trips through this home.
// Take photos walks the spots with the camera; Edit shows Remove on staples and spots and one
// field to add a staple or a spot.
import SwiftUI

struct HomeView: View {
    var homeID: String
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var home: Live<HomeCard?>?
    @State private var rows: Live<[FlagRow]>?
    @State private var trips: Live<[TripRow]>?
    @State private var editing = false
    /// What the one field adds while editing: a staple or a spot.
    @State private var addingSpot = false
    @State private var text = ""
    @State private var matches: [Match] = []
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?
    @State private var sweeping = false
    @State private var spotShown: SpotRow?
    @FocusState private var fieldFocused: Bool

    private var staleness: Staleness { Staleness(days: session.current?.stalenessDays, now: RelativeText.now()) }

    var body: some View {
        let card = home?.value ?? nil
        let all = rows?.value ?? []
        let staples = all.filter(\.isStaple)
        let others = all.filter { !$0.isStaple }
        List {
            if let card, !card.spots.isEmpty || editing {
                Section {
                    spotStrip(card.spots)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if editing {
                Section {
                    addField
                    ForEach(matches.prefix(5)) { m in
                        Button {
                            try? HomeActions.addStaple(itemID: m.itemID, home: homeID, in: session)
                            text = ""
                        } label: {
                            Text(m.name)
                                .foregroundStyle(Tokens.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .rowHeight()
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.accentSoft)
                    }
                } header: {
                    Picker("Add", selection: $addingSpot) {
                        Text("Staple").tag(false)
                        Text("Spot").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.top, Tokens.space3)
                }
                .listRowBackground(ListsView.rowGround)
            }
            Section {
                ForEach(staples) { row in
                    flagRow(row)
                        .removable(editing, title: "Remove") { arm(row.itemID) }
                }
            } header: {
                SectionHeader("Staples")
            } footer: {
                if staples.isEmpty {
                    Text("Staples are what this home should always have. Tap Edit to add them; when one runs out, flag it and it goes on the list.")
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
            if let ts = trips?.value, !ts.isEmpty {
                Section {
                    ForEach(ts) { t in
                        TripHistoryRow(trip: t)
                            .listRowBackground(ListsView.rowGround)
                            .listRowSeparatorTint(Tokens.line)
                    }
                } header: {
                    SectionHeader("Trips")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
        .textCase(nil)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle(card?.name ?? "")
        .navigationSubtitle(subtitle(card))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
            ToolbarItem(placement: .primaryAction) {
                Button(editing ? "Done" : "Edit") {
                    editing.toggle()
                    if !editing { text = ""; matches = [] }
                }
                .accessibilityIdentifier("edit-home")
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
        .animation(Motion.of(reduceMotion, Motion.base), value: editing)
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
        .onChange(of: text) { _, t in
            guard !addingSpot, !t.trimmingCharacters(in: .whitespaces).isEmpty, let scope = session.scope else { matches = []; return }
            matches = (try? session.store.read(scope) { db, s in try Queries.matches(db, s, prefix: t) }) ?? []
        }
        .onChange(of: addingSpot) { text = ""; matches = [] }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        let staleness = self.staleness
        let id = homeID
        home = Live(session.store, initial: nil) { db in try Queries.homeCards(db, scope, staleness: staleness).first { $0.id == id } }
        rows = Live(session.store, initial: []) { db in try Queries.flagRows(db, scope, homeID: id, staleness: staleness) }
        trips = Live(session.store, initial: []) { db in try Queries.trips(db, scope, homeID: id) }
    }

    private func subtitle(_ card: HomeCard?) -> Text {
        guard let card, card.staples > 0 else { return Text("") }
        return card.missing == 0 ? Text("All there") : Text("\(card.missing) missing")
    }

    // MARK: Spots

    private func spotStrip(_ spots: [SpotRow]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Tokens.space3) {
                ForEach(spots) { spot in
                    Button {
                        spotShown = spot
                    } label: {
                        SpotThumb(spot: spot, size: Tokens.thumb)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("spot-" + spot.name)
                    .contextMenu {
                        if editing {
                            Button("Remove", role: .destructive) { try? HomeActions.archiveSpot(spot.id, in: session) }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.space4)
            .padding(.vertical, Tokens.space2)
        }
        .scrollIndicators(.hidden)
    }

    private var addField: some View {
        TextField(addingSpot ? "New spot, like pantry or fridge" : "Add a staple", text: $text)
            .focused($fieldFocused)
            .submitLabel(.done)
            .onSubmit(addTyped)
            .accessibilityIdentifier(addingSpot ? "new-spot" : "new-staple")
            .onAppear { fieldFocused = true }
    }

    private func addTyped() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if addingSpot {
            _ = try? HomeActions.createSpot(named: t, home: homeID, in: session)
        } else {
            _ = try? HomeActions.addStaple(t, home: homeID, in: session)
        }
        text = ""
        matches = []
    }

    // MARK: Rows

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
        .rowHeight()
        .listRowBackground(ListsView.rowGround)
        .listRowSeparatorTint(Tokens.line)
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

    private func arm(_ itemID: String) {
        arming = itemID
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, arming == itemID { arming = nil }
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

/// One past trip: from and to, when, and what moved.
struct TripHistoryRow: View {
    var trip: TripRow
    @Environment(Session.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space1) {
            HStack {
                Text(verbatim: trip.fromName + " → " + trip.toName)
                    .foregroundStyle(Tokens.ink)
                Spacer()
                RelativeText(millis: trip.date)
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
