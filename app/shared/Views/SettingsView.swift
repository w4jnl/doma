// Settings: this device's name, the staleness for owners, the devices of this person with
// Revoke armed in place, and About with the server's name and the app's version.
import GRDB
import SwiftUI

struct SettingsView: View {
    var model: FamilyModel?
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var staleness: Double = 14
    @State private var waiting: Live<Int>?
    @State private var homes: Live<[HomeRow]>?
    @State private var deviceInvite: Invite?
    @State private var makingDevice = false

    private var isOwner: Bool { session.current?.isOwner ?? false }

    var body: some View {
        List {
            Section {
                LabeledContent("Name") {
                    Text(model?.devices.first { $0.id == session.context?.credentialID }?.label ?? Session.deviceLabel)
                }
                if let c = session.context {
                    LabeledContent("You") { Text(c.displayName) }
                }
            } header: {
                SectionHeader("This device")
            }
            .listRowBackground(FamilyView.rowGround)
            .listRowSeparatorTint(Tokens.line)
            if isOwner, !(homes?.value ?? []).isEmpty {
                Section {
                    Stepper(value: $staleness, in: 1...365, step: 1) {
                        LabeledContent("Ask again after") {
                            Text("\(Int(staleness)) days")
                                .font(Tokens.mono(.body))
                        }
                    }
                    .onChange(of: staleness) { _, v in
                        Task { await model?.setStaleness(days: Int64(v)) }
                    }
                } header: {
                    SectionHeader("Flags")
                } footer: {
                    Text("A flag older than this shows as unknown, and the home screen asks whether it is still there.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                }
                .listRowBackground(FamilyView.rowGround)
                .listRowSeparatorTint(Tokens.line)
            }
            if let m = model {
                Section {
                    ForEach(m.devices) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.label.isEmpty ? d.platform : d.label)
                                if let last = d.lastUsedAt {
                                    HStack(spacing: Tokens.space1) {
                                        Text("last seen")
                                            .font(.footnote)
                                            .foregroundStyle(Tokens.inkMuted)
                                        RelativeText(millis: last)
                                    }
                                }
                            }
                            Spacer()
                            if d.id != session.context?.credentialID {
                                ArmedButton(title: "Revoke", armedTitle: "Really revoke?") {
                                    Task { await m.revoke(device: d.id) }
                                }
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Tokens.accent)
                                    .accessibilityLabel(Text("this device"))
                            }
                        }
                    }
                    Button {
                        guard !makingDevice else { return }
                        makingDevice = true
                        Task {
                            deviceInvite = await m.deviceInvite()
                            makingDevice = false
                        }
                    } label: {
                        Label("Add a device", systemImage: "plus")
                            .foregroundStyle(Tokens.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(makingDevice)
                    .accessibilityIdentifier("add-device")
                } header: {
                    SectionHeader("Your devices")
                } footer: {
                    Text("Show the code to your Mac or your new phone; it joins as you.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                }
                .listRowBackground(FamilyView.rowGround)
                .listRowSeparatorTint(Tokens.line)
            }
            if let m = model, !session.syncer.rejected.isEmpty {
                Section {
                    ForEach(Array(session.syncer.rejected.enumerated()), id: \.offset) { _, r in
                        Text(r.reason)
                            .font(.footnote)
                            .foregroundStyle(Tokens.inkMuted)
                    }
                } header: {
                    SectionHeader("Not accepted")
                }
                .listRowBackground(FamilyView.rowGround)
                .listRowSeparatorTint(Tokens.line)
                .onAppear { _ = m }
            }
            Section {
                // the one place the wordmark appears in the app
                HStack(spacing: Tokens.space3) {
                    Mark(size: 22)
                    Text(verbatim: "doma")
                        .font(Tokens.mono(.body, bold: true))
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    Text(AppInfo.version)
                        .font(Tokens.mono(.subheadline))
                        .foregroundStyle(Tokens.inkMuted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("doma, version \(AppInfo.version)"))
                LabeledContent("Family's doma") {
                    Text(session.context?.baseURL.host ?? "")
                        .font(Tokens.mono(.body))
                }
                if let at = session.syncer.lastSyncedAt {
                    LabeledContent("Last refreshed") {
                        RelativeText(millis: millis(at))
                    }
                }
                if let n = waiting?.value, n > 0 {
                    LabeledContent("Waiting to go up") {
                        Text(verbatim: String(n))
                            .font(Tokens.mono(.body))
                    }
                    .accessibilityIdentifier("waiting")
                }
                ProblemLine(text: session.syncer.lastError)
            } header: {
                SectionHeader("About")
            }
            .listRowBackground(FamilyView.rowGround)
            .listRowSeparatorTint(Tokens.line)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        // the Settings window: the Mac's grouped form, 480 wide
        .listStyle(.inset)
        .frame(width: 480, height: 560)
        #endif
        .textCase(nil)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle("Settings")
        .navigationDestination(item: $deviceInvite) { inv in
            InviteSheet(invite: inv)
        }
        .onAppear {
            staleness = Double(session.current?.stalenessDays ?? 14)
            #if os(macOS)
            if let m = model, m.devices.isEmpty { Task { await m.load() } }
            #endif
        }
        .task(id: session.context?.serverID) {
            if let scope = session.scope {
                homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
            }
            guard let server = session.context?.serverID else { return }
            waiting = Live(session.store, initial: 0) { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE server_id = ?", arguments: [server]) ?? 0
            }
        }
    }
}
