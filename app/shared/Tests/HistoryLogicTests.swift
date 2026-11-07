// The History screen's reading of the purchases: months, per item with totals by unit, per
// home, per person; all from the entries table.
import GRDB
import XCTest
@testable import Doma

@MainActor
final class HistoryLogicTests: XCTestCase {
    func session() throws -> Session {
        let store = try DomaStore.inMemory()
        try store.saveContext(ServerContext(serverID: "S1", baseURL: URL(string: "https://doma.example")!, credentialID: "C1", personID: "pa", displayName: "Jaro", createdAt: 1))
        try store.upsertHousehold(HouseholdRow(serverID: "S1", id: "H1", name: "De Vries", timezone: "Europe/Amsterdam", stalenessDays: nil, role: "owner"))
        let s = Session(store: store)
        try s.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true))
        try s.record(Kind.homeCreated, HomePayload(homeID: "G", name: "Gouda"))
        return s
    }

    func rows(_ s: Session) throws -> [EntryRow] {
        try s.store.read(s.scope!) { db, sc in try Queries.entries(db, sc, listID: "L1") }
    }

    /// Strikes every open row and clears the list: one shopping trip.
    func shop(_ s: Session) throws {
        for row in try rows(s) where !row.isChecked {
            try ListActions.toggle(row, on: "L1", in: s)
        }
        try ListActions.clear("L1", in: s)
    }

    func testPurchasesByMonthItemHomeAndPerson() throws {
        let s = try session()
        let scope = try XCTUnwrap(s.scope)
        XCTAssertEqual(try s.store.read(scope) { db, sc in try Queries.purchaseMonths(db, sc) }, [], "nothing bought yet")
        _ = try ListActions.add("melk 2", to: "L1", in: s)
        _ = try ListActions.add("koffie 500 g", to: "L1", in: s)
        guard case .added(let brood) = try ListActions.add("brood", to: "L1", in: s) else { return XCTFail("not added") }
        try ListActions.setHome(try XCTUnwrap(rows(s).first { $0.itemID == brood }), "G", on: "L1", in: s)
        try shop(s)
        // a second trip: more milk, and the open row that is not bought does not count
        _ = try ListActions.add("melk 3", to: "L1", in: s)
        _ = try ListActions.add("eieren", to: "L1", in: s)
        for row in try rows(s) where row.name == "melk" {
            try ListActions.toggle(row, on: "L1", in: s)
        }
        try ListActions.clear("L1", in: s)

        let months = try s.store.read(scope) { db, sc in try Queries.purchaseMonths(db, sc) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        XCTAssertEqual(months.map(\.month), [f.string(from: Date())])
        XCTAssertEqual(months.map(\.count), [4])
        let o = try s.store.read(scope) { db, sc in try Queries.purchases(db, sc, month: months[0].month) }
        XCTAssertEqual(o.total, 4)
        XCTAssertEqual(o.items.map(\.name), ["melk", "brood", "koffie"], "most bought first, then by name")
        XCTAssertEqual(o.items[0].times, 2)
        XCTAssertEqual(o.items[0].totals.map(\.text), ["5x"], "2 and 3 add up")
        XCTAssertEqual(o.items[1].totals.map(\.text), ["1x"], "no quantity counts one")
        XCTAssertEqual(o.items[2].totals.map(\.text), ["500 g"])
        XCTAssertEqual(o.homes.map { ($0.name, $0.times).0 }, ["Gouda"])
        XCTAssertEqual(o.homes.map(\.times), [1])
        XCTAssertEqual(o.people.map(\.id), ["pa"])
        XCTAssertEqual(o.people.map(\.times), [4])
        XCTAssertEqual(try s.store.read(scope) { db, sc in try Queries.purchases(db, sc, month: "1999-01") }, MonthOverview(), "an empty month is empty")
    }
}
