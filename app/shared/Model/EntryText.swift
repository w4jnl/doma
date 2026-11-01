// What a person types into the add field, split into item, quantity, unit and note: the port of
// internal/domain/qty.go, with the same unit table, so the two sides read "500 g gehakt" alike.
import Foundation

struct ParsedEntry: Equatable, Sendable {
    var name: String
    /// nil when no quantity was typed.
    var qty: Double?
    var unit: String
    var note: String
}

enum EntryText {
    /// The units the parser recognises; anything else stays in the note. "×" reads as "x".
    static let units: Set<String> = ["x", "st", "stuks", "pcs", "g", "kg", "ml", "cl", "l", "pak", "fles", "zak", "blik", "bos"]

    private static let number = try! NSRegularExpression(pattern: "^([0-9]+(?:[.,][0-9]+)?)([^0-9\\s.,]*)$")

    /// "melk 2", "2 melk", "2x melk", "500 g gehakt", "1,5 l melk" and "melk (the small jar)"
    /// give the item melk or gehakt with qty 2 / 2 / 2 / 500 / 1.5 / none and unit x / x / x /
    /// g / l / none. Nothing typed is lost.
    static func parse(_ text: String) -> ParsedEntry {
        var e = ParsedEntry(name: "", qty: nil, unit: "", note: "")
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.lastIndex(of: "("), open != s.startIndex, s.hasSuffix(")") {
            e.note = String(s[s.index(after: open)..<s.index(before: s.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
            s = String(s[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var toks = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        if let (n, unit, used) = leadingQty(toks) {
            e.qty = n
            e.unit = unit
            toks.removeFirst(used)
        } else if let (n, unit, used) = trailingQty(toks) {
            e.qty = n
            e.unit = unit
            toks.removeLast(used)
        }
        e.name = toks.joined(separator: " ")
        if e.name.isEmpty, e.qty != nil {
            // a bare number is a name, not a quantity of nothing
            e.name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            e.qty = nil
            e.unit = ""
        }
        return e
    }

    private static func parseNumber(_ tok: String) -> (Double, String)? {
        let t = tok.lowercased()
        let range = NSRange(t.startIndex..., in: t)
        guard let m = number.firstMatch(in: t, range: range),
              let numR = Range(m.range(at: 1), in: t), let sufR = Range(m.range(at: 2), in: t),
              let n = Double(t[numR].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        var suffix = String(t[sufR])
        if suffix == "×" { suffix = "x" }
        return (n, suffix)
    }

    /// "2 melk", "2x melk", "500 g gehakt", "1,5 l melk".
    private static func leadingQty(_ toks: [String]) -> (Double, String, Int)? {
        guard toks.count >= 2, let (n, suffix) = parseNumber(toks[0]) else { return nil }
        if !suffix.isEmpty {
            return units.contains(suffix) ? (n, suffix, 1) : nil
        }
        if let u = unitToken(toks[1]), toks.count > 2 {
            return (n, u, 2)
        }
        return (n, "x", 1)
    }

    /// "melk 2", "gehakt 500 g", "melk 2x".
    private static func trailingQty(_ toks: [String]) -> (Double, String, Int)? {
        guard toks.count >= 2 else { return nil }
        let last = toks[toks.count - 1]
        if let (n, suffix) = parseNumber(last) {
            if suffix.isEmpty { return (n, "x", 1) }
            return units.contains(suffix) ? (n, suffix, 1) : nil
        }
        if let u = unitToken(last), toks.count >= 3, let (n, suffix) = parseNumber(toks[toks.count - 2]), suffix.isEmpty {
            return (n, u, 2)
        }
        return nil
    }

    private static func unitToken(_ tok: String) -> String? {
        var t = tok.lowercased()
        if t == "×" { t = "x" }
        return units.contains(t) ? t : nil
    }
}
