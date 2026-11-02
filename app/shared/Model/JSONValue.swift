// JSONValue is any JSON, for event payloads the app did not write (an unknown kind from a newer
// server is stored and skipped) and for the canonical rendering the fold tests compare by.
import Foundation

indirect enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// From Foundation's JSON objects (JSONSerialization).
    init(any v: Any) {
        switch v {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    init(data: Data) throws {
        self.init(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Serialized with sorted keys and integral numbers written as integers.
    var data: Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }

    var string: String { String(decoding: data, as: UTF8.self) }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Zero in the fold's canonical sense: null, "", 0, false, {} and [].
    var isZero: Bool {
        switch self {
        case .null: true
        case .bool(let b): !b
        case .number(let n): n == 0
        case .string(let s): s.isEmpty
        case .array(let a): a.isEmpty
        case .object(let o): o.isEmpty
        }
    }

    /// Every zero field dropped, recursively, as fold.Tables.Canonical does.
    var pruned: JSONValue {
        switch self {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                let p = v.pruned
                if !p.isZero { out[k] = p }
            }
            return .object(out)
        case .array(let a):
            return .array(a.map(\.pruned))
        default:
            return self
        }
    }
}
