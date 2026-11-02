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

    private var isOwner: Bool { session.current?.isOwner ?? false }

    var body: some View {
        Form {
            Section("This device") {
                LabeledContent("Name") {
                    Text(model?.devices.first { $0.id == session.context?.credentialID }?.label ?? Session.deviceLabel)
                        .font(Tokens.mono(.body))
                }
                if let c = session.context {
                    LabeledContent("You") { Text(c.displayName) }
                }
            }
            if isOwner {
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
                    Text("A flag older than this shows as unknown, and the home screen asks whether it is still there.")
                        .font(.footnote)
                        .foregroundStyle(Tokens.inkMuted)
                } header: {
                    Text("Flags")
                }
            }
            if let m = model, m.devices.count > 1 {
                Section("Your devices") {
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
                                Text("this one")
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.inkMuted)
                            }
                        }
                    }
                }
            }
            if let m = model, !session.syncer.rejected.isEmpty {
                Section("Not accepted") {
                    ForEach(Array(session.syncer.rejected.enumerated()), id: \.offset) { _, r in
                        Text(r.reason)
                            .font(.footnote)
                            .foregroundStyle(Tokens.inkMuted)
                    }
                }
                .onAppear { _ = m }
            }
            Section("About") {
                LabeledContent("Family's doma") {
                    Text(session.context?.baseURL.host ?? "")
                        .font(Tokens.mono(.body))
                }
                LabeledContent("Version") {
                    Text(AppInfo.version)
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
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            staleness = Double(session.current?.stalenessDays ?? 14)
        }
        .task(id: session.context?.serverID) {
            guard let server = session.context?.serverID else { return }
            waiting = Live(session.store, initial: 0) { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE server_id = ?", arguments: [server]) ?? 0
            }
        }
    }
}
