// The events this app writes against docs/event-schema.json, read by path: every kind's typed
// payload, the envelope, and what the schema refuses. The checker covers the subset the file
// uses: type, required, properties, pattern, enum, minLength, maxLength, minimum, maxItems,
// items, anyOf and $ref into $defs.
import XCTest
@testable import Doma

final class EventSchemaTests: XCTestCase {
    static let schema: JSONValue = {
        let url = Fixture.root.appendingPathComponent("docs/event-schema.json")
        return try! JSONValue(data: Data(contentsOf: url))
    }()

    /// A sample payload per kind, as the app builds them.
    static let samples: [(String, any Encodable & Sendable)] = [
        (Kind.itemNamed, ItemPayload(itemID: "01JBX0000000000000000000AA", name: "melk")),
        (Kind.itemRenamed, ItemPayload(itemID: "I1", name: "halfvolle melk")),
        (Kind.itemMerged, ItemPayload(keepID: "I1", dropID: "I2")),
        (Kind.listCreated, ListPayload(listID: "L1", name: "Weekend", colour: "teal", ownerPersonID: "P1", isDefault: false)),
        (Kind.listRenamed, ListPayload(listID: "L1", name: "Hut", colour: "")),
        (Kind.listArchived, ListPayload(listID: "L1")),
        (Kind.entryAdded, EntryPayload(listID: "L1", itemID: "I1", note: "the small jar", qty: 1.5, unit: "l", forHomeID: "H1")),
        (Kind.entryEdited, EntryPayload(listID: "L1", itemID: "I1", note: "", qty: 2, unit: "x")),
        (Kind.entryChecked, EntryPayload(listID: "L1", itemID: "I1")),
        (Kind.entryUnchecked, EntryPayload(listID: "L1", itemID: "I1")),
        (Kind.entryCleared, EntryPayload(listID: "L1", beforeHLC: HLC(wall: 1_700_000_000_000, counter: 3, device: "01JBX0000000000000000000AA").description)),
        (Kind.entryMoved, EntryPayload(listID: "L1", itemID: "I1", sort: 1234.5)),
        (Kind.flagSet, FlagPayload(homeID: "H1", itemID: "I1", state: "out", note: "")),
        (Kind.stapleAdded, StaplePayload(homeID: "H1", itemID: "I1", sort: 3)),
        (Kind.stapleRemoved, StaplePayload(homeID: "H1", itemID: "I1")),
        (Kind.homeCreated, HomePayload(homeID: "H1", name: "Gouda")),
        (Kind.homeRenamed, HomePayload(homeID: "H1", name: "Thuis")),
        (Kind.homeArchived, HomePayload(homeID: "H1")),
        (Kind.spotCreated, SpotPayload(spotID: "S1", homeID: "H1", name: "Pantry")),
        (Kind.spotRenamed, SpotPayload(spotID: "S1", name: "Larder")),
        (Kind.spotArchived, SpotPayload(spotID: "S1")),
        (Kind.photoAdded, PhotoPayload(photoID: "PH1", spotID: "S1", bytes: 1200, width: 1600, height: 1200)),
        (Kind.tripArrived, TripPayload(tripID: "T1", fromHomeID: "H1", toHomeID: "H2", moved: ["I1", "I2"])),
    ]

    func testEveryPayloadTheAppWritesIsValid() throws {
        let kinds = try XCTUnwrap(Self.schema["kinds"])
        var covered = Set<String>()
        for (kind, payload) in Self.samples {
            let rule = try XCTUnwrap(kinds[kind], kind)
            let problems = Validator(schema: Self.schema).check(payload.jsonValue, against: rule, at: kind)
            XCTAssertEqual(problems, [], kind)
            covered.insert(kind)
            let envelope: JSONValue = .object(["id": .string(ULID.make()), "household_id": .string("H1"), "hlc": .string(HLC(wall: 1, device: "d").description), "kind": .string(kind), "payload": payload.jsonValue])
            XCTAssertEqual(Validator(schema: Self.schema).check(envelope, against: Self.schema["envelope"]!, at: "envelope"), [])
        }
        if case .object(let all) = kinds {
            for k in all.keys where k != Kind.memberRemoved && k != Kind.deviceRevoked {
                XCTAssertTrue(covered.contains(k), "no sample for \(k)")
            }
        }
    }

    func testTheSchemaRefusesWhatItShould() throws {
        let v = Validator(schema: Self.schema)
        let kinds = Self.schema["kinds"]!
        XCTAssertFalse(v.check(.object(["item_id": .string("I1")]), against: kinds[Kind.itemNamed]!, at: "x").isEmpty, "name required")
        XCTAssertFalse(v.check(.object(["home_id": .string("H1"), "item_id": .string("I1"), "state": .string("gone")]), against: kinds[Kind.flagSet]!, at: "x").isEmpty, "state enum")
        XCTAssertFalse(v.check(.object(["list_id": .string("L1"), "item_id": .string("I1"), "qty": .number(-1)]), against: kinds[Kind.entryAdded]!, at: "x").isEmpty, "qty minimum")
        XCTAssertFalse(v.check(.object(["list_id": .string("L1"), "before_hlc": .string("nope")]), against: kinds[Kind.entryCleared]!, at: "x").isEmpty, "hlc pattern")
        XCTAssertTrue(v.check(.object(["list_id": .string("L1"), "item_id": .string("I1"), "qty": .null, "unit": .null]), against: kinds[Kind.entryAdded]!, at: "x").isEmpty, "nulls allowed")
    }
}

/// Enough of JSON Schema for docs/event-schema.json.
struct Validator {
    let schema: JSONValue

    func check(_ v: JSONValue, against rule: JSONValue, at path: String) -> [String] {
        var out: [String] = []
        if let ref = rule["$ref"]?.stringValue {
            let name = ref.replacingOccurrences(of: "#/$defs/", with: "")
            guard let target = schema["$defs"]?[name] else { return ["\(path): unknown $ref \(ref)"] }
            return check(v, against: target, at: path)
        }
        if case .array(let options)? = rule["anyOf"] {
            if options.allSatisfy({ !check(v, against: $0, at: path).isEmpty }) {
                out.append("\(path): matches none of anyOf")
            }
            return out
        }
        if let type = rule["type"]?.stringValue {
            let ok: Bool
            switch type {
            case "object": if case .object = v { ok = true } else { ok = false }
            case "string": if case .string = v { ok = true } else { ok = false }
            case "number": if case .number = v { ok = true } else { ok = false }
            case "integer": if case .number(let n) = v, n == n.rounded() { ok = true } else { ok = false }
            case "boolean": if case .bool = v { ok = true } else { ok = false }
            case "array": if case .array = v { ok = true } else { ok = false }
            case "null": ok = v.isNull
            default: ok = false
            }
            if !ok { return ["\(path): not a \(type)"] }
        }
        if case .array(let allowed)? = rule["enum"], !allowed.contains(v) {
            out.append("\(path): not in enum")
        }
        if case .string(let s) = v {
            if let p = rule["pattern"]?.stringValue, s.range(of: p, options: .regularExpression) == nil {
                out.append("\(path): does not match \(p)")
            }
            if case .number(let min)? = rule["minLength"], s.count < Int(min) { out.append("\(path): too short") }
            if case .number(let max)? = rule["maxLength"], s.count > Int(max) { out.append("\(path): too long") }
        }
        if case .number(let n) = v, case .number(let min)? = rule["minimum"], n < min {
            out.append("\(path): below minimum")
        }
        if case .array(let items) = v {
            if case .number(let max)? = rule["maxItems"], items.count > Int(max) { out.append("\(path): too many") }
            if let itemRule = rule["items"] {
                for (i, item) in items.enumerated() { out += check(item, against: itemRule, at: "\(path)[\(i)]") }
            }
        }
        if case .object(let o) = v {
            if case .array(let required)? = rule["required"] {
                for r in required.compactMap(\.stringValue) where o[r] == nil {
                    out.append("\(path): missing \(r)")
                }
            }
            if case .object(let props)? = rule["properties"] {
                for (k, val) in o {
                    if let r = props[k] { out += check(val, against: r, at: "\(path).\(k)") }
                }
            }
        }
        return out
    }
}
