// Trip: the household's trips, upcoming by date and then the past ones, and one trip opened:
// from and to in one row with the swap between them, the date and the list it shops on, then
// Bring, Buy and Check on arrival; each bring row has a checkbox for packing, each buy row Add
// to list (a long-press offers the other lists), and Arrived at the bottom commits one
// trip.arrived with what was packed. The plan is shared through the log; the packing is this
// device's until Arrived.
import SwiftUI

/// The trips screen: what the list rows need, read in one go so the counts agree with the rows.
struct TripsScreen: Hashable, Sendable {
    var trips: [TripRow] = []
    /// Per open trip that carries its to-home's needs: how many to bring and to buy.
    var counts: [String: (bring: Int, buy: Int)] = [:]

    static func == (a: TripsScreen, b: TripsScreen) -> Bool { a.trips == b.trips && a.counts.mapValues { [$0.bring, $0.buy] } == b.counts.mapValues { [$0.bring, $0.buy] } }
    func hash(into h: inout Hasher) { h.combine(trips) }
}

struct TripsView: View {
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var screen: Live<TripsScreen>?
    @State private var homes: Live<[HomeRow]>?
    @State private var lists: Live<[ListSummary]>?
    @State private var planning = false
    @State private var newFrom: String?
    @State private var newTo: String?
    @State private var newDate = RelativeText.now()
    @State private var newList: String?
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?

    private var staleness: Staleness { Staleness(days: session.current?.stalenessDays, now: RelativeText.now()) }

    var body: some View {
        let all = homes?.value ?? []
        let trips = screen?.value.trips ?? []
        let open = trips.filter(\.isOpen)
        let past = trips.filter { !$0.isOpen }
        List {
            if all.count < 2 {
                Section {
                    HelpLine(text: "A trip goes from one home to another. Add a second home under Homes and this tab says what to bring and what to buy.")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Tokens.space4)
                        .listRowBackground(Color.clear)
                }
            } else {
                if planning {
                    Section {
                        TripPlanFields(from: $newFrom, to: $newTo, date: $newDate, list: $newList, homes: all, lists: lists?.value ?? [])
                    } header: {
                        SectionHeader("New trip")
                    }
                    .listRowBackground(ListsView.rowGround)
                    .transition(Motion.arrive(reduceMotion, from: .top))
                }
                Section {
                    ForEach(open) { trip in
                        row(trip)
                    }
                } header: {
                    SectionHeader("Upcoming")
                } footer: {
                    if open.isEmpty {
                        Text("No trip planned yet. Tap + to plan one: where from, where to, when, and which list to shop on.")
                            .font(.footnote)
                            .foregroundStyle(Tokens.inkMuted)
                    }
                }
                if !past.isEmpty {
                    Section {
                        ForEach(past) { trip in
                            TripHistoryRow(trip: trip)
                                .listRowBackground(ListsView.rowGround)
                                .listRowSeparatorTint(Tokens.line)
                        }
                    } header: {
                        SectionHeader("History")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
        .animation(Motion.of(reduceMotion, Motion.base), value: planning)
        .textCase(nil)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle("Trip")
        .navigationDestination(for: String.self) { id in TripView(tripID: id) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            HouseholdTitle()
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
            if planning {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { planning = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Plan", action: plan)
                        .disabled(newFrom == nil || newTo == nil || newFrom == newTo)
                        .accessibilityIdentifier("plan")
                }
            } else if all.count >= 2 {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startPlanning(all)
                    } label: {
                        Label("Plan a trip", systemImage: "plus")
                    }
                    .accessibilityIdentifier("plan-trip")
                }
            }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        let staleness = self.staleness
        homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
        lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope).filter { !$0.isPersonal } }
        screen = Live(session.store, initial: TripsScreen()) { db in
            var out = TripsScreen(trips: try Queries.trips(db, scope))
            for trip in out.trips where TripPlan.carries(trip, among: out.trips) {
                let p = try TripActions.plan(db, scope, from: trip.fromHomeID, to: trip.toHomeID, staleness: staleness)
                out.counts[trip.id] = (p.bring.count, p.buy.count)
            }
            return out
        }
    }

    private func startPlanning(_ all: [HomeRow]) {
        let last = screen?.value.trips.first
        newFrom = last?.fromHomeID ?? all[0].id
        newTo = last?.toHomeID ?? all[1].id
        newDate = RelativeText.now()
        newList = lists?.value.first { $0.isDefault }?.id
        planning = true
    }

    private func plan() {
        guard let from = newFrom, let to = newTo else { return }
        _ = try? TripActions.plan(from: from, to: to, date: newDate, list: newList, in: session)
        planning = false
    }

    @ViewBuilder
    private func row(_ trip: TripRow) -> some View {
        let counts = screen?.value.counts[trip.id]
        NavigationLink(value: trip.id) {
            VStack(alignment: .leading, spacing: Tokens.space1) {
                HStack {
                    Text(verbatim: trip.fromName + " → " + trip.toName)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    if arming == trip.id {
                        Button {
                            arming = nil
                            disarm?.cancel()
                            try? TripActions.cancel(trip.id, in: session)
                        } label: {
                            Text("Really cancel?")
                                .font(.footnote)
                                .foregroundStyle(Tokens.onOut)
                                .padding(.horizontal, Tokens.space2)
                                .padding(.vertical, Tokens.space1)
                                .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Text(Date(timeIntervalSince1970: Double(trip.date) / 1000), format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(Tokens.mono(.footnote))
                            .foregroundStyle(Tokens.inkMuted)
                    }
                }
                Text(summary(counts, trip))
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
            .padding(.vertical, Tokens.space1)
        }
        .listRowBackground(ListsView.rowGround)
        .listRowSeparatorTint(Tokens.line)
        .accessibilityIdentifier("trip-" + trip.fromName + "-" + trip.toName)
        .contextMenu {
            Button("Cancel trip") { arm(trip.id) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Cancel trip") { arm(trip.id) }
        }
    }

    private func summary(_ counts: (bring: Int, buy: Int)?, _ trip: TripRow) -> String {
        guard let counts else { return String(localized: "Another trip to \(trip.toName) comes first; what it misses shows there.") }
        if counts.bring == 0, counts.buy == 0 { return String(localized: "Nothing to bring or buy, as far as the flags say.") }
        return [counts.bring > 0 ? String(localized: "\(counts.bring) to bring") : nil, counts.buy > 0 ? String(localized: "\(counts.buy) to buy") : nil].compactMap { $0 }.joined(separator: ", ")
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

/// From and to in one row with the swap between them, the date and the list; the plan's fields,
/// for a new trip and for one opened.
struct TripPlanFields: View {
    @Binding var from: String?
    @Binding var to: String?
    @Binding var date: Date
    @Binding var list: String?
    var homes: [HomeRow]
    var lists: [ListSummary]

    var body: some View {
        HStack(spacing: Tokens.space2) {
            homeMenu("From", selection: $from)
            Button {
                swap(&from, &to)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Tokens.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Swap from and to"))
            homeMenu("To", selection: $to)
        }
        .rowHeight()
        DatePicker("Date", selection: $date, displayedComponents: .date)
        Menu {
            ForEach(lists) { l in
                Button {
                    list = l.id
                } label: {
                    if l.id == list {
                        Label(l.name, systemImage: "checkmark")
                    } else {
                        Text(l.name)
                    }
                }
            }
        } label: {
            HStack {
                Text("List")
                    .foregroundStyle(Tokens.ink)
                Spacer()
                HStack(spacing: Tokens.space1) {
                    ListDot(colour: lists.first { $0.id == list }?.colour ?? "")
                    Text(lists.first { $0.id == list }?.name ?? "")
                        .foregroundStyle(Tokens.inkMuted)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Tokens.inkMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .rowHeight()
        .accessibilityLabel(Text("List, \(lists.first { $0.id == list }?.name ?? "")"))
    }

    private func name(_ id: String?) -> String { homes.first { $0.id == id }?.name ?? "" }

    private func homeMenu(_ title: LocalizedStringKey, selection: Binding<String?>) -> some View {
        Menu {
            ForEach(homes) { h in
                Button {
                    if h.id == (selection.wrappedValue == from ? to : from) { swap(&from, &to) } else { selection.wrappedValue = h.id }
                } label: {
                    if h.id == selection.wrappedValue {
                        Label(h.name, systemImage: "checkmark")
                    } else {
                        Text(h.name)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Tokens.inkMuted)
                HStack(spacing: Tokens.space1) {
                    Text(name(selection.wrappedValue))
                        .foregroundStyle(Tokens.ink)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Tokens.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(Text(title)), \(name(selection.wrappedValue))"))
    }
}

/// One trip opened: its plan to change, then Bring, Buy and Check on arrival, and Arrived.
struct TripView: View {
    var tripID: String
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: Live<(trip: TripRow?, plan: TripPlan, carries: Bool)>?
    @State private var homes: Live<[HomeRow]>?
    @State private var lists: Live<[ListSummary]>?
    @State private var from: String?
    @State private var to: String?
    @State private var date = RelativeText.now()
    @State private var list: String?
    @State private var packed: Set<String> = []
    @State private var arrived = 0
    @State private var loaded = false

    private var staleness: Staleness { Staleness(days: session.current?.stalenessDays, now: RelativeText.now()) }

    var body: some View {
        let trip = state?.value.trip
        let p = state?.value.plan ?? TripPlan()
        let carries = state?.value.carries ?? true
        let all = homes?.value ?? []
        List {
            if let trip, trip.isOpen {
                Section {
                    TripPlanFields(from: $from, to: $to, date: $date, list: $list, homes: all, lists: lists?.value ?? [])
                }
                .listRowBackground(ListsView.rowGround)
            } else if let trip {
                Section {
                    TripHistoryRow(trip: trip)
                        .listRowBackground(ListsView.rowGround)
                }
            }
            if let trip, trip.isOpen {
                if !carries {
                    Section {
                        HelpLine(text: "Another trip to \(trip.toName) comes first; what it misses shows there.")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Tokens.space4)
                            .listRowBackground(Color.clear)
                    }
                } else if p.isEmpty {
                    Section {
                        HelpLine(text: "Nothing to bring or buy, as far as the flags say.")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Tokens.space4)
                            .listRowBackground(Color.clear)
                    }
                }
                bringSection(p, trip)
                buySection(p, trip)
                checkSection(p, trip)
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
        .navigationTitle(trip.map { Text(verbatim: $0.fromName + " → " + $0.toName) } ?? Text("Trip"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let trip, trip.isOpen, carries { arrivedButton(trip) }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
        .onChange(of: state?.value.trip) { _, now in take(now) }
        .onChange(of: from) { replan() }
        .onChange(of: to) { replan() }
        .onChange(of: date) { replan() }
        .onChange(of: list) { replan() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        let staleness = self.staleness
        let id = tripID
        homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
        lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope).filter { !$0.isPersonal } }
        state = Live(session.store, initial: (nil, TripPlan(), true)) { db in
            let trips = try Queries.trips(db, scope)
            guard let trip = trips.first(where: { $0.id == id }) else { return (nil, TripPlan(), true) }
            let carries = TripPlan.carries(trip, among: trips)
            let plan = carries ? try TripActions.plan(db, scope, from: trip.fromHomeID, to: trip.toHomeID, staleness: staleness) : TripPlan()
            return (trip, plan, carries)
        }
        take(state?.value.trip)
    }

    /// The plan's fields from the row, when the row changes under the screen.
    private func take(_ trip: TripRow?) {
        guard let trip else { return }
        loaded = false
        from = trip.fromHomeID
        to = trip.toHomeID
        date = Date(timeIntervalSince1970: Double(trip.date) / 1000)
        list = trip.listID
        loaded = true
    }

    /// A change to a field is a new plan for the same trip.
    private func replan() {
        guard loaded, let trip = state?.value.trip, let from, let to, from != to else { return }
        let changed = from != trip.fromHomeID || to != trip.toHomeID || list != trip.listID || millis(Calendar.current.startOfDay(for: date)) != trip.date
        guard changed else { return }
        packed = []
        _ = try? TripActions.plan(id: trip.id, from: from, to: to, date: date, list: list, in: session)
    }

    // MARK: Groups

    @ViewBuilder
    private func bringSection(_ p: TripPlan, _ trip: TripRow) -> some View {
        if !p.bring.isEmpty {
            Section {
                ForEach(p.bring) { item in bringRow(item) }
            } header: {
                SectionHeader("Bring")
            } footer: {
                Text("At \(trip.fromName) and wanted at \(trip.toName). Tick what you pack.")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func buySection(_ p: TripPlan, _ trip: TripRow) -> some View {
        if !p.buy.isEmpty {
            Section {
                ForEach(p.buy) { item in buyRow(item, trip) }
            } header: {
                HStack {
                    SectionHeader("Buy")
                    Spacer()
                    if p.buy.contains(where: { !$0.onList }) {
                        Button("Add all") { addAll(p, trip) }
                            .font(.subheadline)
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.accent)
                            .padding(.top, Tokens.space4)
                            .padding(.bottom, Tokens.space1)
                    }
                }
            } footer: {
                Text("Wanted at \(trip.toName) and not at \(trip.fromName).")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func checkSection(_ p: TripPlan, _ trip: TripRow) -> some View {
        if !p.check.isEmpty {
            Section {
                ForEach(p.check) { item in
                    HStack {
                        Text(item.name)
                            .foregroundStyle(Tokens.ink)
                        Spacer()
                        FlagMark(state: .unknown)
                    }
                    .rowHeight()
                    .listRowBackground(ListsView.rowGround)
                    .listRowSeparatorTint(Tokens.line)
                }
            } header: {
                SectionHeader("Check on arrival")
            } footer: {
                Text("Staples of \(trip.toName) nobody has flagged lately.")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
        }
    }

    private func addAll(_ p: TripPlan, _ trip: TripRow) {
        for item in p.buy where !item.onList {
            try? TripActions.addToList(item.itemID, forHome: trip.toHomeID, list: trip.listID, in: session)
        }
    }

    // MARK: Rows

    private func bringRow(_ item: TripItem) -> some View {
        let on = packed.contains(item.itemID)
        return Button {
            if on { packed.remove(item.itemID) } else { packed.insert(item.itemID) }
        } label: {
            HStack(spacing: Tokens.space3) {
                (on ? Symbol.done : Symbol.open).image
                    .foregroundStyle(on ? Tokens.accent : Tokens.inkMuted)
                    .frame(width: Tokens.space5)
                Text(item.name)
                    .foregroundStyle(Tokens.ink)
                Spacer()
                FlagMark(state: item.toState)
            }
            .rowHeight()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(ListsView.rowGround)
        .listRowSeparatorTint(Tokens.line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(on ? Text("packed, \(item.name)") : Text(item.name))
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier("bring-" + item.name)
        .sensoryFeedback(.selection, trigger: on)
    }

    private func buyRow(_ item: TripItem, _ trip: TripRow) -> some View {
        HStack(spacing: Tokens.space3) {
            Text(item.name)
                .foregroundStyle(Tokens.ink)
            Spacer()
            if item.onList {
                // names the list: the trip's, or another shared one that already has it
                Text("on \(item.listName ?? "")")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            } else {
                // a tap adds to the trip's list; a long-press offers the other lists
                Menu {
                    ForEach(lists?.value ?? []) { l in
                        Button(l.name) { try? TripActions.addToList(item.itemID, forHome: trip.toHomeID, list: l.id, in: session) }
                    }
                } label: {
                    Text("Add to list")
                        .font(.subheadline)
                        .foregroundStyle(Tokens.accent)
                } primaryAction: {
                    try? TripActions.addToList(item.itemID, forHome: trip.toHomeID, list: trip.listID, in: session)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityIdentifier("buy-" + item.name)
            }
        }
        .rowHeight()
        .listRowBackground(ListsView.rowGround)
        .listRowSeparatorTint(Tokens.line)
    }

    /// The one primary button, enabled only while something is packed; drawn by hand, since
    /// the system's prominent style does not look the same from one render to the next.
    private func arrivedButton(_ trip: TripRow) -> some View {
        let label: Text = packed.isEmpty ? Text("Arrived") : Text("Arrived with \(packed.count)")
        return Button {
            if (try? TripActions.arrive(trip, packed: Array(packed).sorted(), in: session)) != nil {
                packed = []
                arrived += 1
                dismiss()
            }
        } label: {
            label
                .font(.headline)
                .foregroundStyle(packed.isEmpty ? Tokens.inkMuted : Tokens.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.space3)
                .background(packed.isEmpty ? Tokens.surfaceSunk : Tokens.accent, in: RoundedRectangle(cornerRadius: Tokens.radiusMD))
        }
        .buttonStyle(.plain)
        .disabled(packed.isEmpty)
        .padding(.horizontal, Tokens.space4)
        .padding(.vertical, Tokens.space2)
        .accessibilityIdentifier("arrived")
        .sensoryFeedback(.success, trigger: arrived)
    }
}
