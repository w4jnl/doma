// Lists: the shared lists first, then the person's own, each with its glyph, name and open
// count; + creates one, asking a name and whether it is shared with the household or just me.
import SwiftUI

struct ListsView: View {
    @Environment(Session.self) private var session
    @State private var lists: Live<[ListSummary]>?
    @State private var adding = false
    @State private var newName = ""
    @State private var personal = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        List {
            if adding {
                Section {
                    newListRow
                }
            }
            let all = lists?.value ?? []
            let shared = all.filter { !$0.isPersonal }
            let mine = all.filter(\.isPersonal)
            Section {
                ForEach(shared) { l in
                    row(l)
                }
            } header: {
                Text("Shared")
            }
            Section {
                ForEach(mine) { l in
                    row(l)
                }
                if mine.isEmpty {
                    Text("A list just for you. Tap + and choose Just me.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                }
            } header: {
                Text("Just me")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle(session.current?.name ?? "")
        .navigationDestination(for: String.self) { id in ListView(listID: id) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    adding.toggle()
                    if adding { nameFocused = true }
                } label: {
                    Label("New list", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .task(id: session.scope) {
            guard let scope = session.scope else { return }
            lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
        }
    }

    private func row(_ l: ListSummary) -> some View {
        NavigationLink(value: l.id) {
            HStack(spacing: Tokens.space3) {
                Image(systemName: l.isPersonal ? "person" : "list.bullet")
                    .foregroundStyle(Tokens.inkMuted)
                    .accessibilityHidden(true)
                Text(l.name)
                    .foregroundStyle(Tokens.ink)
                Spacer()
                if l.openCount > 0 {
                    Text(verbatim: String(l.openCount))
                        .font(Tokens.mono(.subheadline))
                        .foregroundStyle(Tokens.inkMuted)
                }
            }
            .rowHeight()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(l.name), \(l.openCount) to get"))
        }
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
    }

    private var newListRow: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            TextField("Name", text: $newName)
                .focused($nameFocused)
                .textFieldStyle(.plain)
                .padding(Tokens.space2)
                .background(Tokens.surfaceSunk, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                .onSubmit(create)
                .accessibilityLabel(Text("List name"))
            Picker("Who sees it", selection: $personal) {
                Text("Shared with the household").tag(false)
                Text("Just me").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Button("Cancel") {
                    adding = false
                    newName = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
                Spacer()
                Button("Add", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, Tokens.space2)
        .listRowBackground(Tokens.surface)
    }

    private func create() {
        guard let id = try? ListActions.createList(named: newName, personal: personal, in: session) else { return }
        _ = id
        newName = ""
        adding = false
    }
}
