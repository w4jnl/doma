// The Family screen's side of the REST API: members, invites and guest links are the server's
// to keep (they change who may read the log), so the app asks for them and acts through it.
import Foundation
import Observation

struct Member: Decodable, Hashable, Sendable, Identifiable {
    var personID: String
    var displayName: String
    var role: String
    var joinedAt: Int64
    var lastSeenAt: Int64?
    var id: String { personID }
    enum CodingKeys: String, CodingKey {
        case role
        case personID = "person_id", displayName = "display_name", joinedAt = "joined_at", lastSeenAt = "last_seen_at"
    }
}

struct Invite: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var role: String
    var expiresAt: Int64
    var url: String?
    /// Set when the invite adds a device to its maker instead of a member to the household.
    var device: Bool?
    enum CodingKeys: String, CodingKey {
        case id, role, url, device
        case expiresAt = "expires_at"
    }
}

struct GuestLink: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var homeID: String
    var listID: String
    var expiresAt: Int64
    var active: Bool
    var url: String?
    enum CodingKeys: String, CodingKey {
        case id, label, active, url
        case homeID = "home_id", listID = "list_id", expiresAt = "expires_at"
    }
}

struct Credential: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var platform: String
    var createdAt: Int64
    var lastUsedAt: Int64?
    var hasPush: Bool
    /// What this device wants to hear: not these lists, and clears only when true.
    var mutedLists: [String] = []
    var notifyClears: Bool = true
    enum CodingKeys: String, CodingKey {
        case id, label, platform
        case createdAt = "created_at", lastUsedAt = "last_used_at", hasPush = "has_push"
        case mutedLists = "muted_lists", notifyClears = "notify_clears"
    }

    init(id: String, label: String, platform: String, createdAt: Int64, lastUsedAt: Int64?, hasPush: Bool, mutedLists: [String] = [], notifyClears: Bool = true) {
        self.id = id; self.label = label; self.platform = platform; self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.hasPush = hasPush
        self.mutedLists = mutedLists; self.notifyClears = notifyClears
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        platform = try c.decode(String.self, forKey: .platform)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Int64.self, forKey: .lastUsedAt)
        hasPush = try c.decode(Bool.self, forKey: .hasPush)
        mutedLists = try c.decodeIfPresent([String].self, forKey: .mutedLists) ?? []
        notifyClears = try c.decodeIfPresent(Bool.self, forKey: .notifyClears) ?? true
    }
}

@MainActor @Observable
final class FamilyModel {
    private(set) var members: [Member] = []
    private(set) var invites: [Invite] = []
    private(set) var guests: [GuestLink] = []
    private(set) var devices: [Credential] = []
    private(set) var problem: String?
    private(set) var loading = false

    private let session: Session
    private var preset = false

    init(session: Session) {
        self.session = session
    }

    /// Rows given, nothing loaded: the snapshot tests and the previews.
    init(session: Session, members: [Member], invites: [Invite] = [], guests: [GuestLink] = [], devices: [Credential] = []) {
        self.session = session
        self.members = members
        self.invites = invites
        self.guests = guests
        self.devices = devices
        preset = true
    }

    private var base: String? { session.current.map { "/api/v1/h/" + $0.id } }

    struct Wrapped<T: Decodable>: Decodable {
        var members: [T]?
        var invites: [T]?
        var guests: [T]?
    }

    struct MeDoc: Decodable {
        var credentials: [Credential]
    }

    func load() async {
        guard !preset else { return }
        guard let client = session.client, let base else {
            // no key, or no household: the syncer's line says what to do
            problem = session.syncer.lastError
            return
        }
        loading = true
        defer { loading = false }
        do {
            let m: Wrapped<Member> = try await client.get(base + "/members")
            members = m.members ?? []
            session.learn(names: Dictionary(members.map { ($0.personID, $0.displayName) }, uniquingKeysWith: { a, _ in a }))
            if session.current?.isOwner == true {
                let i: Wrapped<Invite> = try await client.get(base + "/invites")
                invites = i.invites ?? []
                let g: Wrapped<GuestLink> = try await client.get(base + "/guests")
                guests = (g.guests ?? []).filter(\.active)
            }
            let me: MeDoc = try await client.get("/api/v1/me")
            devices = me.credentials
            problem = nil
        } catch {
            problem = Self.message(error)
        }
    }

    func invite(role: String) async -> Invite? {
        guard let client = session.client, let base else { return nil }
        struct Body: Encodable { var role: String }
        do {
            let inv: Invite = try await client.post(base + "/invites", Body(role: role))
            invites.append(inv)
            return inv
        } catch {
            problem = Self.message(error)
            return nil
        }
    }

    /// An invite for a second device of this person: a Mac, a new phone. It is not among the
    /// household's invites and lives a day.
    func deviceInvite() async -> Invite? {
        guard let client = session.client, let base else { return nil }
        struct Body: Encodable { var device: Bool }
        do {
            let inv: Invite = try await client.post(base + "/invites", Body(device: true))
            return inv
        } catch {
            problem = Self.message(error)
            return nil
        }
    }

    /// What this device wants to hear; kept on the server, which composes the words.
    func setNotify(device credentialID: String, muted: [String], clears: Bool) async {
        guard let client = session.client else { return }
        struct Body: Encodable {
            var mutedLists: [String], clears: Bool
            enum CodingKeys: String, CodingKey { case clears, mutedLists = "muted_lists" }
        }
        do {
            let _: SyncClient.Empty = try await client.put("/api/v1/devices/\(credentialID)/notify", Body(mutedLists: muted, clears: clears))
            if let i = devices.firstIndex(where: { $0.id == credentialID }) {
                devices[i].mutedLists = muted
                devices[i].notifyClears = clears
            }
        } catch {
            problem = Self.message(error)
        }
    }

    func revokeInvite(_ id: String) async {
        guard let client = session.client, let base else { return }
        do {
            try await client.delete(base + "/invites/" + id)
            invites.removeAll { $0.id == id }
        } catch {
            problem = Self.message(error)
        }
    }

    func guestLink(homeID: String, listID: String, label: String, days: Int) async -> GuestLink? {
        guard let client = session.client, let base else { return nil }
        struct Body: Encodable {
            var homeID: String, listID: String, label: String, days: Int
            enum CodingKeys: String, CodingKey {
                case label, days
                case homeID = "home_id", listID = "list_id"
            }
        }
        do {
            let g: GuestLink = try await client.post(base + "/guests", Body(homeID: homeID, listID: listID, label: label, days: days))
            guests.append(g)
            return g
        } catch {
            problem = Self.message(error)
            return nil
        }
    }

    func revokeGuest(_ id: String) async {
        guard let client = session.client, let base else { return }
        do {
            try await client.delete(base + "/guests/" + id)
            guests.removeAll { $0.id == id }
        } catch {
            problem = Self.message(error)
        }
    }

    func remove(member personID: String) async {
        guard let client = session.client, let base else { return }
        do {
            try await client.delete(base + "/members/" + personID)
            members.removeAll { $0.personID == personID }
        } catch {
            problem = Self.message(error)
        }
    }

    /// This person leaves the household; the server refuses the last owner.
    func leave() async -> Bool {
        guard let client = session.client, let base, let c = session.context, let scope = session.scope else { return false }
        do {
            try await client.delete(base + "/members/" + c.personID)
            try? session.store.removeHousehold(scope)
            session.reload()
            return true
        } catch {
            problem = Self.message(error)
            return false
        }
    }

    func revoke(device id: String) async {
        guard let client = session.client else { return }
        do {
            try await client.delete("/api/v1/credentials/" + id)
            devices.removeAll { $0.id == id }
            if id == session.context?.credentialID {
                session.forgetServer()
            }
        } catch {
            problem = Self.message(error)
        }
    }

    func setStaleness(days: Int64) async {
        guard let client = session.client, let base, let h = session.current else { return }
        struct Body: Encodable {
            var name: String, timezone: String, stalenessDays: Int64
            enum CodingKeys: String, CodingKey {
                case name, timezone
                case stalenessDays = "staleness_days"
            }
        }
        do {
            let _: AcceptedHousehold = try await client.put(base, Body(name: h.name, timezone: h.timezone, stalenessDays: days))
            var row = h
            row.stalenessDays = days
            try? session.store.upsertHousehold(row)
            session.reload()
        } catch {
            problem = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        if let e = error as? ClientError {
            switch e {
            case .problem(let p): return p.message
            case .transport: return String(localized: "Could not reach the family's doma. Try again in a moment.")
            case .unauthorized: return String(localized: "This device is no longer part of the family.")
            case .rateLimited: return String(localized: "Too many requests. Try again in a moment.")
            case .badResponse: return String(localized: "Something went wrong. Try again.")
            }
        }
        return error.localizedDescription
    }
}
