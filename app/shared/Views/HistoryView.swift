// History (docs/design.md, "History and quantities"): what the household bought, one month
// at a time, stepped back and forth under the title, the latest month with a purchase first.
// Per item with how many times, the totals
// of quantity by unit and when last; per home; who shopped. It reads the cleared entries and
// makes no event, so it is the same on every phone and on the Mac.
// It is also where the family tidies its items: a swipe on an item row (the row's menu on the
// Mac) offers Rename and Merge into, which fix the past months too, since every month reads the
// item's current name and a merged item reads through to the one it was merged into, and
// Retire, armed in place, which stops an item coming up while typing and leaves its months as
// they are.
import SwiftUI

/// The route the Lists overview pushes.
struct HistoryRoute: Hashable {}

struct HistoryView: View {
    @Environment(Session.self) private var session
    @State private var months: Live<[PurchaseMonth]>?
    @State private var overview: Live<MonthOverview>?
    /// The month stepped to; until then the screen shows the latest month with a purchase,
    /// this one when there is none, so the first days of a month do not open on nothing.
    @State private var picked: String?
    /// The item being renamed in its row, and the name as typed.
    @State private var renaming: String?
    @State private var renameText = ""
    /// The item being merged into another: its row becomes a field, and the catalog's matches
    /// for what is typed follow under it, each armed in place.
    @State private var merging: String?
    @State private var mergeText = ""
    @State private var candidates: [Match] = []
    @FocusState private var fieldFocused: Bool
    /// The item whose Retire is armed in its row, and the task that disarms it.
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?

    private var month: String {
        picked ?? months?.value.first?.month ?? Self.month(of: RelativeText.now())
    }

    var body: some View {
        let o = overview?.value ?? MonthOverview()
        let had = months?.value ?? []
        List {
            Section {
                stepper(had)
                    .listRowBackground(Tokens.ground)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
            }
            if o.total == 0 {
                Section {
                    HelpLine(text: "Nothing bought this month.")
                        .listRowBackground(Tokens.ground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                }
            } else {
                Section {
                    ForEach(o.items) { item in
                        if renaming == item.itemID {
                            renameRow(item)
                        } else if merging == item.itemID {
                            mergeRow(item)
                            ForEach(candidates) { m in
                                candidateRow(m, for: item)
                            }
                        } else {
                            itemRow(item)
                        }
                    }
                } header: {
                    SectionHeader("Items")
                }
                if !o.homes.isEmpty {
                    Section {
                        ForEach(o.homes) { h in
                            countRow(h.name, h.times)
                        }
                    } header: {
                        SectionHeader("Homes")
                    }
                }
                if o.people.count > 1 || (o.people.count == 1 && o.people[0].id != session.context?.personID) {
                    Section {
                        ForEach(o.people) { p in
                            countRow(personName(p.id), p.times)
                        }
                    } header: {
                        SectionHeader("Who shopped")
                    }
                }
            }
        }
        .listStyle(.plain)
        .textCase(nil)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .environment(\.defaultMinListRowHeight, ListView.rowHeight)
        .navigationTitle("History")
        .navigationSubtitle(o.total == 0 ? Text("Nothing bought") : Text("\(o.total) bought"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
        .onChange(of: month) {
            renaming = nil
            merging = nil
            observeMonth()
        }
        .onChange(of: mergeText) { findCandidates() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        months = Live(session.store, initial: []) { db in try Queries.purchaseMonths(db, scope) }
        observeMonth()
    }

    private func observeMonth() {
        guard let scope = session.scope else { return }
        let m = month
        overview = Live(session.store, initial: MonthOverview()) { db in try Queries.purchases(db, scope, month: m) }
    }

    // MARK: Months

    /// "YYYY-MM" of a date in the device's calendar, as the store groups the purchases.
    nonisolated static func month(of date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    private static func date(of month: String) -> Date? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }

    private func step(_ by: Int) {
        guard let d = Self.date(of: month), let next = Calendar.current.date(byAdding: .month, value: by, to: d) else { return }
        picked = Self.month(of: next)
    }

    private var monthTitle: String {
        guard let d = Self.date(of: month) else { return month }
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        return f.string(from: d)
    }

    /// The month in the middle, a step back while an earlier month has purchases, a step
    /// forward until this month.
    private func stepper(_ had: [PurchaseMonth]) -> some View {
        let thisMonth = Self.month(of: RelativeText.now())
        let earlier = had.contains { $0.month < month }
        return HStack(spacing: Tokens.space3) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: Tokens.space5, height: Tokens.space5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(earlier ? Tokens.accent : Tokens.inkFaint)
            .disabled(!earlier)
            .accessibilityLabel(Text("Previous month"))
            .accessibilityIdentifier("history-previous")
            Text(monthTitle)
                .font(.headline)
                .foregroundStyle(Tokens.ink)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText())
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: Tokens.space5, height: Tokens.space5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(month < thisMonth ? Tokens.accent : Tokens.inkFaint)
            .disabled(month >= thisMonth)
            .accessibilityLabel(Text("Next month"))
            .accessibilityIdentifier("history-next")
        }
        .frame(minHeight: ListView.rowHeight)
        .animation(.easeOut(duration: Tokens.motionQuick), value: month)
    }

    // MARK: Rows

    private func itemRow(_ item: PurchasedItem) -> some View {
        itemContent(item)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Retire", role: .destructive) { arm(item.itemID) }
                    .tint(Tokens.out)
                Button("Merge into…") { startMerge(item) }
                    .tint(Tokens.inkMuted)
                Button("Rename") { startRename(item) }
                    .tint(Tokens.accent)
            }
            #if os(macOS)
            .contextMenu {
                Button("Rename") { startRename(item) }
                Button("Merge into…") { startMerge(item) }
                Button("Retire", role: .destructive) { arm(item.itemID) }
            }
            .onTapGesture(count: 2) { startRename(item) }
            #endif
    }

    private func itemContent(_ item: PurchasedItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(Tokens.ink)
                Text(item.times == 1 ? "once, \(RelativeText.string(for: Date(timeIntervalSince1970: Double(item.lastAt) / 1000), locale: Locale.current))" : "\(item.times) times, last \(RelativeText.string(for: Date(timeIntervalSince1970: Double(item.lastAt) / 1000), locale: Locale.current))")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
            Spacer(minLength: Tokens.space2)
            if arming == item.itemID {
                Button {
                    arming = nil
                    disarm?.cancel()
                    try? HomeActions.retireItem(item.itemID, in: session)
                } label: {
                    Text("Really retire?")
                        .font(.footnote)
                        .foregroundStyle(Tokens.onOut)
                        .padding(.horizontal, Tokens.space2)
                        .padding(.vertical, Tokens.space1)
                        .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("retire-" + item.name)
            } else {
                Text(item.totals.map(\.text).joined(separator: ", "))
                    .font(Tokens.mono(.subheadline))
                    .foregroundStyle(Tokens.inkMuted)
                    .frame(minWidth: Tokens.space7, alignment: .trailing)
            }
        }
        .padding(.vertical, Tokens.space1)
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-" + item.name)
    }

    // MARK: Tidying

    private func arm(_ id: String) {
        arming = id
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, arming == id { arming = nil }
        }
    }

    private func startRename(_ item: PurchasedItem) {
        arming = nil
        merging = nil
        renameText = item.name
        renaming = item.itemID
        fieldFocused = true
    }

    private func startMerge(_ item: PurchasedItem) {
        arming = nil
        renaming = nil
        mergeText = ""
        candidates = []
        merging = item.itemID
        fieldFocused = true
    }

    private func done() {
        renaming = nil
        merging = nil
        fieldFocused = false
    }

    /// The catalog's matches for the typed name, as under the add bar, without the item itself.
    private func findCandidates() {
        guard let scope = session.scope, let drop = merging else { return }
        let text = mergeText
        candidates = ((try? session.store.read(scope) { db, s in try Queries.matches(db, s, prefix: text) }) ?? []).filter { $0.itemID != drop }
    }

    /// Rename, in the row: the item's name, which is its name on every list, at every home and
    /// in every month here.
    private func renameRow(_ item: PurchasedItem) -> some View {
        HStack(spacing: Tokens.space3) {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    try? HomeActions.renameItem(item.itemID, to: renameText, in: session)
                    done()
                }
                .accessibilityIdentifier("rename-item")
            #if os(iOS)
            Button("Cancel") { done() }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
            #endif
        }
        .frame(minHeight: ListView.rowHeight)
        #if os(macOS)
        .onExitCommand { done() }
        #endif
        .listRowBackground(Tokens.surface)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
    }

    /// Merge into, in the row: type the name of the item to keep; the matches follow under it.
    private func mergeRow(_ item: PurchasedItem) -> some View {
        HStack(spacing: Tokens.space3) {
            TextField("Merge \(item.name) into…", text: $mergeText)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit { if candidates.isEmpty { done() } }
                .accessibilityIdentifier("merge-item")
            #if os(iOS)
            Button("Cancel") { done() }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
            #endif
        }
        .frame(minHeight: ListView.rowHeight)
        #if os(macOS)
        .onExitCommand { done() }
        #endif
        .listRowBackground(Tokens.surface)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
    }

    /// One item the dropped one could be merged into, armed in place: merge is one way.
    private func candidateRow(_ m: Match, for item: PurchasedItem) -> some View {
        HStack(spacing: Tokens.space3) {
            ArmedButton(title: LocalizedStringKey(m.name), armedTitle: "Really merge into \(m.name)?", tint: Tokens.ink) {
                try? HomeActions.mergeItem(item.itemID, into: m.itemID, in: session)
                done()
            }
            .accessibilityIdentifier("merge-into-" + m.name)
            Spacer(minLength: Tokens.space2)
        }
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.surface)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space5 + Tokens.space3, bottom: 0, trailing: Tokens.space4))
    }

    private func countRow(_ name: String, _ times: Int) -> some View {
        HStack(spacing: Tokens.space3) {
            Text(name)
                .foregroundStyle(Tokens.ink)
            Spacer(minLength: Tokens.space2)
            Text(String(times))
                .font(Tokens.mono(.subheadline))
                .foregroundStyle(Tokens.inkMuted)
        }
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        .accessibilityElement(children: .combine)
    }

    /// The person as the family knows them; this device's own person is "You".
    private func personName(_ id: String) -> String {
        if id == session.context?.personID { return String(localized: "You") }
        return session.name(of: id) ?? String(localized: "Someone")
    }
}
