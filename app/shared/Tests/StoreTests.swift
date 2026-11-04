// The local store: an event is appended, queued and folded in one transaction; the SQL fold
// passes the fixture like the in-memory one; the tables rebuild from the log; a snapshot is a
// base later events build on.
import GRDB
import XCTest
@testable import Doma

final class StoreTests: XCTestCase {
    let scope = Scope(serverID: "S1", householdID: "H1", personID: "pa")

    func fresh() throws -> (DomaStore, HLCClock) {
        (try DomaStore.inMemory(), HLCClock(device: "dev"))
    }

    func testOnDiskStoreIsAWALPool() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doma-store-" + ULID.make(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try DomaStore(path: dir.appendingPathComponent("doma.sqlite").path)
        XCTAssertTrue(store.db is DatabasePool, "on disk, screens read on their own connections")
        XCTAssertEqual(try store.db.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }, "wal")
        let clock = HLCClock(device: "dev")
        try store.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true), scope: scope, clock: clock)
        XCTAssertEqual(try store.tables(scope).lists.map(\.name), ["Shopping"])
        // the second open applies no migration twice and sees the row
        let again = try DomaStore(path: dir.appendingPathComponent("doma.sqlite").path)
        XCTAssertEqual(try again.tables(scope).lists.count, 1)
    }

    func testRecordAppendsQueuesAndFolds() throws {
        let (store, clock) = try fresh()
        try store.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true), scope: scope, clock: clock)
        try store.record(scope: scope, clock: clock) { events in
            events.append(Event(id: "i1", personID: "pa", hlc: clock.next(), kind: Kind.itemNamed, payload: ItemPayload(itemID: "I1", name: "melk").jsonValue))
            events.append(Event(id: "e1", personID: "pa", hlc: clock.next(), kind: Kind.entryAdded, payload: EntryPayload(listID: "L1", itemID: "I1", qty: 2, unit: "x").jsonValue))
        }
        let t = try store.tables(scope)
        XCTAssertEqual(t.lists.map(\.name), ["Shopping"])
        XCTAssertEqual(t.items.map(\.normName), ["melk"])
        XCTAssertEqual(t.entries.count, 1)
        XCTAssertEqual(t.entries[0].qty, 2)
        XCTAssertEqual(t.items[0].useCount, 1)
        let out = try store.outbox(scope, limit: 10)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1].body["kind"]?.stringValue, Kind.itemNamed)
        XCTAssertEqual(out[1].body["household_id"]?.stringValue, "H1")
        XCTAssertNotNil(out[1].body["hlc"]?.stringValue.flatMap { HLC(parsing: $0) })
        try store.dequeue(scope, ids: ["i1", "e1"])
        XCTAssertEqual(try store.outboxCount(scope), 1)
    }

    func testRemoteEventsFoldAndEchoesTakeTheirSeq() throws {
        let (store, clock) = try fresh()
        let mine = try store.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true), scope: scope, clock: clock)
        let remote = [
            SyncEvent(seq: 1, id: mine.id, personID: "pa", hlc: mine.hlc.description, kind: mine.kind, payload: mine.payload),
            SyncEvent(seq: 2, id: "i9", personID: "pb", hlc: "9000:0:b", kind: Kind.itemNamed, payload: ItemPayload(itemID: "I9", name: "brood").jsonValue),
            SyncEvent(seq: 3, id: "e9", personID: "pb", hlc: "9001:0:b", kind: Kind.entryAdded, payload: EntryPayload(listID: "L1", itemID: "I9").jsonValue),
        ]
        try store.applyRemote(remote, scope: scope, clock: clock)
        let t = try store.tables(scope)
        XCTAssertEqual(t.entries.map(\.addedBy), ["pb"])
        XCTAssertEqual(t.lists.count, 1)
        // the clock moved past the remote stamps
        XCTAssertGreaterThan(clock.next().wall, 9000)
        let seqs = try store.db.read { db in try Int64?.fetchAll(db, sql: "SELECT seq FROM events ORDER BY id") }
        XCTAssertEqual(seqs.compactMap { $0 }.sorted(), [1, 2, 3])
    }

    func testFixtureThroughSQL() throws {
        for c in try Fixture.load() {
            let (store, _) = try fresh()
            let remote = c.events.enumerated().map { i, e in SyncEvent(seq: Int64(i + 1), id: e.id, personID: e.personID, hlc: e.hlc.description, kind: e.kind, payload: e.payload) }
            try store.applyRemote(remote, scope: scope, clock: nil)
            XCTAssertEqual(try store.tables(scope).canonical, Tables.canonical(expectation: c.expect), c.name)
            // and reversed, through the same store code
            let (store2, _) = try fresh()
            try store2.applyRemote(remote.reversed(), scope: scope, clock: nil)
            XCTAssertEqual(try store2.tables(scope).canonical, Tables.canonical(expectation: c.expect), c.name + " reversed")
        }
    }

    func testRebuildFromLogGivesTheSameTables() throws {
        var rng = SeededRNG(seed: 3)
        let events = Fixture.generate(60, rng: &rng)
        let (store, clock) = try fresh()
        let remote = events.enumerated().map { i, e in SyncEvent(seq: Int64(i + 1), id: e.id, personID: e.personID, hlc: e.hlc.description, kind: e.kind, payload: e.payload) }
        try store.applyRemote(Array(remote.prefix(40)), scope: scope, clock: clock)
        for e in events.suffix(20) {
            try store.record(e.kind, e.payload, scope: scope, clock: clock, id: e.id)
        }
        let before = try store.tables(scope).canonical
        try store.rebuildFromLog(scope)
        XCTAssertEqual(try store.tables(scope).canonical, before)
        // and equal to the pure fold of the same log
        let mem = MemStore()
        let log = try store.db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM events ORDER BY seq IS NULL, seq, hlc").map(Event.init(row:)) }
        for e in log { try mem.append(e) }
        XCTAssertEqual(mem.tables.canonical, before)
    }

    func testSnapshotIsABaseForLaterEvents() throws {
        // a full store on one device, a snapshot of it on another, the same later events on both
        let (full, clockA) = try fresh()
        try full.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true), scope: scope, clock: clockA, id: "l1")
        try full.record(Kind.itemNamed, ItemPayload(itemID: "I1", name: "melk"), scope: scope, clock: clockA, id: "i1")
        try full.record(Kind.entryAdded, EntryPayload(listID: "L1", itemID: "I1", note: "2x"), scope: scope, clock: clockA, id: "e1")
        let snapshot = try full.tables(scope)
        let (joined, clockB) = try fresh()
        // the joiner had an unsent event of its own before the snapshot landed
        let l1b = try joined.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true), scope: scope, clock: clockB, id: "l1b")
        try joined.importSnapshot(snapshot, seq: 3, scope: scope)
        XCTAssertEqual(try joined.cursor(scope), 3)
        XCTAssertEqual(try joined.outboxCount(scope), 1)
        // a check and a clear after the add, and a namesake from a phone that was offline for
        // long: its stamp is older than everything in the snapshot, so it owns the name
        let t = millis(Date()) + 1000
        let later = [
            SyncEvent(seq: 4, id: "c1", personID: "pb", hlc: "\(t):0:b", kind: Kind.entryChecked, payload: EntryPayload(listID: "L1", itemID: "I1").jsonValue),
            SyncEvent(seq: 5, id: "x1", personID: "pb", hlc: "\(t + 1):0:b", kind: Kind.entryCleared, payload: EntryPayload(listID: "L1", beforeHLC: "\(t + 1):0:b").jsonValue),
            SyncEvent(seq: 6, id: "i2", personID: "pb", hlc: "9002:0:b", kind: Kind.itemNamed, payload: ItemPayload(itemID: "I2", name: "MELK").jsonValue),
        ]
        // the full device also gets the joiner's event once it has gone up
        try full.applyRemote(later + [SyncEvent(seq: 7, id: l1b.id, personID: "pa", hlc: l1b.hlc.description, kind: l1b.kind, payload: l1b.payload)], scope: scope, clock: clockA)
        try joined.applyRemote(later, scope: scope, clock: clockB)
        let want = try full.tables(scope)
        let got = try joined.tables(scope)
        XCTAssertEqual(got.canonical, want.canonical)
        XCTAssertEqual(got.items.map { "\($0.id):\($0.mergedInto ?? "")" }, ["I1:I2", "I2:"])
        XCTAssertNotNil(got.entries.first?.clearedHLC)
        XCTAssertEqual(got.entries.first?.itemID, "I2")
    }

    func testWipeAndRemoveHousehold() throws {
        let (store, clock) = try fresh()
        try store.saveContext(ServerContext(serverID: "S1", baseURL: URL(string: "https://doma.example")!, credentialID: "C1", personID: "pa", displayName: "Jaro", createdAt: 1))
        try store.upsertHousehold(HouseholdRow(serverID: "S1", id: "H1", name: "De Vries", timezone: "Europe/Amsterdam", stalenessDays: nil, role: "owner"))
        try store.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true), scope: scope, clock: clock)
        XCTAssertEqual(try store.households(serverID: "S1").count, 1)
        try store.removeHousehold(scope)
        XCTAssertEqual(try store.households(serverID: "S1").count, 0)
        XCTAssertEqual(try store.tables(scope), Tables())
        XCTAssertEqual(try store.contexts().count, 1)
        try store.wipe(serverID: "S1")
        XCTAssertTrue(try store.contexts().isEmpty)
    }

    /// Two families' domas in one store: each keeps its households, rows and cursor under its
    /// own server id, even for the same household id, and wiping one leaves the other whole.
    func testTwoServersShareOneStore() throws {
        let (store, clock) = try fresh()
        let s1 = scope
        let s2 = Scope(serverID: "S2", householdID: "H1", personID: "pb")
        try store.saveContext(ServerContext(serverID: "S1", baseURL: URL(string: "https://doma.example")!, credentialID: "C1", personID: "pa", displayName: "Jaro", createdAt: 1))
        try store.saveContext(ServerContext(serverID: "S2", baseURL: URL(string: "https://test.doma.example")!, credentialID: "C9", personID: "pb", displayName: "Jaro", createdAt: 2))
        try store.upsertHousehold(HouseholdRow(serverID: "S1", id: "H1", name: "De Vries", timezone: "", stalenessDays: nil, role: "owner"))
        try store.upsertHousehold(HouseholdRow(serverID: "S2", id: "H1", name: "Proef", timezone: "", stalenessDays: nil, role: "member"))
        try store.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true), scope: s1, clock: clock)
        try store.record(Kind.listCreated, ListPayload(listID: "L1", name: "Testlijst", isDefault: true), scope: s2, clock: HLCClock(device: "C9"))
        try store.db.write { db in try DomaStore.setCursor(db, s2, 7) }
        XCTAssertEqual(try store.contexts().map(\.serverID), ["S1", "S2"])
        XCTAssertEqual(try store.households(serverID: "S1").map(\.name), ["De Vries"])
        XCTAssertEqual(try store.households(serverID: "S2").map(\.name), ["Proef"])
        XCTAssertEqual(try store.read(s1) { db, sc in try Queries.lists(db, sc) }.map(\.name), ["Shopping"])
        XCTAssertEqual(try store.read(s2) { db, sc in try Queries.lists(db, sc) }.map(\.name), ["Testlijst"])
        XCTAssertEqual(try store.db.read { db in try DomaStore.cursor(db, s1) }, 0)
        XCTAssertEqual(try store.db.read { db in try DomaStore.cursor(db, s2) }, 7)
        XCTAssertEqual(try store.outboxCount(s1), 1)
        try store.wipe(serverID: "S2")
        XCTAssertEqual(try store.contexts().map(\.serverID), ["S1"])
        XCTAssertEqual(try store.read(s1) { db, sc in try Queries.lists(db, sc) }.count, 1)
        XCTAssertEqual(try store.read(s2) { db, sc in try Queries.lists(db, sc) }.count, 0)
    }
}

extension Array where Element == Entry {
    var canonicalDescription: String { Tables(entries: self).canonical }
}
