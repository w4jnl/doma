// History (docs/design.md, "History and quantities"): what the household bought, one month
// at a time, stepped back and forth under the title, the latest month with a purchase first.
// Per item with how many times, the totals
// of quantity by unit and when last; per home; who shopped. It reads the cleared entries and
// makes no event, so it is the same on every phone and on the Mac.
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
                        itemRow(item)
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
        .onChange(of: month) { observeMonth() }
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
        HStack(alignment: .firstTextBaseline, spacing: Tokens.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(Tokens.ink)
                Text(item.times == 1 ? "once, \(RelativeText.string(for: Date(timeIntervalSince1970: Double(item.lastAt) / 1000), locale: Locale.current))" : "\(item.times) times, last \(RelativeText.string(for: Date(timeIntervalSince1970: Double(item.lastAt) / 1000), locale: Locale.current))")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
            Spacer(minLength: Tokens.space2)
            Text(item.totals.map(\.text).joined(separator: ", "))
                .font(Tokens.mono(.subheadline))
                .foregroundStyle(Tokens.inkMuted)
                .frame(minWidth: Tokens.space7, alignment: .trailing)
        }
        .padding(.vertical, Tokens.space1)
        .frame(minHeight: ListView.rowHeight)
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-" + item.name)
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
