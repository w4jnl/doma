// The phone's tabs: Lists and Family in phase 0, Homes and Trip between them from phase 1. The
// Lists tab opens into the last-used list, the default list the first time, with the overview
// behind a Lists button at the top left and a second tap on the tab; a switcher over households
// takes the title's place when the person is in more than one. The badge on the icon is what
// this device has not seen yet: entries others added since each list was last in front. The badge on the icon is the open
// count across the shared lists and the person's own.
import SwiftUI
#if os(iOS)
import UserNotifications
#endif

struct MainView: View {
    @Environment(Session.self) private var session
    @State private var tab = Tab.lists
    @State private var listsAgain = 0

    enum Tab: Hashable { case lists, family }

    /// The tab on screen; tapping Lists while it is already up steps between the list and the
    /// overview, the way a tab's second tap goes to its root.
    private var selection: Binding<Tab> {
        Binding(get: { tab }, set: { new in
            if new == tab, new == .lists { listsAgain += 1 }
            tab = new
        })
    }

    var body: some View {
        TabView(selection: selection) {
            SwiftUI.Tab("Lists", systemImage: "list.bullet", value: Tab.lists) {
                ListsHome(again: listsAgain)
            }
            SwiftUI.Tab("Family", systemImage: "person.2", value: Tab.family) {
                NavigationStack {
                    FamilyView()
                }
            }
        }
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        .modifier(Badge())
    }
}

/// The Lists tab: the last-used list, remembered per household on this device, the default
/// list the first time, with the overview one level down.
struct ListsHome: View {
    /// Bumped when the Lists tab is tapped while already selected.
    var again = 0
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
                    ListView(listID: id, overview: { path = [.all] })
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
        .onChange(of: again) { path = path.isEmpty ? [.all] : [] }
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

/// Keeps the icon's badge at what this device has not seen: entries others added to the
/// household's lists after each list was last in front. It falls as lists are opened.
struct Badge: ViewModifier {
    @Environment(Session.self) private var session
    @State private var marks: Live<[OpenMark]>?

    private var unseen: Int {
        guard let h = session.currentHouseholdID else { return 0 }
        return session.unseen(household: h, in: marks?.value ?? []).values.reduce(0, +)
    }

    func body(content: Content) -> some View {
        content
            .task(id: session.scope) {
                guard let scope = session.scope else { return }
                marks = Live(session.store, initial: []) { db in try Queries.openMarks(db, scope) }
            }
            .onChange(of: unseen, initial: true) { _, n in
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
