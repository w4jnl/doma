// The app's network path against a real doma, when one is given in tmp/live.json at the
// repository root, {"base_url": "http://127.0.0.1:8097", "invite": "<token>"} (make ui-test
// writes it; by hand, make run and an owner invite from the admin page). The session accepts
// the invite, the default list and the first home come down, an item goes up and the server
// echoes it back with a seq, and a second device joins. Skipped otherwise.
import GRDB
import XCTest
@testable import Doma

@MainActor
final class LiveTests: XCTestCase {
    func testAcceptAddAndSyncAgainstAServer() async throws {
        let file = Fixture.root.appendingPathComponent("tmp/live.json")
        guard let data = try? Data(contentsOf: file), let live = try? JSONValue(data: data),
              let base = live["base_url"]?.stringValue, let token = live["invite"]?.stringValue else {
            throw XCTSkip("no live server: write tmp/live.json with base_url and invite")
        }
        DeviceKey.forget()
        let store = try DomaStore.inMemory()
        let session = Session(store: store)
        XCTAssertFalse(session.hasHousehold)
        try await session.accept(base + "/i/" + token, displayName: "Jaro")
        XCTAssertTrue(session.hasHousehold)
        XCTAssertEqual(session.current?.role, "owner")
        let scope = try XCTUnwrap(session.scope)
        var tables = try store.tables(scope)
        XCTAssertEqual(tables.lists.map(\.name), ["Shopping"], "the default list came down")
        XCTAssertEqual(tables.homes.map(\.name), ["Gouda"], "and the first home")
        XCTAssertGreaterThan(try store.cursor(scope), 0)

        // an item typed on this device goes up and comes back with a seq
        guard case .added(let itemID) = try ListActions.add("melk 2", to: tables.lists[0].id, in: session) else { return XCTFail("not added") }
        XCTAssertEqual(try store.outboxCount(scope), 2)
        await session.syncer.sync()
        XCTAssertFalse(session.syncer.offline, session.syncer.lastError ?? "")
        XCTAssertEqual(try store.outboxCount(scope), 0)
        tables = try store.tables(scope)
        XCTAssertEqual(tables.items.map(\.id), [itemID])
        XCTAssertEqual(tables.entries.count, 1)
        let seqs = try await store.db.read { db in try Int64?.fetchAll(db, sql: "SELECT seq FROM events ORDER BY seq") }
        XCTAssertFalse(seqs.contains(nil), "every event has the server's seq")

        // a second invite from this owner, through the REST API, as Family does
        let family = FamilyModel(session: session)
        await family.load()
        XCTAssertEqual(family.members.map(\.displayName), ["Jaro"])
        let inv = await family.invite(role: "member")
        XCTAssertNotNil(inv?.url)
        XCTAssertNotNil(inv.flatMap { InviteLink($0.url ?? "") })
        // a second phone joins with it and sees the item
        DeviceKey.forget()
        let other = Session(store: try DomaStore.inMemory())
        try await other.accept(inv!.url!, displayName: "Sam")
        XCTAssertEqual(other.current?.role, "member")
        let theirs = try other.store.tables(try XCTUnwrap(other.scope))
        XCTAssertEqual(theirs.entries.count, 1)
        XCTAssertEqual(theirs.items.first?.name, "melk")
        DeviceKey.forget()
    }
}
