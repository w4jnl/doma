// What the screens read and do, without the screens: the lists query's order and counts, the
// rows' order, the matches, Recent, and the add field's outcomes through a session on an
// in-memory store.
import XCTest
@testable import Doma

@MainActor
final class ScreenLogicTests: XCTestCase {
    func session() throws -> Session {
        let store = try DomaStore.inMemory()
        try store.saveContext(ServerContext(serverID: "S1", baseURL: URL(string: "https://doma.example")!, credentialID: "C1", personID: "pa", displayName: "Jaro", createdAt: 1))
        try store.upsertHousehold(HouseholdRow(serverID: "S1", id: "H1", name: "De Vries", timezone: "Europe/Amsterdam", stalenessDays: nil, role: "owner"))
        let s = Session(store: store)
        XCTAssertNotNil(s.scope)
        try s.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true))
        try s.record(Kind.homeCreated, HomePayload(homeID: "G", name: "Gouda"))
        return s
    }

    func lists(_ s: Session) throws -> [ListSummary] {
        try s.store.read(s.scope!) { db, sc in try Queries.lists(db, sc) }
    }

    func rows(_ s: Session, _ list: String = "L1") throws -> [EntryRow] {
        try s.store.read(s.scope!) { db, sc in try Queries.entries(db, sc, listID: list) }
    }

    func testAddMatchesTheCatalogOrMakesTheItem() throws {
        let s = try session()
        guard case .added(let melk) = try ListActions.add("melk 2", to: "L1", in: s) else { return XCTFail("not added") }
        guard case .added(let gehakt) = try ListActions.add("500 g gehakt", to: "L1", in: s) else { return XCTFail("not added") }
        XCTAssertNotEqual(melk, gehakt)
        // the same name again, differently cased: the item is reused and the row flashes
        let again = try ListActions.add("Melk", to: "L1", in: s)
        guard case .alreadyOpen(let entryID) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(try rows(s).first { $0.itemID == melk }?.id, entryID)
        XCTAssertEqual(try rows(s).count, 2)
        XCTAssertEqual(try rows(s).first { $0.itemID == gehakt }?.detail, "500 g")
        XCTAssertEqual(try rows(s).first { $0.itemID == melk }?.detail, "2x")
        XCTAssertEqual(try ListActions.add("   ", to: "L1", in: s), .nothingTyped)
        // a note stays with the entry
        guard case .added(let eggs) = try ListActions.add("eieren 12 (vrije uitloop)", to: "L1", in: s) else { return XCTFail("not added") }
        XCTAssertEqual(try rows(s).first { $0.itemID == eggs }?.detail, "12x vrije uitloop")
        // the outbox holds item.named and entry.added pairs, and the fold made the catalog
        XCTAssertEqual(try s.store.outboxCount(s.scope!), 8)
        XCTAssertEqual(try s.store.tables(s.scope!).items.count, 3)
    }

    func testStrikeRestoreClearAndRecent() throws {
        let s = try session()
        _ = try ListActions.add("melk", to: "L1", in: s)
        _ = try ListActions.add("brood", to: "L1", in: s)
        let melk = try XCTUnwrap(rows(s).first { $0.name == "melk" })
        try ListActions.toggle(melk, on: "L1", in: s)
        var r = try rows(s)
        XCTAssertEqual(r.map(\.name), ["brood", "melk"], "struck rows sink below the open ones")
        XCTAssertTrue(r[1].isChecked)
        // adding a struck item restores it
        XCTAssertEqual(try ListActions.add("melk", to: "L1", in: s), .added(itemID: melk.itemID))
        r = try rows(s)
        XCTAssertFalse(r.first { $0.name == "melk" }!.isChecked)
        try ListActions.toggle(r.first { $0.name == "melk" }!, on: "L1", in: s)
        try ListActions.clear("L1", in: s)
        r = try rows(s)
        XCTAssertEqual(r.map(\.name), ["brood"])
        let recent = try s.store.read(s.scope!) { db, sc in try Queries.recent(db, sc, listID: "L1") }
        XCTAssertEqual(recent.map(\.name), ["melk"])
        // and re-adding from Recent opens a new era
        XCTAssertEqual(try ListActions.add(itemID: melk.itemID, to: "L1", in: s), .added(itemID: melk.itemID))
        XCTAssertEqual(try rows(s).count, 2)
        XCTAssertEqual(try s.store.tables(s.scope!).entries.count, 3, "the cleared one is the purchase record")
        XCTAssertEqual(try lists(s).first?.openCount, 2)
    }

    func testMatchesByUseThenRecency() throws {
        let s = try session()
        _ = try ListActions.add("melk", to: "L1", in: s)
        _ = try ListActions.add("melkchocolade", to: "L1", in: s)
        _ = try ListActions.add("halfvolle melk", to: "L1", in: s)
        _ = try ListActions.add("brood", to: "L1", in: s)
        // melk bought once makes it the top match
        let melk = try XCTUnwrap(rows(s).first { $0.name == "melk" })
        try ListActions.toggle(melk, on: "L1", in: s)
        try ListActions.clear("L1", in: s)
        _ = try ListActions.add("melk", to: "L1", in: s)
        let matches = try s.store.read(s.scope!) { db, sc in try Queries.matches(db, sc, prefix: "mel") }
        XCTAssertEqual(matches.first?.name, "melk")
        XCTAssertNotNil(matches.first?.lastBought)
        XCTAssertEqual(Set(matches.map(\.name)), ["melk", "melkchocolade", "halfvolle melk"], "any word's prefix matches")
        XCTAssertEqual(try s.store.read(s.scope!) { db, sc in try Queries.matches(db, sc, prefix: "x") }, [])
    }

    func testPersonalListsAreMineOnly() throws {
        let s = try session()
        let mine = try XCTUnwrap(ListActions.createList(named: "Weekend", personal: true, colour: "list-4", in: s))
        try ListActions.createList(named: "Hut", personal: false, colour: "list-2", in: s)
        // another person's personal list, as the server would never send it but the store could hold it
        try s.store.applyRemote([SyncEvent(seq: 99, id: "x", personID: "pb", hlc: "9999999999999:0:b", kind: Kind.listCreated, payload: ListPayload(listID: "L9", name: "Theirs", ownerPersonID: "pb").jsonValue)], scope: s.scope!, clock: nil)
        let all = try lists(s)
        XCTAssertEqual(all.map(\.name), ["Shopping", "Hut", "Weekend"], "shared first, the default list first of those, then mine")
        XCTAssertEqual(all.first { $0.id == mine }?.isPersonal, true)
        XCTAssertEqual(all.map(\.colour), ["", "list-2", "list-4"], "the default list has no colour of its own")
        try ListActions.renameList(mine, to: "Weekend away", colour: "list-4", in: s)
        XCTAssertEqual(try lists(s).first { $0.id == mine }.map { ($0.name, $0.colour) }?.0, "Weekend away")
        XCTAssertEqual(try lists(s).first { $0.id == mine }?.colour, "list-4", "a rename keeps the colour")
        try ListActions.archiveList(mine, in: s)
        XCTAssertEqual(try lists(s).map(\.name), ["Shopping", "Hut"])
    }

    func testMenuActions() throws {
        let s = try session()
        _ = try ListActions.add("olijfolie", to: "L1", in: s)
        _ = try ListActions.add("olive oil", to: "L1", in: s)
        var r = try rows(s)
        let oil = r.first { $0.name == "olijfolie" }!
        try ListActions.setHome(oil, "G", on: "L1", in: s)
        XCTAssertEqual(try rows(s).first { $0.name == "olijfolie" }?.homeName, "Gouda")
        try ListActions.rename(oil, to: "Olijfolie extra", in: s)
        r = try rows(s)
        XCTAssertEqual(r.map(\.name).sorted(), ["Olijfolie extra", "olive oil"])
        try ListActions.merge(r.first { $0.name == "olive oil" }!, into: oil.itemID, in: s)
        r = try rows(s)
        XCTAssertEqual(r.count, 1, "one item now, one open entry")
        XCTAssertEqual(r[0].itemID, oil.itemID)
        try ListActions.toggle(r[0], on: "L1", in: s)
        try ListActions.edit(try rows(s)[0], text: "2 l", on: "L1", in: s)
        XCTAssertEqual(try rows(s)[0].detail, "2 l")
        XCTAssertTrue(try rows(s)[0].isChecked, "Bought keeps the check")
        let others = try s.store.read(s.scope!) { db, sc in try Queries.otherItems(db, sc, listID: "L1", except: oil.itemID) }
        XCTAssertEqual(others, [])
    }

    func testMoveSetsSortBetweenNeighbours() throws {
        let s = try session()
        _ = try ListActions.add("a", to: "L1", in: s)
        _ = try ListActions.add("b", to: "L1", in: s)
        _ = try ListActions.add("c", to: "L1", in: s)
        var r = try rows(s)
        XCTAssertEqual(r.map(\.name), ["a", "b", "c"])
        try ListActions.move(r, from: IndexSet(integer: 2), to: 0, on: "L1", in: s)
        r = try rows(s)
        XCTAssertEqual(r.map(\.name), ["c", "a", "b"])
        try ListActions.move(r, from: IndexSet(integer: 0), to: 3, on: "L1", in: s)
        XCTAssertEqual(try rows(s).map(\.name), ["a", "b", "c"])
    }
}
