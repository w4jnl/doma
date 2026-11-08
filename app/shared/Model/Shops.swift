// The bundled shop table (docs/design.md, "Add a card"): for each chain the name, its website's
// domain and the countries it trades in, from OpenStreetMap's Name Suggestion Index through
// scripts/shops/gen.py. It suggests names as a card's shop is typed, the device's region first,
// and hands the logo job a website. Names and websites only; no logo is bundled.
import Foundation

struct Shop: Hashable, Sendable, Identifiable {
    var name: String
    var domain: String?
    /// ISO country codes, lowercase; ["eu"] for a chain found everywhere.
    var countries: [String]
    var id: String { name + "|" + (domain ?? "") }
}

enum Shops {
    /// Every shop in the table, read once from the app's bundle.
    nonisolated(unsafe) static var all: [Shop] = load()

    private struct File: Decodable {
        struct Row: Decodable {
            var n: String
            var d: String?
            var c: [String]
        }
        var shops: [Row]
    }

    nonisolated static func load(from url: URL? = Bundle.main.url(forResource: "shops", withExtension: "json")) -> [Shop] {
        guard let url, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.shops.map { Shop(name: $0.n, domain: $0.d, countries: $0.c) }
    }

    /// The shops whose name starts with what was typed, or has a word that does: the region's
    /// own first, then the rest, by name; at most `limit`.
    nonisolated static func suggest(_ typed: String, region: String? = Locale.current.region?.identifier, limit: Int = 6, in table: [Shop] = all) -> [Shop] {
        let p = Norm.name(typed)
        guard !p.isEmpty else { return [] }
        let here = region?.lowercased()
        func rank(_ s: Shop) -> Int {
            guard let here else { return 1 }
            if s.countries.contains(here) { return 0 }
            return s.countries == ["eu"] ? 1 : 2
        }
        let hits = table.filter { s in
            let n = Norm.name(s.name)
            return n.hasPrefix(p) || n.contains(" " + p)
        }
        return Array(hits.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            let pa = Norm.name(a.name).hasPrefix(p), pb = Norm.name(b.name).hasPrefix(p)
            if pa != pb { return pa }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.prefix(limit))
    }
}
