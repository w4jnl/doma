// Trip: from and to in one row with the swap between them, a date, then Bring, Buy and Check on
// arrival; each bring row has a checkbox for packing, each buy row Add to list, and Arrived at
// the bottom commits one trip.arrived with what was packed. The packing is this device's until
// Arrived; the event is the record.
import SwiftUI

struct TripView: View {
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var homes: Live<[HomeRow]>?
    @State private var plan: Live<TripPlan>?
    @State private var from: String?
    @State private var to: String?
    @State private var date = RelativeText.now()
    @State private var packed: Set<String> = []
    @State private var arrived = 0

    private var staleness: Staleness { Staleness(days: session.current?.stalenessDays, now: RelativeText.now()) }
    private var key: String { "trip." + (session.currentRef?.key ?? "") }

    var body: some View {
        let all = homes?.value ?? []
        let p = plan?.value ?? TripPlan()
        List {
            if all.count < 2 {
                Section {
                    HelpLine(text: "A trip goes from one home to another. Add a second home under Homes and this tab says what to bring and what to buy.")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Tokens.space4)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    pickers(all)
                        .listRowBackground(ListsView.rowGround)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .listRowBackground(ListsView.rowGround)
                }
                if p.isEmpty {
                    Section {
                        HelpLine(text: "Nothing to bring or buy, as far as the flags say.")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Tokens.space4)
                            .listRowBackground(Color.clear)
                    }
                }
                bringSection(p, all)
                buySection(p, all)
                checkSection(p, all)
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
        .navigationTitle("Trip")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            HouseholdTitle()
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if all.count >= 2 { arrivedButton }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
        .onChange(of: homes?.value) { _, now in settle(now ?? []) }
        .onChange(of: from) { replan() }
        .onChange(of: to) { replan() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
        settle(homes?.value ?? [])
        replan()
    }

    /// The remembered homes when they still exist, else the first two.
    private func settle(_ all: [HomeRow]) {
        guard all.count >= 2 else { return }
        let ids = all.map(\.id)
        if let f = from, ids.contains(f), let t = to, ids.contains(t), f != t { return }
        let rf = UserDefaults.standard.string(forKey: key + ".from"), rt = UserDefaults.standard.string(forKey: key + ".to")
        if let rf, let rt, ids.contains(rf), ids.contains(rt), rf != rt {
            from = rf
            to = rt
        } else {
            from = ids[0]
            to = ids[1]
        }
    }

    private func replan() {
        guard let scope = session.scope, let f = from, let t = to, f != t else { plan = nil; return }
        UserDefaults.standard.set(f, forKey: key + ".from")
        UserDefaults.standard.set(t, forKey: key + ".to")
        packed = []
        let staleness = self.staleness
        plan = Live(session.store, initial: TripPlan()) { db in
            let fromFlags = try Queries.flagRows(db, scope, homeID: f, staleness: staleness)
            let toFlags = try Queries.flagRows(db, scope, homeID: t, staleness: staleness)
            let listed = try Queries.openForHome(db, scope, homeID: t)
            return TripPlan.derive(from: f, to: t, flags: fromFlags, toFlags: toFlags, listed: listed)
        }
    }

    private func name(_ id: String?, _ all: [HomeRow]) -> String {
        all.first { $0.id == id }?.name ?? ""
    }

    // MARK: Groups

    @ViewBuilder
    private func bringSection(_ p: TripPlan, _ all: [HomeRow]) -> some View {
        if !p.bring.isEmpty {
            Section {
                ForEach(p.bring) { item in bringRow(item) }
            } header: {
                SectionHeader("Bring")
            } footer: {
                Text("At \(name(from, all)) and wanted at \(name(to, all)). Tick what you pack.")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func buySection(_ p: TripPlan, _ all: [HomeRow]) -> some View {
        if !p.buy.isEmpty {
            Section {
                ForEach(p.buy) { item in buyRow(item) }
            } header: {
                HStack {
                    SectionHeader("Buy")
                    Spacer()
                    if p.buy.contains(where: { !$0.onList }) {
                        Button("Add all", action: addAll)
                            .font(.subheadline)
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.accent)
                            .padding(.top, Tokens.space4)
                            .padding(.bottom, Tokens.space1)
                    }
                }
            } footer: {
                Text("Wanted at \(name(to, all)) and not at \(name(from, all)).")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func checkSection(_ p: TripPlan, _ all: [HomeRow]) -> some View {
        if !p.check.isEmpty {
            Section {
                ForEach(p.check) { item in checkRow(item) }
            } header: {
                SectionHeader("Check on arrival")
            } footer: {
                Text("Staples of \(name(to, all)) nobody has flagged lately.")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
        }
    }

    private func checkRow(_ item: TripItem) -> some View {
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

    private func addAll() {
        guard let to, let p = plan?.value else { return }
        for item in p.buy where !item.onList {
            try? TripActions.addToList(item.itemID, forHome: to, in: session)
        }
    }

    // MARK: Pickers

    private func pickers(_ all: [HomeRow]) -> some View {
        HStack(spacing: Tokens.space2) {
            homeMenu("From", selection: $from, all)
            Button {
                swap(&from, &to)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Tokens.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Swap from and to"))
            homeMenu("To", selection: $to, all)
        }
        .rowHeight()
    }

    private func homeMenu(_ title: LocalizedStringKey, selection: Binding<String?>, _ all: [HomeRow]) -> some View {
        Menu {
            ForEach(all) { h in
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
                    Text(name(selection.wrappedValue, all))
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
        .accessibilityLabel(Text("\(Text(title)), \(name(selection.wrappedValue, all))"))
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

    private func buyRow(_ item: TripItem) -> some View {
        HStack(spacing: Tokens.space3) {
            Text(item.name)
                .foregroundStyle(Tokens.ink)
            Spacer()
            if item.onList {
                Text("on the list")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            } else if let to {
                Button("Add to list") {
                    try? TripActions.addToList(item.itemID, forHome: to, in: session)
                }
                .font(.subheadline)
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.accent)
                .accessibilityIdentifier("buy-" + item.name)
            }
        }
        .rowHeight()
        .listRowBackground(ListsView.rowGround)
        .listRowSeparatorTint(Tokens.line)
    }

    /// The one primary button, enabled only while something is packed.
    private var arrivedButton: some View {
        let label: Text = packed.isEmpty ? Text("Arrived") : Text("Arrived with \(packed.count)")
        // drawn by hand, not the system's prominent style: its disabled look is not the same
        // from one render to the next, and the pictures compare
        return Button(action: arrive) {
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

    private func arrive() {
        guard let from, let to else { return }
        if (try? TripActions.arrive(from: from, to: to, packed: Array(packed).sorted(), in: session)) != nil {
            packed = []
            arrived += 1
        }
    }
}
