// Family: the members with role and last seen, the pending invites and guest links with their
// expiry, Invite and Guest link in the toolbar, Leave armed in place. An invite opens a sheet
// with the QR on surface-sunk, the share button under it, the link in mono.
import SwiftUI

struct FamilyView: View {
    /// A model given instead of loaded: the snapshot tests.
    var preset: FamilyModel?
    @Environment(Session.self) private var session
    @State private var model: FamilyModel?
    @State private var invite: Invite?
    @State private var guest: GuestLink?
    @State private var makingGuest = false
    @State private var scanning = false
    @State private var settings = false
    /// The member or link whose Remove or Revoke is armed in its row.
    @State private var arming: String?
    @State private var disarm: Task<Void, Never>?

    private var isOwner: Bool { session.current?.isOwner ?? false }

    var body: some View {
        List {
            if let m = model {
                Section {
                    ForEach(m.members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                    .foregroundStyle(Tokens.ink)
                                Text(LocalizedStringKey(member.role))
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.inkMuted)
                            }
                            Spacer()
                            if arming == member.personID {
                                armedPill("Really remove?") { Task { await m.remove(member: member.personID) } }
                            } else if let seen = member.lastSeenAt {
                                RelativeText(millis: seen)
                            }
                        }
                        .rowHeight()
                        .listRowBackground(Self.rowGround)
                        .listRowSeparatorTint(Tokens.line)
                        .animation(Motion.quick, value: arming == member.personID)
                        .removable(isOwner && member.personID != session.context?.personID, title: "Remove") { arm(member.personID) }
                    }
                } header: {
                    SectionHeader("Members")
                }
                if isOwner, !m.invites.isEmpty {
                    Section {
                        ForEach(m.invites) { inv in
                            HStack {
                                Image(systemName: "qrcode")
                                    .foregroundStyle(Tokens.inkMuted)
                                    .accessibilityHidden(true)
                                Text(LocalizedStringKey(inv.role))
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if arming == inv.id {
                                    armedPill("Really revoke?") { Task { await m.revokeInvite(inv.id) } }
                                } else {
                                    HStack(spacing: Tokens.space1) {
                                        Text("expires")
                                            .font(.footnote)
                                            .foregroundStyle(Tokens.inkMuted)
                                        RelativeText(millis: inv.expiresAt)
                                    }
                                }
                            }
                            .rowHeight()
                            .listRowBackground(Self.rowGround)
                            .listRowSeparatorTint(Tokens.line)
                            .animation(Motion.quick, value: arming == inv.id)
                            .removable(true, title: "Revoke") { arm(inv.id) }
                        }
                    } header: {
                        SectionHeader("Invites")
                    }
                }
                if isOwner, !m.guests.isEmpty {
                    Section {
                        ForEach(m.guests) { g in
                            HStack {
                                Symbol.guest.image
                                    .foregroundStyle(Tokens.inkMuted)
                                    .accessibilityHidden(true)
                                Text(g.label.isEmpty ? String(localized: "Guest") : g.label)
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if arming == g.id {
                                    armedPill("Really revoke?") { Task { await m.revokeGuest(g.id) } }
                                } else {
                                    HStack(spacing: Tokens.space1) {
                                        Text("expires")
                                            .font(.footnote)
                                            .foregroundStyle(Tokens.inkMuted)
                                        RelativeText(millis: g.expiresAt)
                                    }
                                    if let url = g.url {
                                        ShareLink(item: url) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.subheadline)
                                                .foregroundStyle(Tokens.inkMuted)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(Text("Share the guest link"))
                                    }
                                }
                            }
                            .rowHeight()
                            .listRowBackground(Self.rowGround)
                            .listRowSeparatorTint(Tokens.line)
                            .animation(Motion.quick, value: arming == g.id)
                            .removable(true, title: "Revoke") { arm(g.id) }
                        }
                    } header: {
                        SectionHeader("Guest links")
                    }
                }
                Section {
                    Button("Scan a code") { scanning = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.accent)
                        .listRowBackground(Self.rowGround)
                    ArmedButton(title: "Leave this household", armedTitle: "Really leave?") {
                        Task { _ = await m.leave() }
                    }
                    .listRowBackground(Self.rowGround)
                }
                if let p = m.problem {
                    Section {
                        ProblemLine(text: p)
                            .listRowBackground(Self.rowGround)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle("Family")
        .navigationSubtitle(session.current?.name ?? "")
        .textCase(nil)
        .toolbar {
            HouseholdTitle()
            ToolbarItem(placement: .automatic) { OfflineBadge() }
            ToolbarItemGroup(placement: .primaryAction) {
                if isOwner {
                    // Invite is the one prominent button on the screen; Guest link and
                    // Settings are plain. On the Mac both open popovers from their buttons.
                    Menu {
                        Button("Invite a member") { Task { invite = await model?.invite(role: "member") } }
                        Button("Invite an owner") { Task { invite = await model?.invite(role: "owner") } }
                    } label: {
                        #if os(macOS)
                        Label("Invite", systemImage: "person.badge.plus")
                            .labelStyle(.titleAndIcon)
                        #else
                        Label("Invite", systemImage: "qrcode")
                            .labelStyle(.titleOnly)
                        #endif
                    }
                    .buttonStyle(.borderedProminent)
                    #if os(macOS)
                    .popover(item: $invite, arrowEdge: .bottom) { inv in
                        InviteSheet(invite: inv)
                            .frame(width: 360, height: 480)
                    }
                    #endif
                    Button {
                        makingGuest = true
                    } label: {
                        Label("Guest link", image: Symbol.guest.name)
                    }
                    .help(Text("Guest link"))
                    #if os(macOS)
                    .popover(isPresented: $makingGuest, arrowEdge: .bottom) {
                        GuestLinkSheet(model: model)
                            .frame(width: 400, height: 460)
                    }
                    #endif
                }
                #if os(iOS)
                Button {
                    settings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                #endif
            }
        }
        .task(id: session.scope) {
            let m = preset ?? FamilyModel(session: session)
            model = m
            await m.load()
        }
        .refreshable { await model?.load() }
        #if os(iOS)
        .navigationDestination(item: $invite) { inv in InviteSheet(invite: inv) }
        .navigationDestination(isPresented: $settings) { SettingsView(model: model) }
        .navigationDestination(isPresented: $makingGuest) { GuestLinkSheet(model: model) }
        #endif
        .sheet(isPresented: $scanning) {
            NavigationStack { ScanView(asSheet: true) }
        }
    }

    /// Rows sit on `surface` in the phone's grouped list and on `ground` in the Mac's plain one.
    static var rowGround: Color {
        #if os(iOS)
        Tokens.surface
        #else
        Tokens.ground
        #endif
    }

    /// "Really remove?" in the row, for four seconds.
    private func armedPill(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button {
            arming = nil
            disarm?.cancel()
            action()
        } label: {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Tokens.onOut)
                .padding(.horizontal, Tokens.space2)
                .padding(.vertical, Tokens.space1)
                .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
        }
        .buttonStyle(.plain)
        .transition(.opacity)
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

extension View {
    /// Remove or Revoke behind a swipe and the long-press menu; the tap arms the row.
    @ViewBuilder
    func removable(_ on: Bool, title: LocalizedStringKey, arm: @escaping () -> Void) -> some View {
        if on {
            self
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(title, role: .destructive, action: arm)
                        .tint(Tokens.out)
                }
                .contextMenu {
                    Button(title, role: .destructive, action: arm)
                }
        } else {
            self
        }
    }
}

struct InviteSheet: View {
    var invite: Invite
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Tokens.space4) {
            if let url = invite.url {
                QRView(text: url)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .padding(Tokens.space5)
                    .background(Tokens.surfaceSunk, in: RoundedRectangle(cornerRadius: Tokens.radiusMD))
                ShareLink(item: url) {
                    Label("Share the invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(url)
                    .font(Tokens.mono(.footnote))
                    .foregroundStyle(Tokens.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, Tokens.space4)
                    .contextMenu {
                        Button("Copy") {
                            #if os(iOS)
                            UIPasteboard.general.string = url
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            #endif
                        }
                    }
            }
            Group {
                if invite.device == true {
                    Text("Valid once, for a day. It adds a device to you.")
                } else {
                    HStack(spacing: Tokens.space1) {
                        Text("Valid once, for 7 days, as")
                        Text(LocalizedStringKey(invite.role))
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(Tokens.inkMuted)
            Spacer()
        }
        .padding(Tokens.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.ground)
        .navigationTitle(invite.device == true ? "Add a device" : "Invite")
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
    }
}

struct GuestLinkSheet: View {
    var model: FamilyModel?
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var homes: Live<[HomeRow]>?
    @State private var lists: Live<[ListSummary]>?
    @State private var homeID = ""
    @State private var listID = ""
    @State private var label = ""
    @State private var made: GuestLink?

    var body: some View {
        Group {
            if let g = made, let url = g.url {
                VStack(spacing: Tokens.space4) {
                    QRView(text: url)
                        .frame(maxWidth: 320, maxHeight: 320)
                    ShareLink(item: url) {
                        Label("Share the guest link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Text(url)
                        .font(Tokens.mono(.footnote))
                        .foregroundStyle(Tokens.inkMuted)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(Tokens.space5)
            } else {
                Form {
                    Picker("Home", selection: $homeID) {
                        ForEach(homes?.value ?? []) { h in Text(h.name).tag(h.id) }
                    }
                    Picker("List", selection: $listID) {
                        ForEach((lists?.value ?? []).filter { !$0.isPersonal }) { l in Text(l.name).tag(l.id) }
                    }
                    TextField("Who it is for", text: $label)
                    Text("The guest sees what is missing at that home and that list, for 7 days.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                    ProblemLine(text: model?.problem)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Tokens.ground)
        .navigationTitle("Guest link")
        #if os(macOS)
        .onExitCommand { dismiss() }
        .safeAreaInset(edge: .bottom) {
            if made == nil {
                HStack {
                    Spacer()
                    Button("Make the link") {
                        Task { made = await model?.guestLink(homeID: homeID, listID: listID, label: label, days: 7) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(homeID.isEmpty || listID.isEmpty)
                }
                .padding(Tokens.space4)
            }
        }
        #else
        .toolbar {
            if made == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make the link") {
                        Task { made = await model?.guestLink(homeID: homeID, listID: listID, label: label, days: 7) }
                    }
                    .disabled(homeID.isEmpty || listID.isEmpty)
                }
            }
        }
        #endif
        .task(id: session.scope) {
            guard let scope = session.scope else { return }
            homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
            lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
            homeID = homes?.value.first?.id ?? ""
            listID = (lists?.value ?? []).first { $0.isDefault }?.id ?? lists?.value.first?.id ?? ""
        }
    }
}
