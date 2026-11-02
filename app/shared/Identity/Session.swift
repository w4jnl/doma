// Session is the app's root: the local store, the server context and this device's key, the
// households the person is in, the clock that stamps their events, and the syncer. Screens read
// and write through it. v1 holds one server context and refuses a second with a message.
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class Session {
    let store: DomaStore
    private(set) var context: ServerContext?
    private(set) var households: [HouseholdRow] = []
    private(set) var key: DeviceKey?
    private(set) var clock: HLCClock?
    private(set) var syncer: Syncer!
    /// The household the screens show; the first one until the person switches.
    var currentHouseholdID: String?

    /// The one used by the app process, for the push and background entry points.
    nonisolated(unsafe) static weak var current: Session?

    init(store: DomaStore) {
        self.store = store
        syncer = Syncer(store: store,
                        client: { [weak self] in self?.client },
                        scopes: { [weak self] in self?.scopes ?? [] },
                        clock: { [weak self] in self?.clock },
                        revoked: { [weak self] in self?.forgetServer() },
                        removed: { [weak self] in self?.householdRemoved($0) })
        reload()
        Session.current = self
    }

    /// The store at its default path; a fresh one in memory when that fails.
    static func live() -> Session {
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

    func reload() {
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
        if currentHouseholdID == nil || !households.contains(where: { $0.id == currentHouseholdID }) {
            currentHouseholdID = households.first?.id
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
        if context == nil {
            let c = ServerContext(serverID: ULID.make(), baseURL: server, credentialID: acc.credentialID, personID: acc.personID, displayName: name, createdAt: millis(Date()))
            try store.saveContext(c)
        }
        reload()
        guard let c = context else { return }
        try store.upsertHousehold(HouseholdRow(serverID: c.serverID, id: acc.household.id, name: acc.household.name, timezone: acc.household.timezone ?? "", stalenessDays: acc.household.stalenessDays, role: acc.role))
        reload()
        currentHouseholdID = acc.household.id
        await syncer.sync()
    }

    /// Refreshes the households and roles from the server.
    func refreshMemberships() async {
        guard let client, let c = context else { return }
        guard let me: MeDocument = try? await client.get("/api/v1/me") else { return }
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

    /// The APNs token, sent to the server for this credential.
    func registerPush(token: Data) async {
        guard let client, let c = context else { return }
        struct Body: Encodable { var token: String }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        do {
            let _: SyncClient.Empty = try await client.post("/api/v1/devices/\(c.credentialID)/apns", Body(token: hex))
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
