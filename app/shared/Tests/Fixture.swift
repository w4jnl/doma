// What the fold tests share: docs/fixtures/fold.json read by path, the permutations, and a
// generator of plausible household timelines (internal/fold/foldtest).
import Foundation
import XCTest
@testable import Doma

enum Fixture {
    /// The repository root: app/shared/Tests is three levels under it.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Case {
        var name: String
        var events: [Event]
        var expect: JSONValue
    }

    static func load() throws -> [Case] {
        let data = try Data(contentsOf: root.appendingPathComponent("docs/fixtures/fold.json"))
        let v = try JSONValue(data: data)
        guard case .array(let cases)? = v["cases"] else { throw NSError(domain: "fixture", code: 1) }
        return try cases.map { c in
            guard case .array(let evs)? = c["events"], let name = c["name"]?.stringValue, let expect = c["expect"] else {
                throw NSError(domain: "fixture", code: 2)
            }
            let events = try evs.map { try JSONDecoder().decode(Event.self, from: $0.data) }
            return Case(name: name, events: events, expect: expect)
        }
    }

    /// Every permutation of n up to seven, and otherwise the identity, the reverse and random
    /// shuffles.
    static func orders(_ n: Int, shuffles: Int, rng: inout some RandomNumberGenerator) -> [[Int]] {
        var identity = Array(0..<n)
        if n <= 7 {
            var out: [[Int]] = []
            func permute(_ k: Int) {
                if k == n {
                    out.append(identity)
                    return
                }
                for i in k..<n {
                    identity.swapAt(k, i)
                    permute(k + 1)
                    identity.swapAt(k, i)
                }
            }
            permute(0)
            return out
        }
        var out = [identity, Array(identity.reversed())]
        for _ in 0..<shuffles {
            out.append(identity.shuffled(using: &rng))
        }
        return out
    }

    static func fold(_ events: [Event]) throws -> Tables {
        let s = MemStore()
        for e in events { try s.append(e) }
        return s.tables
    }

    // MARK: A timeline

    static let names = ["melk", "Melk", "brood", "olijfolie", "olive oil", "koffie", "eieren"]
    static let itemIDs = ["I1", "I2", "I3", "I4"]
    static let listIDs = ["L1", "L2"]
    static let homeIDs = ["H1", "H2"]
    static let persons = ["pa", "pb"]

    /// n events in a timeline where each device's stamps increase, with the kinds a family
    /// produces, including the awkward ones: namesakes, renames into existing names, merges,
    /// re-adds after clears, out flags and trips.
    static func generate(_ n: Int, rng: inout some RandomNumberGenerator) -> [Event] {
        var wall: Int64 = 1000
        var out: [Event] = []
        var created = Set<String>()
        func stamp(_ dev: Int) -> HLC {
            wall += Int64(Int.random(in: 1...50, using: &rng))
            return HLC(wall: wall, device: dev == 0 ? "a" : "b")
        }
        func add(_ dev: Int, _ kind: String, _ payload: [String: JSONValue]) {
            if kind == Kind.listCreated, let id = payload["list_id"]?.stringValue {
                if created.contains(id) { return }
                created.insert(id)
            }
            out.append(Event(id: String(format: "e%03d", out.count), personID: persons[dev], hlc: stamp(dev), kind: kind, payload: .object(payload)))
        }
        func pick(_ xs: [String]) -> String { xs.randomElement(using: &rng)! }
        if Int.random(in: 0..<4, using: &rng) > 0 {
            add(0, Kind.homeCreated, ["home_id": .string("H1"), "name": .string("Gouda")])
            add(0, Kind.homeCreated, ["home_id": .string("H2"), "name": .string("Hut")])
            add(0, Kind.listCreated, ["list_id": .string("L1"), "name": .string("Boodschappen"), "default": .bool(true)])
        }
        while out.count < n {
            let dev = Int.random(in: 0..<2, using: &rng)
            switch Int.random(in: 0..<20, using: &rng) {
            case 0, 1, 2:
                add(dev, Kind.itemNamed, ["item_id": .string(pick(itemIDs)), "name": .string(pick(names))])
            case 3:
                add(dev, Kind.itemRenamed, ["item_id": .string(pick(itemIDs)), "name": .string(pick(names))])
            case 4:
                add(dev, Kind.itemMerged, ["keep_id": .string(pick(itemIDs)), "drop_id": .string(pick(itemIDs))])
            case 5:
                let id = pick(listIDs)
                add(dev, Kind.listCreated, ["list_id": .string(id), "name": .string(pick(["Weekend", "Hut"])), "default": .bool(id == "L1")])
            case 6, 7, 8:
                var p: [String: JSONValue] = ["list_id": .string(pick(listIDs)), "item_id": .string(pick(itemIDs))]
                if Bool.random(using: &rng) {
                    p["qty"] = .number(Double(Int.random(in: 1...5, using: &rng)))
                    p["unit"] = .string(pick(["x", "g", "l"]))
                }
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    p["for_home_id"] = .string(pick(homeIDs))
                }
                add(dev, Kind.entryAdded, p)
            case 9, 10:
                add(dev, Kind.entryChecked, ["list_id": .string(pick(listIDs)), "item_id": .string(pick(itemIDs))])
            case 11:
                add(dev, Kind.entryUnchecked, ["list_id": .string(pick(listIDs)), "item_id": .string(pick(itemIDs))])
            case 12, 13:
                let before = HLC(wall: wall - Int64(Int.random(in: 0..<80, using: &rng)), device: dev == 0 ? "a" : "b")
                add(dev, Kind.entryCleared, ["list_id": .string(pick(listIDs)), "before_hlc": .string(before.description)])
            case 14:
                add(dev, Kind.entryEdited, ["list_id": .string(pick(listIDs)), "item_id": .string(pick(itemIDs)), "qty": .number(Double(Int.random(in: 1...9, using: &rng))), "unit": .string("x"), "note": .string("edited")])
            case 15:
                add(dev, Kind.entryMoved, ["list_id": .string(pick(listIDs)), "item_id": .string(pick(itemIDs)), "sort": .number(Double(Int.random(in: 0..<10, using: &rng)))])
            case 16:
                add(dev, Kind.flagSet, ["home_id": .string(pick(homeIDs)), "item_id": .string(pick(itemIDs)), "state": .string(pick(["have", "low", "out", "out"]))])
            case 17:
                add(dev, pick([Kind.stapleAdded, Kind.stapleRemoved]), ["home_id": .string(pick(homeIDs)), "item_id": .string(pick(itemIDs))])
            case 18:
                add(dev, Kind.listRenamed, ["list_id": .string(pick(listIDs)), "name": .string(pick(["Weekend", "Hut", "Cabin"])), "colour": .string("teal")])
            default:
                add(dev, Kind.tripArrived, ["trip_id": .string("T\(out.count)"), "from_home_id": .string("H1"), "to_home_id": .string("H2"), "moved": .array([.string(pick(itemIDs)), .string(pick(itemIDs))])])
            }
        }
        return out
    }
}

/// A small deterministic generator (SplitMix64), so a failing seed reproduces.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
