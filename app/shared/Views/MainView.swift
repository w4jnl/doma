// The phone's tabs: Lists and Family in phase 0, Homes and Trip between them from phase 1. The
// Lists tab opens into the last-used list, the default list the first time, with the other
// lists in the title's menu and the overview behind All lists; a switcher over households takes
// the title's place when the person is in more than one. The badge on the icon is the open
// count across the shared lists and the person's own.
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
            ListsHome()
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

/// The Lists tab: the last-used list, remembered per household on this device, the default
/// list the first time, with the overview one level down.
struct ListsHome: View {
    @Environment(Session.self) private var session
    @State private var lists: Live<[ListSummary]>?
    @State private var currentID: String?
    @State private var path: [Route] = []

    enum Route: Hashable {
        case all
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let id = currentID {
                    ListView(listID: id, switcher: ListSwitcher(lists: lists?.value ?? [], pick: open, all: { path = [.all] }))
                        .id(id)
                } else {
                    Tokens.ground
                }
            }
            .navigationDestination(for: Route.self) { _ in
                ListsView(pick: { id in
                    open(id)
                    path = []
                })
            }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
        .onChange(of: lists?.value) { _, now in settle(now ?? []) }
    }

    private var key: String { "list.current." + (session.current?.id ?? "") }

    private func observe() {
        guard let scope = session.scope else { return }
        lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
        settle(lists?.value ?? [])
    }

    /// The list on screen when it still exists, else the remembered one, else the default list.
    private func settle(_ all: [ListSummary]) {
        guard !all.isEmpty else { return }
        if let id = currentID, all.contains(where: { $0.id == id }) { return }
        if let r = UserDefaults.standard.string(forKey: key), all.contains(where: { $0.id == r }) {
            currentID = r
            return
        }
        currentID = (all.first { $0.isDefault } ?? all[0]).id
    }

    private func open(_ id: String) {
        currentID = id
        UserDefaults.standard.set(id, forKey: key)
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

/// A menu over the households in the title's place, only when the person is in more than one.
struct HouseholdTitle: ToolbarContent {
    @Environment(Session.self) private var session

    var body: some ToolbarContent {
        if session.households.count > 1 {
            ToolbarItem(placement: .principal) {
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
            }
        }
    }
}
