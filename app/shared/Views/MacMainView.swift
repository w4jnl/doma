// The Mac: a sidebar with the lists and Family, the list in the main pane. Keyboard: ⌘N new
// list, return adds, space strikes the selected row, ⌘⌫ clears, ⌘1 and ⌘4 the sections (⌘2
// and ⌘3 arrive with Homes and Trip).
#if os(macOS)
import SwiftUI

struct MacMainView: View {
    @Environment(Session.self) private var session
    @State private var lists: Live<[ListSummary]>?
    @State private var selection: Selection? = .lists
    @State private var adding = false
    @State private var newName = ""
    @State private var personal = false

    enum Selection: Hashable {
        case lists
        case list(String)
        case family
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach((lists?.value ?? []).filter { !$0.isPersonal }) { l in
                        listRow(l)
                    }
                } header: {
                    Text("Lists")
                }
                Section {
                    ForEach((lists?.value ?? []).filter(\.isPersonal)) { l in
                        listRow(l)
                    }
                } header: {
                    Text("Only yours")
                }
                Section {
                    Label("Family", systemImage: "person.2")
                        .tag(Selection.family)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(session.current?.name ?? "doma")
            .toolbar {
                ToolbarItem {
                    Button {
                        adding = true
                    } label: {
                        Label("New list", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            .sheet(isPresented: $adding) {
                newListSheet
            }
        } detail: {
            switch selection {
            case .list(let id):
                NavigationStack { ListView(listID: id) }
            case .family:
                NavigationStack { FamilyView() }
            default:
                VStack(spacing: Tokens.space3) {
                    Mark(size: 40)
                    Text("Choose a list")
                        .foregroundStyle(Tokens.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.ground)
            }
        }
        .task(id: session.scope) {
            guard let scope = session.scope else { return }
            lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
            if case .lists = selection, let first = lists?.value.first {
                selection = .list(first.id)
            }
        }
        .background {
            // ⌘1 the lists, ⌘4 Family
            Button("") { if let first = lists?.value.first { selection = .list(first.id) } }
                .keyboardShortcut("1", modifiers: .command)
                .hidden()
            Button("") { selection = .family }
                .keyboardShortcut("4", modifiers: .command)
                .hidden()
        }
    }

    private func listRow(_ l: ListSummary) -> some View {
        HStack {
            Label(l.name, systemImage: l.isPersonal ? "person" : "list.bullet")
            Spacer()
            if l.openCount > 0 {
                Text(verbatim: String(l.openCount))
                    .font(Tokens.mono(.footnote))
                    .foregroundStyle(Tokens.inkMuted)
            }
        }
        .tag(Selection.list(l.id))
    }

    private var newListSheet: some View {
        VStack(alignment: .leading, spacing: Tokens.space3) {
            Text("New list")
                .font(.headline)
            TextField("List name", text: $newName)
                .textFieldStyle(.roundedBorder)
            Text("Who sees it")
                .font(.footnote)
                .foregroundStyle(Tokens.inkMuted)
                .onSubmit(create)
            Picker("Who sees it", selection: $personal) {
                Text("Everyone").tag(false)
                Text("Only you").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { adding = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create list", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Tokens.space5)
        .frame(width: 360)
    }

    private func create() {
        if let id = try? ListActions.createList(named: newName, personal: personal, in: session) {
            selection = .list(id)
        }
        newName = ""
        adding = false
    }
}
#endif
