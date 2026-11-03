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
                            if let seen = member.lastSeenAt {
                                RelativeText(millis: seen)
                            }
                            if isOwner, member.personID != session.context?.personID {
                                ArmedButton(title: "Remove", armedTitle: "Really remove?") {
                                    Task { await m.remove(member: member.personID) }
                                }
                            }
                        }
                        .rowHeight()
                        .listRowBackground(Tokens.ground)
                        .listRowSeparatorTint(Tokens.line)
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
                                Text("expires")
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.inkMuted)
                                RelativeText(millis: inv.expiresAt)
                                ArmedButton(title: "Revoke", armedTitle: "Really revoke?") {
                                    Task { await m.revokeInvite(inv.id) }
                                }
                            }
                            .rowHeight()
                            .listRowBackground(Tokens.ground)
                            .listRowSeparatorTint(Tokens.line)
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
                                Text("expires")
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.inkMuted)
                                RelativeText(millis: g.expiresAt)
                                if let url = g.url {
                                    ShareLink(item: url) {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                    .accessibilityLabel(Text("Share the guest link"))
                                }
                                ArmedButton(title: "Revoke", armedTitle: "Really revoke?") {
                                    Task { await m.revokeGuest(g.id) }
                                }
                            }
                            .rowHeight()
                            .listRowBackground(Tokens.ground)
                            .listRowSeparatorTint(Tokens.line)
                        }
                    } header: {
                        SectionHeader("Guest links")
                    }
                }
                Section {
                    Button("Join another household") { scanning = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.accent)
                        .listRowBackground(Tokens.ground)
                    ArmedButton(title: "Leave this household", armedTitle: "Really leave?") {
                        Task { _ = await m.leave() }
                    }
                    .listRowBackground(Tokens.ground)
                }
                if let p = m.problem {
                    Section {
                        ProblemLine(text: p)
                            .listRowBackground(Tokens.ground)
                    }
                }
            }
        }
        .listStyle(.plain)
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
                    Menu {
                        Button("Invite a member") { Task { invite = await model?.invite(role: "member") } }
                        Button("Invite an owner") { Task { invite = await model?.invite(role: "owner") } }
                    } label: {
                        Label("Invite", systemImage: "qrcode")
                            .labelStyle(.titleOnly)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        makingGuest = true
                    } label: {
                        Label("Guest link", image: Symbol.guest.name)
                            .labelStyle(.titleOnly)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    settings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .task(id: session.scope) {
            let m = preset ?? FamilyModel(session: session)
            model = m
            await m.load()
        }
        .refreshable { await model?.load() }
        .sheet(item: $invite) { inv in
            NavigationStack { InviteSheet(invite: inv) }
        }
        .sheet(isPresented: $makingGuest) {
            NavigationStack { GuestLinkSheet(model: model) }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack { ScanView(asSheet: true) }
        }
        .sheet(isPresented: $settings) {
            NavigationStack { SettingsView(model: model) }
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
                    .frame(maxWidth: 320, maxHeight: 320)
                ShareLink(item: url) {
                    Label("Share the invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Text(url)
                    .font(Tokens.mono(.footnote))
                    .foregroundStyle(Tokens.inkMuted)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.space4)
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(made == nil ? "Cancel" : "Done") { dismiss() }
            }
            if made == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make the link") {
                        Task { made = await model?.guestLink(homeID: homeID, listID: listID, label: label, days: 7) }
                    }
                    .disabled(homeID.isEmpty || listID.isEmpty)
                }
            }
        }
        .task(id: session.scope) {
            guard let scope = session.scope else { return }
            homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
            lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
            homeID = homes?.value.first?.id ?? ""
            listID = (lists?.value ?? []).first { $0.isDefault }?.id ?? lists?.value.first?.id ?? ""
        }
    }
}
