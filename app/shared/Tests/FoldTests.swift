// The fold against docs/fixtures/fold.json, in every order of each case's events, and against
// random timelines in random orders: the same tests the Go fold passes.
import XCTest
@testable import Doma

final class FoldTests: XCTestCase {
    func testFixtureInEveryOrder() throws {
        let cases = try Fixture.load()
        XCTAssertGreaterThan(cases.count, 10)
        var rng = SeededRNG(seed: 7)
        for c in cases {
            let want = Tables.canonical(expectation: c.expect)
            for order in Fixture.orders(c.events.count, shuffles: 40, rng: &rng) {
                let got = try Fixture.fold(order.map { c.events[$0] }).canonical
                if got != want {
                    XCTFail("\(c.name): order \(order)\n got \(got)\nwant \(want)")
                    break
                }
            }
        }
    }

    func testEveryKindIsInTheFixture() throws {
        let kinds = Set(try Fixture.load().flatMap { $0.events.map(\.kind) })
        for k in Kind.all where k != Kind.memberRemoved && k != Kind.deviceRevoked {
            XCTAssertTrue(kinds.contains(k), k)
        }
    }

    func testDuplicateIDsApplyOnce() throws {
        let c = try XCTUnwrap(Fixture.load().first { $0.name.hasPrefix("duplicate ids") })
        let s = MemStore()
        for e in c.events + c.events { try s.append(e) }
        XCTAssertEqual(s.tables.canonical, Tables.canonical(expectation: c.expect))
    }

    func testRandomOrdersConverge() throws {
        for seed in 0..<40 {
            var rng = SeededRNG(seed: UInt64(seed))
            let events = Fixture.generate(40, rng: &rng)
            let want = try Fixture.fold(events).canonical
            for _ in 0..<6 {
                let perm = Array(0..<events.count).shuffled(using: &rng)
                let got = try Fixture.fold(perm.map { events[$0] }).canonical
                if got != want {
                    XCTFail("seed \(seed) diverged for order \(perm)\n got \(got)\nwant \(want)")
                    return
                }
            }
        }
    }

    func testBadPayloadIsAnError() {
        let s = MemStore()
        let e = Event(id: "x", personID: "pa", hlc: HLC(wall: 1, device: "a"), kind: Kind.flagSet,
                      payload: .object(["home_id": .string("H1"), "item_id": .string("I1"), "state": .string("gone")]))
        XCTAssertThrowsError(try s.append(e))
    }

    func testUnknownKindIsSkipped() throws {
        let s = MemStore()
        try s.append(Event(id: "x", personID: "pa", hlc: HLC(wall: 1, device: "a"), kind: "robot.danced", payload: .object(["wild": .bool(true)])))
        XCTAssertEqual(s.tables, Tables())
    }

    /// A phone that joined through a snapshot has the tables and not the log: later events on a
    /// key must build on the base rows, not drop them.
    func testBaseRowsSurviveLaterEvents() throws {
        let full = MemStore()
        let a = HLC(wall: 1000, device: "a")
        try full.append(Event(id: "l1", personID: "pa", hlc: HLC(wall: 900, device: "a"), kind: Kind.listCreated, payload: .object(["list_id": .string("L1"), "name": .string("Shopping"), "default": .bool(true)])))
        try full.append(Event(id: "h1", personID: "pa", hlc: HLC(wall: 901, device: "a"), kind: Kind.homeCreated, payload: .object(["home_id": .string("H1"), "name": .string("Gouda")])))
        try full.append(Event(id: "i1", personID: "pa", hlc: a, kind: Kind.itemNamed, payload: .object(["item_id": .string("I1"), "name": .string("melk")])))
        try full.append(Event(id: "e1", personID: "pa", hlc: HLC(wall: 1001, device: "a"), kind: Kind.entryAdded, payload: .object(["list_id": .string("L1"), "item_id": .string("I1"), "note": .string("2x")])))
        try full.append(Event(id: "f1", personID: "pa", hlc: HLC(wall: 1002, device: "a"), kind: Kind.flagSet, payload: .object(["home_id": .string("H1"), "item_id": .string("I1"), "state": .string("low")])))
        let later: [Event] = [
            Event(id: "c1", personID: "pb", hlc: HLC(wall: 2000, device: "b"), kind: Kind.entryChecked, payload: .object(["list_id": .string("L1"), "item_id": .string("I1")])),
            Event(id: "i2", personID: "pb", hlc: HLC(wall: 2001, device: "b"), kind: Kind.itemNamed, payload: .object(["item_id": .string("I2"), "name": .string("Melk")])),
            Event(id: "e2", personID: "pb", hlc: HLC(wall: 2002, device: "b"), kind: Kind.entryAdded, payload: .object(["list_id": .string("L1"), "item_id": .string("I2"), "note": .string("the big one")])),
            Event(id: "x1", personID: "pb", hlc: HLC(wall: 2003, device: "b"), kind: Kind.entryCleared, payload: .object(["list_id": .string("L1"), "before_hlc": .string(HLC(wall: 2003, device: "b").description)])),
            Event(id: "s1", personID: "pb", hlc: HLC(wall: 2004, device: "b"), kind: Kind.stapleAdded, payload: .object(["home_id": .string("H1"), "item_id": .string("I1")])),
        ]
        let fromSnapshot = MemStore(base: full.tables)
        for e in later {
            try full.append(e)
            try fromSnapshot.append(e)
        }
        XCTAssertEqual(fromSnapshot.tables.canonical, full.tables.canonical)
        // the namesake merged into the base item, the entry was re-added and not cleared, the flag stands
        XCTAssertEqual(fromSnapshot.tables.items.first { $0.id == "I2" }?.mergedInto, "I1")
        XCTAssertEqual(fromSnapshot.tables.entries.count, 1)
        XCTAssertNil(fromSnapshot.tables.entries[0].clearedHLC)
        XCTAssertEqual(fromSnapshot.tables.flags.first?.state, "low")
    }
}
