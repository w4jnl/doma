// A tasks list: the same mechanics as a shopping list, with its own kind in the row, its own
// names while typing, and no purchases.
import GRDB
import XCTest
@testable import Doma

@MainActor
final class TasksLogicTests: XCTestCase {
    func session() throws -> Session {
        let store = try DomaStore.inMemory()
        try store.saveContext(ServerContext(serverID: "S1", baseURL: URL(string: "https://doma.example")!, credentialID: "C1", personID: "pa", displayName: "Jaro", createdAt: 1))
        try store.upsertHousehold(HouseholdRow(serverID: "S1", id: "H1", name: "De Vries", timezone: "Europe/Amsterdam", stalenessDays: nil, role: "owner"))
        let s = Session(store: store)
        try s.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true))
        return s
    }

    func testATasksListKeepsItsKindAndItsNamesToItself() throws {
        let s = try session()
        let scope = try XCTUnwrap(s.scope)
        let chores = try XCTUnwrap(ListActions.createList(named: "Chores", personal: false, tasks: true, colour: "list-2", in: s))
        try ListActions.renameList(chores, to: "Klusjes", colour: "list-3", in: s)
        let lists = try s.store.read(scope) { db, sc in try Queries.lists(db, sc) }
        XCTAssertEqual(lists.map(\.isTasks), [false, true], "the default list shops, the new one is tasks, and stays so under a rename")
        XCTAssertEqual(lists.last?.name, "Klusjes")

        _ = try ListActions.add("melk", to: "L1", in: s)
        _ = try ListActions.add("stofzuigen", to: chores, in: s)
        let shopping = try s.store.read(scope) { db, sc in try Queries.matches(db, sc, prefix: "s") }
        let tasks = try s.store.read(scope) { db, sc in try Queries.matches(db, sc, prefix: "s", tasks: true) }
        XCTAssertEqual(shopping.map(\.name), [], "a chore does not come up while typing on the shopping list")
        XCTAssertEqual(tasks.map(\.name), ["stofzuigen"])
        XCTAssertEqual(try s.store.read(scope) { db, sc in try Queries.matches(db, sc, prefix: "m") }.map(\.name), ["melk"])

        // done is not bought: the clear leaves History and the usual items of the shopping list alone
        for row in try s.store.read(scope, { db, sc in try Queries.entries(db, sc, listID: chores) }) {
            try ListActions.toggle(row, on: chores, in: s)
        }
        try ListActions.clear(chores, in: s)
        XCTAssertEqual(try s.store.read(scope) { db, sc in try Queries.purchaseMonths(db, sc) }, [], "a done task is no purchase")
        XCTAssertEqual(try s.store.read(scope) { db, sc in try Queries.usual(db, sc, listID: "L1") }.map(\.name), [], "the shopping list's usual items do not name the chore")
        XCTAssertEqual(try s.store.read(scope) { db, sc in try Queries.usual(db, sc, listID: chores) }.map(\.name), ["stofzuigen"], "the tasks list's usual items do")
    }
}
