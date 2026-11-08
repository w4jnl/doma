// SyncClient talks to one server as one device: accepts an invite, exchanges events on
// POST /sync/v1, downloads a snapshot, and calls the REST routes; every request after the
// invite is signed with the device key over method, path, timestamp and the body's SHA-256,
// as internal/auth checks it. Errors are the server's problem documents.
import CryptoKit
import Foundation

struct Problem: Error, Decodable, Sendable, Equatable {
    var status: Int
    var type: String?
    var title: String?
    var detail: String?
    var field: String?

    /// What a person reads: the detail, the title, or the status.
    var message: String { detail ?? title ?? "Request failed (\(status))" }
}

enum ClientError: Error, Sendable {
    /// The server refused the signature or the credential: this device is revoked.
    case unauthorized(Problem?)
    /// 429, with the seconds to wait.
    case rateLimited(TimeInterval)
    case problem(Problem)
    case badResponse(Int)
    case transport(String)

    var isOffline: Bool {
        if case .transport = self { return true }
        return false
    }
}

struct Accepted: Decodable, Sendable {
    var server: String
    var personID: String
    var credentialID: String
    /// The name the family knows the person by; a device invite's answer carries the
    /// person's, not what the new device typed.
    var displayName: String?
    var household: AcceptedHousehold
    var role: String
    enum CodingKeys: String, CodingKey {
        case server, household, role
        case personID = "person_id", credentialID = "credential_id", displayName = "display_name"
    }
}

struct AcceptedHousehold: Decodable, Sendable {
    var id: String
    var name: String
    var timezone: String?
    var stalenessDays: Int64?
    enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case stalenessDays = "staleness_days"
    }
}

struct SyncRequest: Encodable, Sendable {
    struct Household: Encodable, Sendable {
        var id: String
        var since: Int64
        var events: [JSONValue]
    }
    var households: [Household]
}

struct SyncEvent: Decodable, Sendable, Hashable {
    var seq: Int64
    var id: String
    var personID: String
    var hlc: String
    var kind: String
    var payload: JSONValue
    enum CodingKeys: String, CodingKey {
        case seq, id, hlc, kind, payload
        case personID = "person_id"
    }
}

struct SyncResponse: Decodable, Sendable {
    struct Rejected: Decodable, Sendable, Hashable {
        var id: String
        var reason: String
    }
    struct Household: Decodable, Sendable {
        var id: String
        var accepted: [String]
        var rejected: [Rejected]
        var events: [SyncEvent]
        var next: Int64
        var snapshot: String?
    }
    var households: [Household]
}

struct SnapshotDocument: Decodable, Sendable {
    var seq: Int64?
    var tables: Tables
}

struct MeDocument: Decodable, Sendable {
    struct Person: Decodable, Sendable {
        var id: String
        var displayName: String
        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }
    struct Membership: Decodable, Sendable {
        var householdID: String
        var householdName: String
        var role: String
        // the household's time zone and staleness, absent from a doma older than them
        var timezone: String?
        var stalenessDays: Int64?
        enum CodingKeys: String, CodingKey {
            case role, timezone
            case householdID = "household_id", householdName = "household_name", stalenessDays = "staleness_days"
        }
    }
    var person: Person
    var memberships: [Membership]
}

struct SyncClient: Sendable {
    var baseURL: URL
    var key: DeviceKey
    var credentialID: String?
    var session: URLSession = .shared
    var now: @Sendable () -> Date = { Date() }

    static let headerCredential = "Doma-Credential"
    static let headerTimestamp = "Doma-Timestamp"
    static let headerSignature = "Doma-Signature"

    /// Redeems an invite with this device's key. Unsigned: the device has no credential yet.
    func accept(token: String, displayName: String, label: String, platform: String) async throws -> Accepted {
        struct Body: Encodable {
            var publicKey: String, platform: String, label: String, displayName: String
            enum CodingKeys: String, CodingKey {
                case platform, label
                case publicKey = "public_key", displayName = "display_name"
            }
        }
        return try await send("POST", "/i/" + token, body: Body(publicKey: key.publicKeyString, platform: platform, label: label, displayName: displayName), signed: false)
    }

    func sync(_ req: SyncRequest) async throws -> SyncResponse {
        try await send("POST", "/sync/v1", body: req, signed: true)
    }

    /// A snapshot by the URL the sync answer gave; the transport inflates it.
    func snapshot(_ url: URL) async throws -> SnapshotDocument {
        let (data, response) = try await perform(request(method: "GET", url: url, body: nil, signed: true))
        try check(response, data)
        return try decode(data)
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path, body: Optional<Int>.none, signed: true)
    }

    func post<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        try await send("POST", path, body: body, signed: true)
    }

    func put<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        try await send("PUT", path, body: body, signed: true)
    }

    func delete(_ path: String) async throws {
        let _: Empty = try await send("DELETE", path, body: Optional<Int>.none, signed: true)
    }

    /// A picture up, by its photo id's path, as image/jpeg; the answer is what the server kept.
    func upload(_ path: String, jpeg: Data) async throws -> Data {
        var r = try request(method: "POST", url: baseURL.appendingPathComponent(path), body: jpeg, signed: true)
        r.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform(r)
        try check(response, data)
        return data
    }

    /// A picture down, by its path, with the device's signature.
    func download(_ path: String) async throws -> Data {
        let (data, response) = try await perform(try request(method: "GET", url: baseURL.appendingPathComponent(path), body: nil, signed: true))
        try check(response, data)
        return data
    }

    struct Empty: Decodable {
        init() {}
        init(from decoder: Decoder) throws {}
    }

    // MARK: Signing

    /// What a device signs: method, path, timestamp and the hex SHA-256 of the body.
    static func signingString(method: String, path: String, timestamp: String, body: Data) -> Data {
        let sum = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data((method + "\n" + path + "\n" + timestamp + "\n" + sum).utf8)
    }

    func request(method: String, url: URL, body: Data?, signed: Bool) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if signed {
            guard let credentialID else { throw ClientError.unauthorized(nil) }
            let ts = String(millis(now()))
            let sig = try key.sign(Self.signingString(method: method, path: url.path, timestamp: ts, body: body ?? Data()))
            r.setValue(credentialID, forHTTPHeaderField: Self.headerCredential)
            r.setValue(ts, forHTTPHeaderField: Self.headerTimestamp)
            r.setValue(sig.base64EncodedString(), forHTTPHeaderField: Self.headerSignature)
        }
        return r
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: (some Encodable)?, signed: Bool) async throws -> T {
        let data: Data? = try body.map { b in
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            return try enc.encode(b)
        }
        let url = baseURL.appendingPathComponent(path)
        let (out, response) = try await perform(try request(method: method, url: url, body: data, signed: signed))
        try check(response, out)
        if T.self == Empty.self { return Empty() as! T }
        return try decode(out)
    }

    private func perform(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: r)
            guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse(0) }
            return (data, http)
        } catch let e as ClientError {
            throw e
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }

    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw ClientError.unauthorized(try? JSONDecoder().decode(Problem.self, from: data))
        case 429:
            let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 10
            throw ClientError.rateLimited(wait)
        default:
            if var p = try? JSONDecoder().decode(Problem.self, from: data) {
                p.status = response.statusCode
                throw ClientError.problem(p)
            }
            throw ClientError.badResponse(response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.transport("unreadable answer: \(error.localizedDescription)")
        }
    }
}
