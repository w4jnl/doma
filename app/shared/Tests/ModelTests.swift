// The stamps, the ids, the name key and the typed line, against the Go tests' cases.
import XCTest
@testable import Doma

final class ModelTests: XCTestCase {
    func testHLCOrderAndForm() {
        let a = HLC(parsing: "1000:0:a")!
        XCTAssertEqual(a.description, "0000000001000:0000:a")
        XCTAssertEqual(HLC(parsing: a.description), a)
        XCTAssertTrue(a < HLC(wall: 1000, counter: 1, device: "a"))
        XCTAssertTrue(a < HLC(wall: 1000, counter: 0, device: "b"))
        XCTAssertTrue(HLC(wall: 999, counter: 9, device: "z") < a)
        XCTAssertNil(HLC(parsing: "1:2"))
        XCTAssertNil(HLC(parsing: "1:2:"))
        XCTAssertNil(HLC(parsing: "1:2:a:b"))
        XCTAssertNil(HLC(parsing: "1:10000:a"))
        XCTAssertEqual(Set(["0000000001000:0000:a", "1000:0:a"].compactMap { HLC(parsing: $0) }).count, 1)
    }

    func testClockNeverGoesBack() {
        let now = Ticker(Date(timeIntervalSince1970: 1))
        let clock = HLCClock(device: "dev", now: { now.date })
        let a = clock.next()
        let b = clock.next()
        XCTAssertTrue(a < b)
        XCTAssertEqual(b.counter, 1)
        clock.observe(HLC(wall: 5000, counter: 3, device: "other"))
        let c = clock.next()
        XCTAssertEqual(c.wall, 5000)
        XCTAssertEqual(c.counter, 4)
        XCTAssertEqual(c.device, "dev")
        now.date = Date(timeIntervalSince1970: 10)
        let d = clock.next()
        XCTAssertEqual(d.wall, 10000)
        XCTAssertEqual(d.counter, 0)
    }

    func testULID() {
        let id = ULID.make(now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(id.count, 26)
        XCTAssertEqual(ULID.time(of: id), 1_700_000_000_000)
        XCTAssertTrue(id.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        XCTAssertNotEqual(ULID.make(), ULID.make())
        XCTAssertEqual(ULID.encode([UInt8](repeating: 0xFF, count: 16)), "7ZZZZZZZZZZZZZZZZZZZZZZZZZ")
        XCTAssertEqual(ULID.encode([UInt8](repeating: 0, count: 16)), String(repeating: "0", count: 26))
    }

    func testNormName() {
        let cases = ["  Olijfolie ": "olijfolie", "Crème  Fraîche": "creme fraiche", "MELK halfvol": "melk halfvol", "Žltý melón": "zlty melon", "": ""]
        for (input, want) in cases {
            XCTAssertEqual(Norm.name(input), want, input)
        }
    }

    func testParseEntry() {
        let cases: [(String, String, Double?, String, String)] = [
            ("melk 2", "melk", 2, "x", ""),
            ("2 melk", "melk", 2, "x", ""),
            ("2x melk", "melk", 2, "x", ""),
            ("2× melk", "melk", 2, "x", ""),
            ("500 g gehakt", "gehakt", 500, "g", ""),
            ("1,5 l melk", "melk", 1.5, "l", ""),
            ("melk (the small jar)", "melk", nil, "", "the small jar"),
            ("melk", "melk", nil, "", ""),
            ("gehakt 500 g", "gehakt", 500, "g", ""),
            ("eieren 12 (vrije uitloop)", "eieren", 12, "x", "vrije uitloop"),
            ("3d printer filament", "3d printer filament", nil, "", ""),
            ("2 liter melk", "liter melk", 2, "x", ""),
            ("melk 2 liter", "melk 2 liter", nil, "", ""),
            ("42", "42", nil, "", ""),
            ("  ", "", nil, "", ""),
            ("2 pak koffie", "koffie", 2, "pak", ""),
            ("koffie 2kg", "koffie", 2, "kg", ""),
        ]
        for (input, name, qty, unit, note) in cases {
            let got = EntryText.parse(input)
            XCTAssertEqual(got, ParsedEntry(name: name, qty: qty, unit: unit, note: note), input)
        }
    }

    func testCanonicalDropsZeroFields() throws {
        var t = Tables()
        t.lists = [ShoppingList(id: "L1", name: "Shopping", isDefault: true, updatedHLC: HLC(wall: 900, device: "a"))]
        t.entries = [Entry(id: "e1", listID: "L1", itemID: "I1", sort: 1002, addedHLC: HLC(wall: 1002, device: "b"), addedBy: "pb")]
        let want = Tables.canonical(expectation: try JSONValue(data: Data("""
        {"lists":[{"id":"L1","name":"Shopping","is_default":true,"updated_hlc":"900:0:a"}],
         "entries":[{"id":"e1","list_id":"L1","item_id":"I1","sort":1002,"added_hlc":"1002:0:b","added_by":"pb","note":""}]}
        """.utf8)))
        XCTAssertEqual(t.canonical, want)
        XCTAssertFalse(t.canonical.contains("colour"))
        XCTAssertTrue(t.canonical.contains("\"sort\":1002"))
    }
}

/// A clock the test moves by hand.
final class Ticker: @unchecked Sendable {
    var date: Date
    init(_ d: Date) { date = d }
}
