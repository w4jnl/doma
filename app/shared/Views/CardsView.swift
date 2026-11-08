// Cards (docs/design.md, "Cards"): the family's loyalty cards, one row per card with the shop's
// logo or its initials in the card's colour, the card last shown first; a tap shows the Card,
// the barcode large on white with the digits under it, bright and awake while it is in front;
// + adds one by camera, by a pasted picture or by typing, with the shop's name suggested from
// the bundled table; Edit, Share with the family and Remove behind a swipe. Every shopping list
// carries the card glyph that opens this screen, so the till is two taps from the list.
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The route a list's card glyph and the Lists overview push.
struct CardsRoute: Hashable {}
struct CardRoute: Hashable { var id: String }

struct CardsView: View {
    @Environment(Session.self) private var session
    @State private var cards: Live<[CardRow]>?
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?
    @State private var adding = false
    @State private var editing: CardRow?

    var body: some View {
        let all = CardsShown.ordered(cards?.value ?? [], session: session)
        List {
            if all.isEmpty {
                Section {
                    HelpLine(text: "No cards yet. Add the first with +.")
                        .listRowBackground(Tokens.ground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                }
            } else {
                Section {
                    ForEach(all) { c in row(c) }
                }
            }
        }
        .listStyle(.plain)
        .textCase(nil)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .environment(\.defaultMinListRowHeight, ListView.rowHeight)
        .navigationTitle("Cards")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .navigationDestination(for: CardRoute.self) { r in CardView(cardID: r.id) }
        .navigationDestination(isPresented: $adding) { AddCardView(editing: nil) }
        .navigationDestination(item: $editing) { c in AddCardView(editing: c.id) }
        .toolbar {
            ToolbarItem(placement: .automatic) { OfflineBadge() }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    adding = true
                } label: {
                    Label("Add a card", systemImage: "plus")
                }
                .accessibilityIdentifier("add-card")
            }
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        cards = Live(session.store, initial: []) { db in try Queries.cards(db, scope) }
    }

    private func row(_ c: CardRow) -> some View {
        NavigationLink(value: CardRoute(id: c.id)) {
            HStack(spacing: Tokens.space3) {
                CardTile(card: c, size: Tokens.rowH)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name)
                        .foregroundStyle(Tokens.ink)
                    if c.isPersonal {
                        Text("Just me")
                            .font(.footnote)
                            .foregroundStyle(Tokens.inkMuted)
                    }
                }
                Spacer(minLength: Tokens.space2)
                if arming == c.id {
                    Button {
                        arming = nil
                        disarm?.cancel()
                        try? CardActions.archive(c, in: session)
                    } label: {
                        Text("Really remove?")
                            .font(.footnote)
                            .foregroundStyle(Tokens.onOut)
                            .padding(.horizontal, Tokens.space2)
                            .padding(.vertical, Tokens.space1)
                            .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("remove-card-" + c.name)
                }
            }
            .padding(.vertical, Tokens.space1)
            .frame(minHeight: ListView.rowHeight)
        }
        .accessibilityIdentifier("card-" + c.name)
        .listRowBackground(Tokens.ground)
        .listRowSeparatorTint(Tokens.line)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", role: .destructive) { arm(c.id) }
                .tint(Tokens.out)
            if c.isPersonal {
                Button("Share with the family") { _ = try? CardActions.share(c, in: session) }
                    .tint(Tokens.inkMuted)
            }
            Button("Edit") { editing = c }
                .tint(Tokens.accent)
        }
        #if os(macOS)
        .contextMenu {
            Button("Edit") { editing = c }
            if c.isPersonal {
                Button("Share with the family") { _ = try? CardActions.share(c, in: session) }
            }
            Button("Remove", role: .destructive) { arm(c.id) }
        }
        #endif
    }

    private func arm(_ id: String) {
        arming = id
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, arming == id { arming = nil }
        }
    }
}

/// Which cards were shown last, per household on this device, so the one the family uses most
/// sits first.
@MainActor
enum CardsShown {
    static func key(_ session: Session) -> String { "cards.shown." + (session.currentRef?.key ?? "") }

    static func list(_ session: Session) -> [String] {
        UITestHooks.testing ? [] : (UserDefaults.standard.stringArray(forKey: key(session)) ?? [])
    }

    static func touch(_ id: String, session: Session) {
        guard !UITestHooks.testing else { return }
        var ids = list(session).filter { $0 != id }
        ids.insert(id, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(50)), forKey: key(session))
    }

    static func ordered(_ cards: [CardRow], session: Session) -> [CardRow] {
        let shown = list(session)
        let rank = Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($1, $0) })
        return cards.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (ra?, rb?): return ra < rb
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

/// The shop's logo, or its initials in the card's colour.
struct CardTile: View {
    var card: CardRow
    var size: CGFloat
    @Environment(Session.self) private var session

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.radiusSM)
                .fill(Tokens.listColor(card.colour))
            if let logoID = card.logoID, let cg = session.photos.logo(cardID: card.id, logoID: logoID) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(size / 10)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
            } else {
                Text(card.initials)
                    .font(Tokens.mono(fixed: size * 0.4, bold: true))
                    .foregroundStyle(Tokens.onAccent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Card

/// The barcode large on white, the digits under it; bright and awake while in front.
struct CardView: View {
    var cardID: String
    @Environment(Session.self) private var session
    @State private var card: Live<CardRow?>?
    #if os(iOS)
    @State private var brightnessBefore: CGFloat?
    #endif

    var body: some View {
        let c = card?.value ?? nil
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: Tokens.space4) {
                if let c {
                    if let cg = Barcode.image(c.value, format: c.format) {
                        Image(decorative: cg, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: Barcode.isLinear(c.format) ? .infinity : 360)
                            .padding(.horizontal, Tokens.space4)
                            .accessibilityIdentifier("barcode")
                    } else {
                        Text("This code cannot be drawn; show the number.")
                            .font(.footnote)
                            .foregroundStyle(.black.opacity(0.6))
                    }
                    Text(c.value)
                        .font(Tokens.mono(.title3))
                        .foregroundStyle(.black)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("card-number")
                    Text(Barcode.name(of: c.format))
                        .font(.footnote)
                        .foregroundStyle(.black.opacity(0.5))
                }
            }
            .frame(maxWidth: Tokens.contentMax)
            .padding(.vertical, Tokens.space6)
        }
        .navigationTitle(c?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) { OfflineBadge() }
        }
        .onAppear {
            observe()
            CardsShown.touch(cardID, session: session)
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            if let screen = Self.screen, !UITestHooks.testing {
                brightnessBefore = screen.brightness
                screen.brightness = 1
            }
            #endif
        }
        .onDisappear {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            if let before = brightnessBefore, let screen = Self.screen {
                screen.brightness = before
            }
            #endif
        }
        .onChange(of: session.scope) { observe() }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        let id = cardID
        card = Live(session.store, initial: nil) { db in try Queries.card(db, scope, id: id) }
    }

    #if os(iOS)
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }
    #endif
}

// MARK: - Add a card

/// Add a card, or edit one: the camera at the top until a code is read, Paste for a picture on
/// the clipboard, the number with its format, the shop's name with the bundled table's
/// suggestions under it, and whose card it is. One screen, two fields: the one exception to
/// the one-field rule beside Scan.
struct AddCardView: View {
    var editing: String?
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var format = "code128"
    @State private var formatChosen = false
    @State private var name = ""
    @State private var domain: String?
    @State private var pickedName: String?
    @State private var personal = false
    @State private var scanned = false
    @State private var suggestions: [Shop] = []
    @State private var problem: String?
    @State private var card: CardRow?
    @FocusState private var focus: Field?

    enum Field { case number, shop }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !CardActions.cleaned(value).isEmpty
    }

    var body: some View {
        List {
            if editing == nil, QRScanner.isAvailable, !scanned {
                Section {
                    QRScanner(found: { _ in }, types: Barcode.cameraTypes, foundType: { code, type in take(code, type) })
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusMD))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.radiusMD).strokeBorder(Tokens.line))
                        .listRowBackground(Tokens.ground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                        .accessibilityLabel(Text("Camera"))
                    HelpLine(text: "Point the camera at the card's barcode.")
                        .listRowBackground(Tokens.ground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.space4, bottom: 0, trailing: Tokens.space4))
                }
            }
            Section {
                HStack(spacing: Tokens.space3) {
                    TextField("Number", text: $value)
                        .textFieldStyle(.plain)
                        .font(Tokens.mono(.body))
                        .focused($focus, equals: .number)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .submitLabel(.next)
                        .onSubmit { focus = .shop }
                        .accessibilityIdentifier("card-value")
                    PasteButton(supportedContentTypes: [.image]) { providers in
                        paste(providers)
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("paste-picture")
                }
                .listRowBackground(ListsView.rowGround)
                Picker("Format", selection: $format) {
                    ForEach(Barcode.formats, id: \.id) { f in
                        Text(f.name).tag(f.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: format) { formatChosen = true }
                .listRowBackground(ListsView.rowGround)
            } header: {
                SectionHeader("Barcode")
            } footer: {
                ProblemLine(text: problem)
            }
            Section {
                TextField("Shop", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .shop)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("card-shop")
                    .listRowBackground(ListsView.rowGround)
                ForEach(suggestions) { s in
                    Button {
                        name = s.name
                        pickedName = s.name
                        domain = s.domain
                        suggestions = []
                    } label: {
                        HStack {
                            Text(s.name)
                                .foregroundStyle(Tokens.ink)
                            Spacer()
                            if let d = s.domain {
                                Text(d)
                                    .font(Tokens.mono(.footnote))
                                    .foregroundStyle(Tokens.inkMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Tokens.surfaceSunk)
                    .accessibilityIdentifier("shop-" + s.name)
                }
                if editing == nil {
                    Picker("Who sees it", selection: $personal) {
                        Text("Household").tag(false)
                        Text("Just me").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(ListsView.rowGround)
                }
            } header: {
                SectionHeader("Shop")
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
        .navigationTitle(editing == nil ? "Add a card" : "Edit card")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? "Add" : "Save", action: save)
                    .disabled(!canSave)
                    .accessibilityIdentifier("save-card")
            }
        }
        .onChange(of: value) { _, now in
            problem = nil
            if !formatChosen { format = CardActions.guessFormat(for: now) }
        }
        .onChange(of: name) { _, now in
            if pickedName != now { domain = nil }
            suggestions = pickedName == now ? [] : Shops.suggest(now)
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let editing, let scope = session.scope, let c = try? session.store.read(scope, { db, s in try Queries.card(db, s, id: editing) }) {
            card = c
            value = c.value
            format = c.format
            formatChosen = true
            name = c.name
            pickedName = c.name
            domain = c.domain
            personal = c.isPersonal
        }
        focus = editing == nil && (QRScanner.isAvailable || value.isEmpty) ? .number : .shop
        if editing == nil, QRScanner.isAvailable { focus = nil }
    }

    /// A code the camera read.
    private func take(_ code: String, _ type: AVMetadataObject.ObjectType) {
        guard !scanned else { return }
        guard let f = Barcode.format(of: type, value: code) else {
            problem = String(localized: "doma cannot draw this kind of code.")
            return
        }
        value = code
        format = f
        formatChosen = true
        scanned = true
        problem = nil
        focus = .shop
    }

    /// A picture from the clipboard, read for its barcode: the way out of another wallet.
    private func paste(_ providers: [NSItemProvider]) {
        guard let p = providers.first else { return }
        Task {
            let data = await Self.data(from: p)
            guard let data, let cg = PhotoLoader.decode(data), let read = Barcode.read(cg) else {
                problem = String(localized: "No barcode in the picture.")
                return
            }
            value = read.value
            format = read.format
            formatChosen = true
            scanned = true
            problem = nil
            focus = .shop
        }
    }

    private static func data(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in cont.resume(returning: data) }
        }
    }

    private func save() {
        guard canSave else { return }
        guard let v = Barcode.normalized(value, format: format) else {
            problem = String(localized: "That is not a valid \(Barcode.name(of: format)).")
            return
        }
        do {
            if let card {
                try CardActions.edit(card, name: name, format: format, value: v, domain: domain, in: session)
            } else {
                let all = (try? session.scope.flatMap { scope in try session.store.read(scope) { db, s in try Queries.cards(db, s) } }) ?? []
                try CardActions.add(name: name, format: format, value: v, domain: domain, personal: personal, colour: CardActions.nextColour(all), in: session)
            }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
