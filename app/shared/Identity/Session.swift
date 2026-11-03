// Session is the app's root: the local store, the server context and this device's key, the
// households the person is in, the clock that stamps their events, and the syncer. Screens read
// and write through it. v1 holds one server context and refuses a second with a message.
import Foundation
import Observation
#if os(iOS)
import UIKit
import UserNotifications
#endif

@MainActor @Observable
final class Session {
    let store: DomaStore
    private(set) var context: ServerContext?
    private(set) var households: [HouseholdRow] = []
    private(set) var key: DeviceKey?
    private(set) var clock: HLCClock?
    private(set) var syncer: Syncer!
    /// The household the screens show: the one last shown on this device, the first one until
    /// the person switches.
    var currentHouseholdID: String? {
        didSet {
            guard let id = currentHouseholdID, let c = context else { return }
            UserDefaults.standard.set(id, forKey: "household.current." + c.serverID)
        }
    }
    /// The family's names by person id, from the members the Family screen and the membership
    /// refresh bring; held in memory, never stored. A struck row names who got it from these.
    private(set) var names: [String: String] = [:]
    /// Per list, the stamp of the newest entry this device had in front: what others added after
    /// it is unseen, and counts on the icon and in the overview. Kept on the device only.
    private(set) var seen: [String: String] = [:]

    /// The one used by the app process, for the push and background entry points.
    nonisolated(unsafe) static weak var current: Session?

    init(store: DomaStore) {
        self.store = store
        syncer = Syncer(store: store,
                        client: { [weak self] in self?.syncClient },
                        scopes: { [weak self] in self?.scopes ?? [] },
                        clock: { [weak self] in self?.clock },
                        revoked: { [weak self] in self?.forgetServer() },
                        removed: { [weak self] in self?.householdRemoved($0) })
        reload()
        Session.current = self
    }

    /// The store at its default path; a fresh one in memory when that fails, and under a UI
    /// test, which may also join an invite at launch.
    static func live() -> Session {
        if UITestHooks.enabled {
            // every launch is a new device: the key of the last one would make it the same person
            DeviceKey.forget()
            let s = Session(store: try! DomaStore.inMemory())
            if let url = UITestHooks.joinURL {
                Task {
                    try? await s.accept(url, displayName: UITestHooks.joinName)
                    let away = UITestHooks.offlineSeconds
                    if away > 0 {
                        UITestHooks.blockSync = true
                        try? await Task.sleep(for: .seconds(away))
                        UITestHooks.blockSync = false
                        await s.syncer.sync()
                    }
                }
            }
            return s
        }
        if let path = try? DomaStore.defaultPath(), let store = try? DomaStore(path: path) {
            return Session(store: store)
        }
        return Session(store: try! DomaStore.inMemory())
    }

    var hasHousehold: Bool { !households.isEmpty }

    var current: HouseholdRow? {
        households.first { $0.id == currentHouseholdID } ?? households.first
    }

    var scope: Scope? {
        guard let c = context, let h = current else { return nil }
        return Scope(serverID: c.serverID, householdID: h.id, personID: c.personID)
    }

    var scopes: [Scope] {
        guard let c = context else { return [] }
        return households.map { Scope(serverID: c.serverID, householdID: $0.id, personID: c.personID) }
    }

    var client: SyncClient? {
        guard let c = context, let key else { return nil }
        return SyncClient(baseURL: c.baseURL, key: key, credentialID: c.credentialID)
    }

    /// The syncer's client: the same, or one that reaches nothing while a UI test holds sync back.
    var syncClient: SyncClient? {
        guard var c = client else { return nil }
        if UITestHooks.enabled, UITestHooks.blockSync {
            c.baseURL = URL(string: "http://127.0.0.1:9")!
        }
        return c
    }

    func reload() {
        defer { loadSeen() }
        context = try? store.context()
        key = DeviceKey.load()
        if let c = context {
            households = (try? store.households(serverID: c.serverID)) ?? []
            if clock?.device != c.credentialID {
                clock = HLCClock(device: c.credentialID)
            }
        } else {
            households = []
            clock = nil
        }
        if context != nil, key == nil, !(UITestHooks.testing && !UITestHooks.enabled) {
            // the store knows the family but the key is gone: nothing can be signed, and the
            // screens must say so rather than look fine and never sync
            syncer.noteMissingKey()
        }
        if currentHouseholdID == nil || !households.contains(where: { $0.id == currentHouseholdID }) {
            let remembered = UITestHooks.testing ? nil : context.flatMap { UserDefaults.standard.string(forKey: "household.current." + $0.serverID) }
            currentHouseholdID = households.first { $0.id == remembered }?.id ?? households.first?.id
        }
    }

    // MARK: Invites

    enum AcceptError: Error, LocalizedError {
        case notAnInvite
        case anotherServer
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notAnInvite: "That is not an invite. Ask for the link or the code again."
            case .anotherServer: "This invite is for another family's doma. This app can join one at a time."
            case .server(let s): s
            }
        }
    }

    /// Accepts an invite: makes the device key if needed, registers this device, stores the
    /// context and the household, and syncs. The display name is asked on the first join only.
    func accept(_ text: String, displayName: String) async throws {
        guard let link = InviteLink(text) else { throw AcceptError.notAnInvite }
        let server: URL
        if let c = context {
            if let s = link.server, s.host != c.baseURL.host || s.port != c.baseURL.port { throw AcceptError.anotherServer }
            server = c.baseURL
        } else if let s = link.server {
            server = s
        } else {
            throw AcceptError.notAnInvite
        }
        let key = try self.key ?? DeviceKey.loadOrMake()
        self.key = key
        let client = SyncClient(baseURL: server, key: key, credentialID: context?.credentialID)
        let name = context?.displayName.isEmpty == false ? context!.displayName : displayName
        let acc: Accepted
        do {
            acc = try await client.accept(token: link.token, displayName: name, label: Self.deviceLabel, platform: Self.platform)
        } catch let e as ClientError {
            if case .problem(let p) = e { throw AcceptError.server(p.message) }
            if case .transport(let s) = e { throw AcceptError.server("Could not reach the family's doma. " + s) }
            throw AcceptError.server("Could not accept the invite.")
        }
        let known = acc.displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        if let c = context {
            // a device that joined again with a new key: the context follows the credential
            if c.credentialID != acc.credentialID || c.personID != acc.personID {
                try store.saveContext(ServerContext(serverID: c.serverID, baseURL: c.baseURL, credentialID: acc.credentialID, personID: acc.personID, displayName: known.isEmpty ? c.displayName : known, createdAt: c.createdAt))
            }
        } else {
            let c = ServerContext(serverID: ULID.make(), baseURL: server, credentialID: acc.credentialID, personID: acc.personID, displayName: known.isEmpty ? name : known, createdAt: millis(Date()))
            try store.saveContext(c)
        }
        reload()
        guard let c = context else { return }
        try store.upsertHousehold(HouseholdRow(serverID: c.serverID, id: acc.household.id, name: acc.household.name, timezone: acc.household.timezone ?? "", stalenessDays: acc.household.stalenessDays, role: acc.role))
        reload()
        currentHouseholdID = acc.household.id
        await syncer.sync()
        await refreshMemberships()
    }

    // MARK: Seen

    private var seenKey: String { "seen." + (context?.serverID ?? "") }

    private func loadSeen() {
        // under a test the marks stay in memory, so every run starts unseen and pictures agree
        guard !UITestHooks.testing else { return }
        seen = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String] ?? [:]
    }

    /// The list was in front with entries up to this stamp.
    func markSeen(household: String, list: String, upTo stamp: String) {
        let key = household + "/" + list
        if let have = seen[key], have >= stamp { return }
        seen[key] = stamp
        if !UITestHooks.testing {
            UserDefaults.standard.set(seen, forKey: seenKey)
        }
    }

    /// The stamp a list was last seen up to, or nothing.
    func seenMark(household: String, list: String) -> String? {
        seen[household + "/" + list]
    }

    /// Whether an entry is unseen here: someone else added it after the list's seen mark.
    func isUnseen(household: String, list: String, addedHLC: String, addedBy: String) -> Bool {
        guard addedBy != context?.personID else { return false }
        guard let mark = seen[household + "/" + list] else { return true }
        return addedHLC > mark
    }

    /// What this device has not seen in the current household, counted from the store; and
    /// on the phone the icon's badge, set here so a sync in the background sets it as well,
    /// where no screen updates.
    @discardableResult
    func refreshBadge() -> Int {
        guard let scope, let h = currentHouseholdID else { return 0 }
        let marks = (try? store.db.read { db in try Queries.openMarks(db, scope) }) ?? []
        let n = unseen(household: h, in: marks).values.reduce(0, +)
        #if os(iOS)
        UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
        #endif
        return n
    }

    /// Unseen entries per list over the household's open marks.
    func unseen(household: String, in marks: [OpenMark]) -> [String: Int] {
        var out: [String: Int] = [:]
        for m in marks where isUnseen(household: household, list: m.listID, addedHLC: m.addedHLC, addedBy: m.addedBy) {
            out[m.listID, default: 0] += 1
        }
        return out
    }

    /// The name for a person id when it is someone else in a household of more than one;
    /// nil for yourself, for an unknown id and for a household of one.
    func name(of personID: String?) -> String? {
        guard let personID, personID != context?.personID, names.count > 1 else { return nil }
        return names[personID]
    }

    /// Takes the names a members answer carried.
    func learn(names new: [String: String]) {
        for (id, name) in new where !name.isEmpty { names[id] = name }
    }

    /// Refreshes the households and roles from the server, and the family's names with them.
    func refreshMemberships() async {
        guard let client, let c = context else { return }
        guard let me: MeDocument = try? await client.get("/api/v1/me") else { return }
        struct Members: Decodable { var members: [Member]? }
        for m in me.memberships {
            if let doc: Members = try? await client.get("/api/v1/h/\(m.householdID)/members") {
                learn(names: Dictionary((doc.members ?? []).map { ($0.personID, $0.displayName) }, uniquingKeysWith: { a, _ in a }))
            }
        }
        let known = Set(me.memberships.map(\.householdID))
        for h in households where !known.contains(h.id) {
            try? store.removeHousehold(Scope(serverID: c.serverID, householdID: h.id, personID: c.personID))
        }
        for m in me.memberships {
            let old = households.first { $0.id == m.householdID }
            try? store.upsertHousehold(HouseholdRow(serverID: c.serverID, id: m.householdID, name: m.householdName, timezone: old?.timezone ?? "", stalenessDays: old?.stalenessDays, role: m.role))
        }
        reload()
    }

    /// Leaves the server: the device key stays for a fresh invite.
    func forgetServer() {
        if let c = context {
            try? store.wipe(serverID: c.serverID)
        }
        reload()
    }

    private func householdRemoved(_ scope: Scope) {
        reload()
    }

    // MARK: Events

    /// Writes one event of this person into the current household and kicks the syncer.
    @discardableResult
    func record(_ kind: String, _ payload: some Encodable, id: String = ULID.make()) throws -> Event? {
        guard let scope, let clock else { return nil }
        let e = try store.record(kind, payload, scope: scope, clock: clock, id: id)
        syncer.kick()
        return e
    }

    /// Several events in one transaction, as "item.named then entry.added" from one tap.
    func record(_ build: (inout [Event], HLCClock, String) -> Void) throws {
        guard let scope, let clock else { return }
        try store.record(scope: scope, clock: clock) { events in build(&events, clock, scope.personID) }
        syncer.kick()
    }

    // MARK: Push

    /// The APNs token, sent to the server for this credential, with which of Apple's gateways
    /// it belongs to: a build from Xcode registers a development token.
    func registerPush(token: Data) async {
        guard let client, let c = context else { return }
        struct Body: Encodable { var token: String, sandbox: Bool }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        do {
            let _: SyncClient.Empty = try await client.post("/api/v1/devices/\(c.credentialID)/apns", Body(token: hex, sandbox: sandbox))
        } catch {
            // the next launch registers again
        }
    }

    static var platform: String {
        #if os(iOS)
        "ios"
        #else
        "macos"
        #endif
    }

    static var deviceLabel: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}
