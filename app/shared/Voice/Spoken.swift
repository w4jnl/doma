// Spoken splits one spoken line into the items it names (docs/design.md, "iPhone and Mac
// apps", Voice). Words alone cannot say where one item ends and the next begins ("apples
// oranges" looks like "olive oil"), so two signals that can are used: the household's catalog,
// whose names are peeled off longest first, so "halfvolle melk eieren" is two items and "salt
// and pepper" one; and the separators a speaker puts between things, a comma or the language's
// "and" (and, en, a). What is left between them is one item, with any words before a catalog
// name kept with it, so "2 kilos of apples" stays whole for the typed line's parser. Typed lines
// never come here.
import Foundation

enum Spoken {
    /// The word that joins two items when spoken, per language.
    static func conjunction(_ language: Language) -> String {
        switch language {
        case .english: "and"
        case .dutch: "en"
        case .slovak: "a"
        }
    }

    /// The longest catalog name tried at a position, in words.
    static let longest = 4

    /// split gives the items in text, in the order said. names are the catalog's item names.
    static func split(_ text: String, language: Language, names: [String]) -> [String] {
        let and = conjunction(language)
        var known: [Int: Set<String>] = [:] // by word count, the normalised names
        for n in names {
            let key = Norm.name(n)
            let count = key.split(separator: " ").count
            guard count > 0, count <= longest else { continue }
            known[count, default: []].insert(key)
        }
        var items: [String] = []
        for chunk in Heard.item(text).split(whereSeparator: { ",;".contains($0) }) {
            let words = chunk.split(whereSeparator: \.isWhitespace).map(String.init)
            var rest: [String] = []
            var i = 0
            func flush() {
                let piece = rest.joined(separator: " ")
                rest = []
                if !Norm.name(piece).isEmpty { items.append(piece) }
            }
            while i < words.count {
                var took = 0
                for n in stride(from: min(longest, words.count - i), through: 1, by: -1) {
                    let key = Norm.name(words[i..<i + n].joined(separator: " "))
                    if known[n]?.contains(key) == true {
                        took = n
                        break
                    }
                }
                if took > 0 {
                    // a known name ends the item; the words before it, a quantity or a size, stay with it
                    rest.append(contentsOf: words[i..<i + took])
                    flush()
                    i += took
                } else if Norm.name(words[i]) == and {
                    flush()
                    i += 1
                } else {
                    rest.append(words[i])
                    i += 1
                }
            }
            flush()
        }
        return items
    }
}
