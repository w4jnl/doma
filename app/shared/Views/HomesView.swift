// Homes: one card per home with its name, how many staples are out, low or unknown, and its
// spots' pictures; a tap opens the home. + makes a home; a long-press or a swipe offers Rename
// and Archive, armed in place.
import SwiftUI

struct HomesView: View {
    /// Set on the Mac's sidebar flow: a tap picks the home instead of pushing it.
    var pick: ((String) -> Void)?
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cards: Live<[HomeCard]>?
    @State private var adding = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?
    @FocusState private var nameFocused: Bool
    @FocusState private var renameFocused: Bool

    var body: some View {
        let all = cards?.value ?? []
        List {
            if adding {
                Section {
                    TextField("Home name", text: $newName)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("new-home-name")
                        .listRowBackground(ListsView.rowGround)
                } header: {
                    SectionHeader("New home")
                }
                .transition(Motion.arrive(reduceMotion, from: .top))
            }
            Section {
                ForEach(all) { card in
                    row(card)
                }
            } footer: {
                if all.isEmpty {
                    Text("A home is a place the family keeps things: the house, the hut, the boat. Tap + to add one.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                } else if all.count == 1 {
                    Text("Add a second home and the Trip tab says what to bring from one to the other.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
        .animation(Motion.of(reduceMotion, Motion.base), value: adding)
        .textCase(nil)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle("Homes")
        .navigationDestination(for: String.self) { id in HomeView(homeID: id) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            HouseholdTitle()
            ToolbarItem(placement: .automatic) {
                OfflineBadge()
            }
            if adding {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        adding = false
                        newName = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create home", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                        nameFocused = true
                    } label: {
                        Label("New home", systemImage: "plus")
                    }
                    .accessibilityIdentifier("new-home")
                }
            }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        let staleness = Staleness(days: session.current?.stalenessDays, now: RelativeText.now())
        cards = Live(session.store, initial: []) { db in try Queries.homeCards(db, scope, staleness: staleness) }
    }

    @ViewBuilder
    private func row(_ card: HomeCard) -> some View {
        if renaming == card.id {
            HStack {
                TextField("Home name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .submitLabel(.done)
                    .onSubmit { commitRename(card) }
                Button("Cancel") { renaming = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.inkMuted)
            }
            .rowHeight()
            .listRowBackground(ListsView.rowGround)
        } else {
            Group {
                if let pick {
                    Button { pick(card.id) } label: { HomeCardRow(card: card, arming: arming == card.id, archive: { archive(card) }) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: card.id) {
                        HomeCardRow(card: card, arming: arming == card.id, archive: { archive(card) })
                    }
                }
            }
            .listRowBackground(ListsView.rowGround)
            .listRowSeparatorTint(Tokens.line)
            .accessibilityIdentifier("home-" + card.name)
            .contextMenu {
                Button("Rename") { startRename(card) }
                Button("Archive") { arm(card) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Archive") { arm(card) }
                Button("Rename") { startRename(card) }
                    .tint(Tokens.accent)
            }
        }
    }

    private func startRename(_ card: HomeCard) {
        renameText = card.name
        renaming = card.id
        renameFocused = true
    }

    private func commitRename(_ card: HomeCard) {
        try? HomeActions.renameHome(card.id, to: renameText, in: session)
        renaming = nil
    }

    private func arm(_ card: HomeCard) {
        arming = card.id
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, arming == card.id { arming = nil }
        }
    }

    private func archive(_ card: HomeCard) {
        arming = nil
        disarm?.cancel()
        try? HomeActions.archiveHome(card.id, in: session)
    }

    private func create() {
        guard let id = try? HomeActions.createHome(named: newName, in: session) else { return }
        newName = ""
        adding = false
        pick?(id)
    }
}

/// A home's card: the name, what it misses, and its spots' pictures.
struct HomeCardRow: View {
    var card: HomeCard
    var arming = false
    var archive: () -> Void = {}
    @Environment(Session.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            HStack(spacing: Tokens.space3) {
                Symbol.home.image
                    .foregroundStyle(Tokens.inkMuted)
                    .frame(width: Tokens.space5)
                    .accessibilityHidden(true)
                Text(card.name)
                    .foregroundStyle(Tokens.ink)
                Spacer()
                if arming {
                    Button(action: archive) {
                        Text("Really archive?")
                            .font(.footnote)
                            .foregroundStyle(Tokens.onOut)
                            .padding(.horizontal, Tokens.space2)
                            .padding(.vertical, Tokens.space1)
                            .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text(missing)
                        .font(.footnote)
                        .foregroundStyle(card.missing > 0 ? Tokens.ink : Tokens.inkMuted)
                }
            }
            .rowHeight()
            if !card.spots.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Tokens.space2) {
                        ForEach(card.spots) { spot in
                            SpotThumb(spot: spot, size: Tokens.thumb)
                        }
                    }
                    .padding(.leading, Tokens.space5 + Tokens.space3)
                }
                .scrollIndicators(.hidden)
                // the card is one tap, the home; the strip is for looking
                .allowsHitTesting(false)
                .padding(.bottom, Tokens.space2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(card.name), \(missing)"))
    }

    private var missing: String {
        if card.staples == 0 { return String(localized: "No staples yet") }
        if card.missing == 0 { return String(localized: "All there") }
        return String(localized: "\(card.missing) missing")
    }
}

/// A spot's current picture at a size, with its name under it; a pending or absent picture is
/// the tray symbol on surface-sunk.
struct SpotThumb: View {
    var spot: SpotRow
    var size: CGFloat
    var named = true
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: Tokens.space1) {
            PhotoImage(photoID: spot.photoID, thumb: true)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusMD))
            if named {
                Text(spot.name)
                    .font(.caption)
                    .foregroundStyle(Tokens.inkMuted)
                    .lineLimit(1)
                    .frame(width: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spot.photoID == nil ? Text("\(spot.name), no picture yet") : Text(spot.name))
    }
}

/// A picture by photo id, from the loader; the tray symbol until it is there.
struct PhotoImage: View {
    var photoID: String?
    var thumb: Bool
    @Environment(Session.self) private var session

    var body: some View {
        ZStack {
            Tokens.surfaceSunk
            if let id = photoID, let cg = session.photos.image(id, thumb: thumb) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "tray")
                    .foregroundStyle(Tokens.inkFaint)
                    .imageScale(.large)
            }
        }
        .clipped()
    }
}
