// HLC is a hybrid logical clock stamp, wall_ms:counter:device, the port of internal/domain/hlc.go.
// Stamps order by wall time, then counter, then device id, and the string form is zero-padded so
// SQLite's ORDER BY hlc agrees with <. Events are ordered by these, never by device wall time.
import Foundation

struct HLC: Hashable, Sendable, Codable, CustomStringConvertible {
    var wall: Int64
    var counter: Int
    var device: String

    static let wallDigits = 13
    static let counterDigits = 4
    static let maxCounter = 9999

    init(wall: Int64, counter: Int = 0, device: String) {
        self.wall = wall
        self.counter = counter
        self.device = device
    }

    /// Parses the string form, short or padded. The device id is non-empty and free of colons.
    init?(parsing s: String) {
        let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[2].isEmpty, !parts[2].contains(":"),
              let wall = Int64(parts[0]), wall >= 0,
              let counter = Int(parts[1]), counter >= 0, counter <= Self.maxCounter
        else { return nil }
        self.init(wall: wall, counter: counter, device: String(parts[2]))
    }

    /// The zero-padded form.
    var description: String {
        let w = String(wall), c = String(counter)
        return String(repeating: "0", count: max(0, Self.wallDigits - w.count)) + w + ":"
            + String(repeating: "0", count: max(0, Self.counterDigits - c.count)) + c + ":" + device
    }

    var isZero: Bool { wall == 0 && counter == 0 && device.isEmpty }

    /// The wall part as a date.
    var date: Date { Date(timeIntervalSince1970: Double(wall) / 1000) }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let h = HLC(parsing: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid hlc \(s)"))
        }
        self = h
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

extension HLC: Comparable {
    static func < (a: HLC, b: HLC) -> Bool {
        if a.wall != b.wall { return a.wall < b.wall }
        if a.counter != b.counter { return a.counter < b.counter }
        // byte order, as the server compares
        return a.device.utf8.lexicographicallyPrecedes(b.device.utf8)
    }
}

/// Unix milliseconds of a date, as the server stores times.
func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded(.down)) }

/// HLCClock mints stamps for one device: never behind the wall clock, never behind a stamp it
/// has observed, strictly increasing. The device id is the credential id on the server.
final class HLCClock: @unchecked Sendable {
    let device: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var last = HLC(wall: 0, counter: 0, device: "")

    init(device: String, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(!device.isEmpty && !device.contains(":"), "hlc device id must be non-empty and free of colons")
        self.device = device
        self.now = now
    }

    /// A stamp after every stamp this clock has minted or observed.
    func next() -> HLC {
        lock.lock()
        defer { lock.unlock() }
        let wall = millis(now())
        var n = HLC(wall: wall, counter: 0, device: device)
        if wall <= last.wall {
            n.wall = last.wall
            n.counter = last.counter + 1
            if n.counter > HLC.maxCounter {
                n.wall += 1
                n.counter = 0
            }
        }
        last = n
        return n
    }

    /// Moves the clock past a stamp received from elsewhere.
    func observe(_ h: HLC) {
        lock.lock()
        defer { lock.unlock() }
        if last < h {
            last = HLC(wall: h.wall, counter: h.counter, device: device)
        }
    }
}
