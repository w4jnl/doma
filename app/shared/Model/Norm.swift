// The catalog key of an item name, the port of internal/domain/norm.go: lowercased, diacritics
// stripped (NFD, the combining marks removed, NFC), whitespace collapsed. "Olijfolie " and
// "olijfolie" are one item, and so are "Crème Fraîche" and "creme fraiche".
import Foundation

enum Norm {
    static func name(_ s: String) -> String {
        let stripped = String(String.UnicodeScalarView(s.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            $0.properties.generalCategory != .nonspacingMark
        })).precomposedStringWithCanonicalMapping
        return stripped.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
