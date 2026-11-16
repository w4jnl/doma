// All items, one level under History: every item the family has, the never bought ones too,
// by name with a search field. A swipe on a row (the row's menu on the Mac) offers Rename,
// Merge into and Retire, as History's rows do, for a tidy-up no single month can offer.

import SwiftUI

struct ItemsView: View {
    @Environment(Session.self) private var session
    @State private var items: Live<[CatalogItem]>?
    @State private var search = ""

    var body: some View {
        let all = items?.value ?? []
        let key = Norm.name(search)
        let shown = key.isEmpty ? all : all.filter { Norm.name($0.name).contains(key) }
        List {
            ForEach(shown) { item in
                TidyRow(itemID: item.itemID, name: item.name) { armed in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .foregroundStyle(Tokens.ink)
                        if let last = item.lastAt, item.times > 0 {
                            let when = RelativeText.string(for: Date(timeIntervalSince1970: Double(last) / 1000), locale: Locale.current)
                            Text(item.times == 1 ? "once, \(when)" : "\(item.times) times, last \(when)")
                                .font(.footnote)
                                .foregroundStyle(Tokens.inkMuted)
                        }
                    }
                    .padding(.vertical, Tokens.space1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("item-" + item.name)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .environment(\.defaultMinListRowHeight, ListView.rowHeight)
        .searchable(text: $search)
        .navigationTitle("All items")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        items = Live(session.store, initial: []) { db in try Queries.allItems(db, scope) }
    }
}
