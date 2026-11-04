// Session is the app's root: the local store, the families' domas this device belongs to and
// its one key, the households the person is in on each, the clocks that stamp their events, and
// the syncer. Screens read and write through it. A second family's doma is a second context:
// the same device key, its own credential, households and cursors; nothing about servers shows
// until there is more than one.
import Foundation
import Observation
#if os(iOS)
import UIKit
import UserNotifications
#endif

@MainActor @Observable
final class Session {
    let store: DomaStore
    /// Every family's doma this device belongs to, oldest first.
    private(set) var contexts: [ServerContext] = []
    /// The households on all of them, in their servers' order.
    private(set) var households: [HouseholdRow] = []
    private(set) var key: DeviceKey?
    /// One clock per server; its device id is this device's credential there.
    private var clocks: [String: HLCClock] = [:]
    private(set) var syncer: Syncer!
    /// The household the screens show: the one last shown on this device, the first one until
    /// the person switches.
    private(set) var currentRef: HouseholdRef?
    /// The family's names by server and person id, from the members the Family screen and the
    /// membership refresh bring; held in memory, never stored. A struck row names who got it.
    private(set) var names: [String: [String: String]] = [:]
    /// Per list, the stamp of the newest entry this device had in front, keyed
    /// server/household/list: what others added after it is unseen, and counts on the icon and
    /// in the overview. Kept on the device only, one dictionary per server.
    private(set) var seen: [String: String] = [:]
    /// The one mic, for the list in front: speech to words on the device, never sent anywhere.
    @ObservationIgnored let dictation = Listener()

    /// The one used by the app process, for the push and background entry points.
    nonisolated(unsafe) static weak var current: Session?

    /// A household on one server.
    struct HouseholdRef: Hashable {
        var serverID: String
        var householdID: String
        var key: String { serverID + "/" + householdID }
    }

    init(store: DomaStore) {
        self.store = store
        syncer = Syncer(store: store,
                        servers: { [weak self] in self?.servers ?? [] },
                        revoked: { [weak self] in self?.forgetServer($0) },
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
        households.first { $0.ref == currentRef } ?? households.first
    }

    /// The current household's id, for the keys screens remember things under.
    var currentHouseholdID: String? { current?.id }

    /// The current household's doma; the first one while there is no household.
    var context: ServerContext? {
        current.flatMap { context(for: $0.serverID) } ?? contexts.first
    }

    func context(for serverID: String) -> ServerContext? {
        contexts.first { $0.serverID == serverID }
    }

    /// The clock that stamps the current household's events.
    var clock: HLCClock? { context.flatMap { clocks[$0.serverID] } }

    var scope: Scope? {
        guard let h = current, let c = context(for: h.serverID) else { return nil }
        return Scope(serverID: c.serverID, householdID: h.id, personID: c.personID)
    }

    /// Every household on every server.
    var scopes: [Scope] {
        households.compactMap { h in context(for: h.serverID).map { Scope(serverID: $0.serverID, householdID: h.id, personID: $0.personID) } }
    }

    /// The client of the current household's doma.
    var client: SyncClient? { context.flatMap(client(for:)) }

    func client(for c: ServerContext) -> SyncClient? {
        guard let key else { return nil }
        return SyncClient(baseURL: c.baseURL, key: key, credentialID: c.credentialID)
    }

    /// What the syncer talks to, one per server; clients that reach nothing while a UI test
    /// holds sync back.
    var servers: [Syncer.Server] {
        contexts.compactMap { c in
            guard var client = client(for: c), let clock = clocks[c.serverID] else { return nil }
            if UITestHooks.enabled, UITestHooks.blockSync {
                client.baseURL = URL(string: "http://127.0.0.1:9")!
            }
            return Syncer.Server(serverID: c.serverID, client: client, clock: clock, scopes: scopes.filter { $0.serverID == c.serverID })
        }
    }

    /// Shows a household.
    func select(_ h: HouseholdRow) {
        currentRef = h.ref
        if !UITestHooks.testing {
            UserDefaults.standard.set(h.ref.key, forKey: "household.current")
        }
    }

    func reload() {
        defer { loadSeen() }
        key = DeviceKey.load()
        var kept: [ServerContext] = []
        var all: [HouseholdRow] = []
        for c in (try? store.contexts()) ?? [] {
            let hs = (try? store.households(serverID: c.serverID)) ?? []
            if hs.isEmpty {
                // the last household there is gone: the server goes with it, the key stays
                try? store.wipe(serverID: c.serverID)
                continue
            }
            kept.append(c)
            all += hs
            if clocks[c.serverID]?.device != c.credentialID {
                clocks[c.serverID] = HLCClock(device: c.credentialID)
            }
        }
        contexts = kept
        households = all
        clocks = clocks.filter { id, _ in kept.contains { $0.serverID == id } }
        if !contexts.isEmpty, key == nil, !(UITestHooks.testing && !UITestHooks.enabled) {
            // the store knows the family but the key is gone: nothing can be signed, and the
            // screens must say so rather than look fine and never sync
            syncer.noteMissingKey()
        }
        if currentRef == nil || !households.contains(where: { $0.ref == currentRef }) {
            let remembered = UITestHooks.testing ? nil : rememberedRef()
            currentRef = households.first { $0.ref == remembered }?.ref ?? households.first?.ref
        }
    }

    /// The household last shown, from this device's defaults; the one-server key of earlier
    /// builds counts for the first server.
    private func rememberedRef() -> HouseholdRef? {
        if let s = UserDefaults.standard.string(forKey: "household.current"), let i = s.firstIndex(of: "/") {
            return HouseholdRef(serverID: String(s[..<i]), householdID: String(s[s.index(after: i)...]))
        }
        if let c = contexts.first, let h = UserDefaults.standard.string(forKey: "household.current." + c.serverID) {
            return HouseholdRef(serverID: c.serverID, householdID: h)
        }
        return nil
    }

    // MARK: Invites

    enum AcceptError: Error, LocalizedError {
        case notAnInvite
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notAnInvite: String(localized: "That is not an invite. Ask for the link or the code again.")
            case .server(let s): s
            }
        }
    }

    /// The doma an invite is for, when the device already belongs to it: the link's address, or
    /// the current household's doma for a bare code.
    func context(for link: InviteLink) -> ServerContext? {
        if let s = link.server {
            return contexts.first { $0.baseURL.host == s.host && $0.baseURL.port == s.port }
        }
        return context
    }

    /// Whether joining with this text needs the person's name: on the first join, and on the
    /// first join to another family's doma.
    func needsName(for text: String) -> Bool {
        guard let link = InviteLink(text) else { return contexts.isEmpty }
        return context(for: link)?.displayName.isEmpty ?? true
    }

    /// Accepts an invite: makes the device key if needed, registers this device, stores the
    /// context and the household, and syncs. A link to a doma this device does not know yet
    /// makes a new context, with the same key and its own credential there.
    func accept(_ text: String, displayName: String) async throws {
        guard let link = InviteLink(text) else { throw AcceptError.notAnInvite }
        let known = context(for: link)
        guard let server = known?.baseURL ?? link.server else { throw AcceptError.notAnInvite }
        let key = try self.key ?? DeviceKey.loadOrMake()
        self.key = key
        let client = SyncClient(baseURL: server, key: key, credentialID: known?.credentialID)
        let typed = displayName.trimmingCharacters(in: .whitespaces)
        let name = known?.displayName.isEmpty == false ? known!.displayName : (typed.isEmpty ? (contexts.first?.displayName ?? "") : typed)
        let acc: Accepted
        do {
            acc = try await client.accept(token: link.token, displayName: name, label: Self.deviceLabel, platform: Self.platform)
        } catch let e as ClientError {
            if case .problem(let p) = e { throw AcceptError.server(p.message) }
            if case .transport(let s) = e { throw AcceptError.server(String(localized: "Could not reach the family's doma.") + " " + s) }
            throw AcceptError.server(String(localized: "Could not accept the invite."))
        }
        let told = acc.displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        let serverID: String
        if let c = known {
            serverID = c.serverID
            // a device that joined again with a new key: the context follows the credential
            if c.credentialID != acc.credentialID || c.personID != acc.personID {
                try store.saveContext(ServerContext(serverID: c.serverID, baseURL: c.baseURL, credentialID: acc.credentialID, personID: acc.personID, displayName: told.isEmpty ? c.displayName : told, createdAt: c.createdAt))
            }
        } else {
            serverID = ULID.make()
            try store.saveContext(ServerContext(serverID: serverID, baseURL: server, credentialID: acc.credentialID, personID: acc.personID, displayName: told.isEmpty ? name : told, createdAt: millis(Date())))
        }
        let h = HouseholdRow(serverID: serverID, id: acc.household.id, name: acc.household.name, timezone: acc.household.timezone ?? "", stalenessDays: acc.household.stalenessDays, role: acc.role)
        try store.upsertHousehold(h)
        reload()
        select(h)
        await syncer.sync()
        await refreshMemberships()
    }

    // MARK: Seen

    private func loadSeen() {
        // under a test the marks stay in memory, so every run starts unseen and pictures agree
        guard !UITestHooks.testing else { return }
        var all: [String: String] = [:]
        for c in contexts {
            for (k, v) in UserDefaults.standard.dictionary(forKey: "seen." + c.serverID) as? [String: String] ?? [:] {
                all[c.serverID + "/" + k] = v
            }
        }
        seen = all
    }

    private func seenKey(_ household: String, _ list: String) -> String {
        (scope?.serverID ?? "") + "/" + household + "/" + list
    }

    /// The list was in front with entries up to this stamp.
    func markSeen(household: String, list: String, upTo stamp: String) {
        let key = seenKey(household, list)
        if let have = seen[key], have >= stamp { return }
        seen[key] = stamp
        if !UITestHooks.testing, let server = scope?.serverID {
            let prefix = server + "/"
            var mine: [String: String] = [:]
            for (k, v) in seen where k.hasPrefix(prefix) { mine[String(k.dropFirst(prefix.count))] = v }
            UserDefaults.standard.set(mine, forKey: "seen." + server)
        }
    }

    /// The stamp a list was last seen up to, or nothing.
    func seenMark(household: String, list: String) -> String? {
        seen[seenKey(household, list)]
    }

    /// Whether an entry is unseen here: someone else added it after the list's seen mark.
    func isUnseen(household: String, list: String, addedHLC: String, addedBy: String) -> Bool {
        guard addedBy != context?.personID else { return false }
        guard let mark = seen[seenKey(household, list)] else { return true }
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
        guard let personID, let c = context, personID != c.personID, let known = names[c.serverID], known.count > 1 else { return nil }
        return known[personID]
    }

    /// Takes the names a members answer carried, for the current household's doma unless a
    /// server is named.
    func learn(names new: [String: String], server: String? = nil) {
        guard let server = server ?? context?.serverID else { return }
        for (id, name) in new where !name.isEmpty { names[server, default: [:]][id] = name }
    }

    /// Refreshes the households and roles from every server, and the families' names with them.
    func refreshMemberships() async {
        struct Members: Decodable { var members: [Member]? }
        for c in contexts {
            guard let client = client(for: c), let me: MeDocument = try? await client.get("/api/v1/me") else { continue }
            for m in me.memberships {
                if let doc: Members = try? await client.get("/api/v1/h/\(m.householdID)/members") {
                    learn(names: Dictionary((doc.members ?? []).map { ($0.personID, $0.displayName) }, uniquingKeysWith: { a, _ in a }), server: c.serverID)
                }
            }
            let known = Set(me.memberships.map(\.householdID))
            for h in households where h.serverID == c.serverID && !known.contains(h.id) {
                try? store.removeHousehold(Scope(serverID: c.serverID, householdID: h.id, personID: c.personID))
            }
            for m in me.memberships {
                let old = households.first { $0.serverID == c.serverID && $0.id == m.householdID }
                try? store.upsertHousehold(HouseholdRow(serverID: c.serverID, id: m.householdID, name: m.householdName, timezone: old?.timezone ?? "", stalenessDays: old?.stalenessDays, role: m.role))
            }
        }
        reload()
    }

    /// Leaves a server, the current household's unless named: the device key stays for a
    /// fresh invite.
    func forgetServer(_ serverID: String? = nil) {
        if let id = serverID ?? context?.serverID {
            try? store.wipe(serverID: id)
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

    /// The APNs token, sent to every server for this device's credential there, with which of
    /// Apple's gateways it belongs to: a build from Xcode registers a development token.
    func registerPush(token: Data) async {
        struct Body: Encodable { var token: String, sandbox: Bool }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        for c in contexts {
            guard let client = client(for: c) else { continue }
            do {
                let _: SyncClient.Empty = try await client.post("/api/v1/devices/\(c.credentialID)/apns", Body(token: hex, sandbox: sandbox))
            } catch {
                // the next launch registers again
            }
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
