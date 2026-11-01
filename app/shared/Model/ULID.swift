// ULID mints the ids the apps give events, items, lists and entries: 48 bits of milliseconds and
// 80 random bits in Crockford base32, 26 characters, sortable by time, as the server's.
import Foundation

enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    static func make(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(millis(now))
        for i in 0..<6 {
            bytes[i] = UInt8((ms >> (8 * UInt64(5 - i))) & 0xFF)
        }
        for i in 6..<16 {
            bytes[i] = UInt8.random(in: .min ... .max)
        }
        return encode(bytes)
    }

    /// Crockford base32 of 16 bytes, 26 characters, the first holding the top three bits.
    static func encode(_ b: [UInt8]) -> String {
        precondition(b.count == 16)
        var out = [UInt8](repeating: 0, count: 26)
        // walk the 128 bits five at a time from the most significant end
        var acc: UInt64 = 0
        var bits = 0
        var pos = 0
        var first = true
        for byte in b {
            acc = (acc << 8) | UInt64(byte)
            bits += 8
            if first {
                // 128 = 3 + 25*5: the first character holds the top three bits, so it is 0 to 7
                out[pos] = alphabet[Int((acc >> UInt64(bits - 3)) & 0x1F)]
                pos += 1
                bits -= 3
                first = false
            }
            while bits >= 5 {
                out[pos] = alphabet[Int((acc >> UInt64(bits - 5)) & 0x1F)]
                pos += 1
                bits -= 5
            }
            acc &= (1 << UInt64(bits)) - 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The millisecond timestamp an id carries, nil when it is not a ULID.
    static func time(of id: String) -> Int64? {
        guard id.count == 26 else { return nil }
        var ms: UInt64 = 0
        for ch in id.prefix(10).uppercased().utf8 {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            ms = (ms << 5) | UInt64(v)
        }
        return Int64(ms)
    }
}
