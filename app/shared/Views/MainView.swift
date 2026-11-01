// The phone's tabs: Lists and Family in phase 0, Homes and Trip between them from phase 1. The
// household name is the title; the switcher takes its place when the person is in more than
// one. The badge on the icon is the open count across the shared lists and the person's own.
import SwiftUI
#if os(iOS)
import UserNotifications
#endif

struct MainView: View {
    @Environment(Session.self) private var session
    @State private var tab = Tab.lists

    enum Tab: Hashable { case lists, family }

    var body: some View {
        @Bindable var session = session
        TabView(selection: $tab) {
            NavigationStack {
                ListsView()
            }
            .tabItem { Label("Lists", systemImage: "list.bullet") }
            .tag(Tab.lists)
            NavigationStack {
                FamilyView()
            }
            .tabItem { Label("Family", systemImage: "person.2") }
            .tag(Tab.family)
        }
        .modifier(Badge())
    }
}

/// Keeps the icon's badge at the open count of the current household.
struct Badge: ViewModifier {
    @Environment(Session.self) private var session
    @State private var count: Live<Int>?

    func body(content: Content) -> some View {
        content
            .task(id: session.scope) {
                guard let scope = session.scope else { return }
                count = Live(session.store, initial: 0) { db in try Queries.openCount(db, scope) }
            }
            .onChange(of: count?.value ?? 0, initial: true) { _, n in
                #if os(iOS)
                UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
                #endif
            }
    }
}

/// The household name as a title, or a menu over the households when there is more than one.
struct HouseholdTitle: ToolbarContent {
    @Environment(Session.self) private var session

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if session.households.count > 1 {
                Menu {
                    ForEach(session.households) { h in
                        Button {
                            session.currentHouseholdID = h.id
                        } label: {
                            if h.id == session.current?.id {
                                Label(h.name, systemImage: "checkmark")
                            } else {
                                Text(h.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Tokens.space1) {
                        Text(session.current?.name ?? "")
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .foregroundStyle(Tokens.ink)
                }
                .accessibilityLabel(Text("Household"))
            } else {
                Text(session.current?.name ?? "")
                    .font(.headline)
                    .foregroundStyle(Tokens.ink)
            }
        }
    }
}
