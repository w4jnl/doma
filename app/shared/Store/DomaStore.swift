// DomaStore is the app's local database: the server context, the households, each household's
// log, tables, outbox and cursor. Every screen reads it and writes to it; a tap is one event
// appended to the outbox and folded in the same transaction, so the screen moves before any
// network. Nothing else writes the tables.
//
// On disk it is a DatabasePool in WAL mode: screens read on reader connections and the
// observations fetch their fresh values after a commit, off the writer, so a tap's write holds
// the main thread only for the fold itself. The syncer uses the async read and write, so the
// exchange never blocks a frame. In memory (tests, previews) it is a DatabaseQueue.
import Foundation
import GRDB
import os

/// The one server this app talks to (v1 holds a single context) and this device's place on it.
struct ServerContext: Hashable, Sendable {
    var serverID: String
    var baseURL: URL
    var credentialID: String
    var personID: String
    var displayName: String
    var createdAt: Int64
}

/// A household this person belongs to, as the server told it.
struct HouseholdRow: Hashable, Sendable, Identifiable {
    var serverID: String
    var id: String
    var name: String
    var timezone: String
    var stalenessDays: Int64?
    var role: String

    var isOwner: Bool { role == "owner" }
}

/// One event waiting to go up.
struct OutboxItem: Hashable, Sendable {
    var eventID: String
    var body: JSONValue
    var attempts: Int64
}

final class DomaStore: Sendable {
    let db: any DatabaseWriter

    /// Signposts for Instruments: a record, a remote apply, a snapshot import.
    static let signposter = OSSignposter(subsystem: "nl.w4j.doma", category: "store")

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        if path.isEmpty {
            db = try DatabaseQueue(path: path, configuration: config)
        } else {
            db = try DatabasePool(path: path, configuration: config)
        }
        try Schema.migrator.migrate(db)
    }

    /// A store that lives in memory: the tests, and the previews.
    static func inMemory() throws -> DomaStore {
        try DomaStore(path: "")
    }

    /// The database file under Application Support.
    static func defaultPath() throws -> String {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("doma", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("doma.sqlite").path
    }

    // MARK: context and households

    func context() throws -> ServerContext? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM contexts ORDER BY created_at LIMIT 1").flatMap { r in
                guard let url = URL(string: r["base_url"]) else { return nil }
                return ServerContext(serverID: r["server_id"], baseURL: url, credentialID: r["credential_id"], personID: r["person_id"], displayName: r["display_name"], createdAt: r["created_at"])
            }
        }
    }

    func saveContext(_ c: ServerContext) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO contexts (server_id, base_url, credential_id, person_id, display_name, created_at) VALUES (?,?,?,?,?,?)",
                           arguments: [c.serverID, c.baseURL.absoluteString, c.credentialID, c.personID, c.displayName, c.createdAt])
        }
    }

    func households(serverID: String) throws -> [HouseholdRow] {
        try db.read { db in try Self.households(db, serverID: serverID) }
    }

    static func households(_ db: Database, serverID: String) throws -> [HouseholdRow] {
        try Row.fetchAll(db, sql: "SELECT * FROM households WHERE server_id = ? ORDER BY name, id", arguments: [serverID]).map { r in
            HouseholdRow(serverID: r["server_id"], id: r["id"], name: r["name"], timezone: r["timezone"], stalenessDays: r["staleness_days"], role: r["role"])
        }
    }

    func upsertHousehold(_ h: HouseholdRow) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO households (server_id, id, name, timezone, staleness_days, role) VALUES (?,?,?,?,?,?)",
                           arguments: [h.serverID, h.id, h.name, h.timezone, h.stalenessDays, h.role])
        }
    }

    /// Drops a household and everything under it: the person was removed from it.
    func removeHousehold(_ scope: Scope) throws {
        try db.write { db in try Self.removeHousehold(db, scope) }
    }

    static func removeHousehold(_ db: Database, _ scope: Scope) throws {
        for table in Schema.householdTables {
            try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ? AND household_id = ?", arguments: [scope.serverID, scope.householdID])
        }
        try db.execute(sql: "DELETE FROM households WHERE server_id = ? AND id = ?", arguments: [scope.serverID, scope.householdID])
    }

    /// Drops everything for a server: the device was revoked, or the person left.
    func wipe(serverID: String) throws {
        try db.write { db in
            for table in Schema.householdTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ?", arguments: [serverID])
            }
            try db.execute(sql: "DELETE FROM households WHERE server_id = ?", arguments: [serverID])
            try db.execute(sql: "DELETE FROM contexts WHERE server_id = ?", arguments: [serverID])
        }
    }

    // MARK: events

    /// Writes one event of this person: appended to the log, put in the outbox and folded, in
    /// one transaction. Returns the event.
    @discardableResult
    func record(_ kind: String, _ payload: some Encodable, scope: Scope, clock: HLCClock, id: String = ULID.make()) throws -> Event {
        let e = Event(id: id, personID: scope.personID, hlc: clock.next(), kind: kind, payload: payload.jsonValue)
        let state = Self.signposter.beginInterval("record", "\(kind, privacy: .public)")
        defer { Self.signposter.endInterval("record", state) }
        try db.write { db in
            let s = SQLFoldStore(db: db, scope: scope)
            try s.append(e, seq: nil)
            try Self.enqueue(db, scope: scope, e)
        }
        return e
    }

    /// Several events of this person in one transaction and one order, as "item.named then
    /// entry.added" from a single tap.
    func record(scope: Scope, clock: HLCClock, _ build: (inout [Event]) -> Void) throws {
        var events: [Event] = []
        build(&events)
        let state = Self.signposter.beginInterval("record", "\(events.count) events")
        defer { Self.signposter.endInterval("record", state) }
        try db.write { db in
            let s = SQLFoldStore(db: db, scope: scope)
            for e in events {
                try s.append(e, seq: nil)
                try Self.enqueue(db, scope: scope, e)
            }
        }
    }

    private static func enqueue(_ db: Database, scope: Scope, _ e: Event) throws {
        let body = JSONValue.object(["id": .string(e.id), "household_id": .string(scope.householdID), "hlc": .string(e.hlc.description), "kind": .string(e.kind), "payload": e.payload])
        try db.execute(sql: "INSERT OR REPLACE INTO outbox (server_id, household_id, event_id, body, created_at, attempts) VALUES (?,?,?,?,?,0)",
                       arguments: [scope.serverID, scope.householdID, e.id, body.string, millis(Date())])
    }

    /// Folds events that came down from the server, in one transaction: a new id is appended
    /// and folded, a known one (this device's, echoed back) takes its seq. The clock observes
    /// every stamp so the next local event is after them.
    func applyRemote(_ events: [SyncEvent], scope: Scope, clock: HLCClock?) throws {
        try db.write { db in try Self.applyRemote(db, events, scope: scope, clock: clock) }
    }

    static func applyRemote(_ db: Database, _ events: [SyncEvent], scope: Scope, clock: HLCClock?) throws {
        let state = signposter.beginInterval("applyRemote", "\(events.count) events")
        defer { signposter.endInterval("applyRemote", state) }
        let s = SQLFoldStore(db: db, scope: scope)
        for se in events {
            guard let hlc = HLC(parsing: se.hlc) else { continue }
            clock?.observe(hlc)
            try s.append(Event(id: se.id, personID: se.personID, hlc: hlc, kind: se.kind, payload: se.payload), seq: se.seq)
        }
    }

    func outbox(_ scope: Scope, limit: Int) throws -> [OutboxItem] {
        try db.read { db in try Self.outbox(db, scope, limit: limit) }
    }

    static func outbox(_ db: Database, _ scope: Scope, limit: Int) throws -> [OutboxItem] {
        try Row.fetchAll(db, sql: "SELECT event_id, body, attempts FROM outbox WHERE server_id = ? AND household_id = ? ORDER BY created_at, rowid LIMIT ?", arguments: [scope.serverID, scope.householdID, limit]).map { r in
            let raw: String = r["body"]
            return OutboxItem(eventID: r["event_id"], body: (try? JSONValue(data: Data(raw.utf8))) ?? .null, attempts: r["attempts"])
        }
    }

    func outboxCount(_ scope: Scope) throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE server_id = ? AND household_id = ?", arguments: [scope.serverID, scope.householdID]) ?? 0
        }
    }

    /// Removes sent events from the outbox: accepted ones, and rejected ones the server will
    /// never take (they are logged by the caller).
    func dequeue(_ scope: Scope, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in try Self.dequeue(db, scope, ids: ids) }
    }

    static func dequeue(_ db: Database, _ scope: Scope, ids: [String]) throws {
        for id in ids {
            try db.execute(sql: "DELETE FROM outbox WHERE server_id = ? AND household_id = ? AND event_id = ?", arguments: [scope.serverID, scope.householdID, id])
        }
    }

    func noteAttempt(_ scope: Scope, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in try Self.noteAttempt(db, scope, ids: ids) }
    }

    static func noteAttempt(_ db: Database, _ scope: Scope, ids: [String]) throws {
        for id in ids {
            try db.execute(sql: "UPDATE outbox SET attempts = attempts + 1 WHERE server_id = ? AND household_id = ? AND event_id = ?", arguments: [scope.serverID, scope.householdID, id])
        }
    }

    func cursor(_ scope: Scope) throws -> Int64 {
        try db.read { db in try Self.cursor(db, scope) }
    }

    static func cursor(_ db: Database, _ scope: Scope) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT since FROM cursors WHERE server_id = ? AND household_id = ?", arguments: [scope.serverID, scope.householdID]) ?? 0
    }

    func setCursor(_ scope: Scope, _ since: Int64) throws {
        try db.write { db in try Self.setCursor(db, scope, since) }
    }

    static func setCursor(_ db: Database, _ scope: Scope, _ since: Int64) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO cursors (server_id, household_id, since) VALUES (?,?,?)", arguments: [scope.serverID, scope.householdID, since])
    }

    /// Replaces the household's tables with a snapshot's and moves the cursor to its seq. The
    /// log the snapshot stands for is not kept; the rows are the base later events build on.
    /// Events still in the outbox are appended again on top.
    func importSnapshot(_ t: Tables, seq: Int64, scope: Scope) throws {
        try db.write { db in try Self.importSnapshot(db, t, seq: seq, scope: scope) }
    }

    static func importSnapshot(_ db: Database, _ t: Tables, seq: Int64, scope: Scope) throws {
        let state = signposter.beginInterval("importSnapshot")
        defer { signposter.endInterval("importSnapshot", state) }
        for table in ["event_items", "events"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ? AND household_id = ?", arguments: [scope.serverID, scope.householdID])
        }
        let s = SQLFoldStore(db: db, scope: scope)
        try s.replaceTables(t)
        try db.execute(sql: "INSERT OR REPLACE INTO cursors (server_id, household_id, since) VALUES (?,?,?)", arguments: [scope.serverID, scope.householdID, seq])
        let pending = try Row.fetchAll(db, sql: "SELECT body FROM outbox WHERE server_id = ? AND household_id = ? ORDER BY created_at, rowid", arguments: [scope.serverID, scope.householdID])
        for r in pending {
            let raw: String = r["body"]
            guard let body = try? JSONValue(data: Data(raw.utf8)), let id = body["id"]?.stringValue, let kind = body["kind"]?.stringValue,
                  let hlc = body["hlc"]?.stringValue.flatMap({ HLC(parsing: $0) }) else { continue }
            try s.append(Event(id: id, personID: scope.personID, hlc: hlc, kind: kind, payload: body["payload"] ?? .object([:])), seq: nil)
        }
    }

    // MARK: the tables

    func tables(_ scope: Scope) throws -> Tables {
        try db.read { db in try SQLFoldStore(db: db, scope: scope).tables() }
    }

    /// Wipes the tables and folds the log again, in seq order with this device's unsent events
    /// last by stamp. A test proves the result equals the tables as they stood.
    func rebuildFromLog(_ scope: Scope) throws {
        try db.write { db in
            let s = SQLFoldStore(db: db, scope: scope)
            try s.replaceTables(Tables())
            let events = try Row.fetchAll(db, sql: "SELECT * FROM events WHERE server_id = ? AND household_id = ? ORDER BY seq IS NULL, seq, hlc", arguments: [scope.serverID, scope.householdID]).map(Event.init(row:))
            for e in events {
                try Fold.apply(e, to: s)
            }
        }
    }

    /// Runs a read against the household's tables.
    func read<T>(_ scope: Scope, _ body: (Database, Scope) throws -> T) throws -> T {
        try db.read { db in try body(db, scope) }
    }
}
