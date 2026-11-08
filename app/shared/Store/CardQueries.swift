// What the Cards screens read: the household's cards and the person's own, not archived, with
// the logo the server fetched when there is one. Another person's private card is never in
// this store: the sync filter keeps it on their devices.
import Foundation
import GRDB

struct CardRow: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var colour: String
    var isPersonal: Bool
    var format: String
    var value: String
    var domain: String?
    var logoID: String?

    /// The letters on the tile when there is no logo: the initials of the first two words.
    var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? String(name.prefix(2)) : letters.uppercased()
    }

    init(row r: Row) {
        id = r["id"]
        name = r["name"]
        colour = r["colour"]
        isPersonal = (r["owner_person_id"] as String?) != nil
        format = r["format"]
        value = r["value"]
        domain = r["domain"]
        logoID = r["logo_id"]
    }

    init(id: String, name: String, colour: String = "", isPersonal: Bool = false, format: String, value: String, domain: String? = nil, logoID: String? = nil) {
        self.id = id
        self.name = name
        self.colour = colour
        self.isPersonal = isPersonal
        self.format = format
        self.value = value
        self.domain = domain
        self.logoID = logoID
    }
}

extension Queries {
    private static let cardColumns = "id, name, colour, owner_person_id, format, value, domain, logo_id"

    /// The cards the person may see, by name.
    static func cards(_ db: Database, _ s: Scope) throws -> [CardRow] {
        try Row.fetchAll(db, sql: """
            SELECT \(cardColumns) FROM cards
            WHERE server_id = ? AND household_id = ? AND archived_at IS NULL AND (owner_person_id IS NULL OR owner_person_id = ?)
            ORDER BY name COLLATE NOCASE, id
            """, arguments: [s.serverID, s.householdID, s.personID]).map(CardRow.init(row:))
    }

    static func card(_ db: Database, _ s: Scope, id: String) throws -> CardRow? {
        try Row.fetchOne(db, sql: """
            SELECT \(cardColumns) FROM cards
            WHERE server_id = ? AND household_id = ? AND id = ? AND (owner_person_id IS NULL OR owner_person_id = ?)
            """, arguments: [s.serverID, s.householdID, id, s.personID]).map(CardRow.init(row:))
    }

    /// How many cards the person may see, for the row on the Lists overview.
    static func cardCount(_ db: Database, _ s: Scope) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM cards
            WHERE server_id = ? AND household_id = ? AND archived_at IS NULL AND (owner_person_id IS NULL OR owner_person_id = ?)
            """, arguments: [s.serverID, s.householdID, s.personID]) ?? 0
    }
}
