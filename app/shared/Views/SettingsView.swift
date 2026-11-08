// Settings: this device's name, the staleness for owners, the devices of this person with
// Revoke armed in place, and About with the server's name and the app's version.
import GRDB
import SwiftUI
#if os(iOS)
import UserNotifications
#endif

struct SettingsView: View {
    var model: FamilyModel?
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var staleness: Double = 14
    @State private var waiting: Live<Int>?

    /// The household in front's doma, as the syncer last found it.
    private var status: Syncer.ServerStatus {
        session.scope.map { session.syncer.status(for: $0.serverID) } ?? Syncer.ServerStatus()
    }
    @State private var homes: Live<[HomeRow]>?
    @State private var deviceInvite: Invite?
    @State private var makingDevice = false
    #if os(iOS)
    @State private var notifications: UNAuthorizationStatus?
    @State private var lists: Live<[ListSummary]>?
    @AppStorage("lock.biometrics") private var lockWithBiometrics = false
    @AppStorage("lock.after") private var lockAfter = LockAfter.immediately.rawValue
    @AppStorage(StrikeGuard.key) private var guardSeconds = StrikeGuard.defaultSeconds
    #endif

    private var isOwner: Bool { session.current?.isOwner ?? false }
    /// Phase 1 brings the Homes tab and with it the flags setting.
    static let homesArrived = true

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
            #if os(iOS)
            Section {
                LabeledContent("Notifications") {
                    switch notifications {
                    case .authorized, .provisional, .ephemeral:
                        Text("On")
                            .foregroundStyle(Tokens.inkMuted)
                    case .denied:
                        Button("Turn on in Settings") { openSystemSettings() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.accent)
                    case .notDetermined:
                        Button("Allow") {
                            PushDelegate.enable()
                            Task {
                                try? await Task.sleep(for: .seconds(1))
                                notifications = await PushDelegate.notificationsAllowed()
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.accent)
                    default:
                        EmptyView()
                    }
                }
                if let m = model, let me = m.devices.first(where: { $0.id == session.context?.credentialID }) {
                    // which lists are worth a word, and whether a clear is
                    ForEach((lists?.value ?? []).filter { !$0.isPersonal }) { l in
                        Toggle(isOn: Binding(
                            get: { !me.mutedLists.contains(l.id) },
                            set: { on in
                                var muted = Set(me.mutedLists)
                                if on { muted.remove(l.id) } else { muted.insert(l.id) }
                                Task { await m.setNotify(device: me.id, muted: Array(muted).sorted(), clears: me.notifyClears) }
                            })) {
                            HStack(spacing: Tokens.space3) {
                                ListDot(colour: l.colour)
                                    .frame(width: Tokens.space5)
                                Text(l.name)
                            }
                        }
                        .tint(Tokens.accent)
                    }
                    Toggle(isOn: Binding(
                        get: { me.notifyClears },
                        set: { on in Task { await m.setNotify(device: me.id, muted: me.mutedLists, clears: on) } })) {
                        Text("When a list is cleared")
                    }
                    .tint(Tokens.accent)
                }
            } header: {
                SectionHeader("Notifications")
            } footer: {
                Text("A word when someone else adds to a list or clears it, at most every two minutes. Never for what you did yourself.")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
            .listRowBackground(FamilyView.rowGround)
            .listRowSeparatorTint(Tokens.line)
            Section {
                Picker("Ignore taps after opening", selection: $guardSeconds) {
                    ForEach(StrikeGuard.choices, id: \.self) { choice in
                        Text(StrikeGuard.title(choice)).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .tint(Tokens.inkMuted)
            } header: {
                SectionHeader("Lists")
            } footer: {
                Text("A tap on a list in the first moment after doma comes to the front is ignored, so a pocket or a pickup strikes nothing.")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
            .listRowBackground(FamilyView.rowGround)
            .listRowSeparatorTint(Tokens.line)
            Section {
                Toggle(isOn: $lockWithBiometrics) {
                    Text("Lock with Face ID")
                }
                .tint(Tokens.accent)
                if lockWithBiometrics {
                    Picker("Lock after", selection: $lockAfter) {
                        ForEach(LockAfter.allCases) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Tokens.inkMuted)
                }
            } header: {
                SectionHeader("Privacy")
            } footer: {
                Text("Face ID, or the passcode, when you come back to doma after that long away.")
                    .font(.footnote)
                    .foregroundStyle(Tokens.inkMuted)
            }
            .listRowBackground(FamilyView.rowGround)
            .listRowSeparatorTint(Tokens.line)
            #endif
            if Self.homesArrived, isOwner, !(homes?.value ?? []).isEmpty {
                Section {
                    Stepper(value: $staleness, in: 14...365, step: 1) {
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
                if let at = status.lastSyncedAt ?? session.syncer.lastSyncedAt {
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
                // this doma's word; the one line every doma shares is the missing key
                ProblemLine(text: status.lastError ?? (session.key == nil ? session.syncer.lastError : nil))
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
        .onChange(of: session.current?.stalenessDays) { _, v in
            // the refresh from doma may land while this screen is open
            staleness = Double(v ?? Int64(Staleness.defaultDays))
        }
        .onAppear {
            staleness = Double(session.current?.stalenessDays ?? Int64(Staleness.defaultDays))
            #if os(iOS)
            Task { notifications = await PushDelegate.notificationsAllowed() }
            #endif
            #if os(macOS)
            if let m = model, m.devices.isEmpty { Task { await m.load() } }
            #endif
        }
        .task(id: session.context?.serverID) {
            if let scope = session.scope {
                homes = Live(session.store, initial: []) { db in try Queries.homes(db, scope) }
                #if os(iOS)
                lists = Live(session.store, initial: []) { db in try Queries.lists(db, scope) }
                #endif
            }
            guard let server = session.context?.serverID else { return }
            waiting = Live(session.store, initial: 0) { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE server_id = ?", arguments: [server]) ?? 0
            }
        }
    }
}

#if os(iOS)
extension SettingsView {
    /// The system's page for this app, where notifications are turned on or off.
    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
#endif
