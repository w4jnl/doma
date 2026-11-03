// What the screens read: lists with their open counts, a list's rows, the recent purchases,
// the catalog matches under the add field, the homes. Every query is scoped to one household on
// one server and reads the materialised tables only.
import Foundation
import GRDB

struct ListSummary: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isPersonal: Bool
    var isDefault: Bool
    var openCount: Int
    var colour: String
}

struct EntryRow: Identifiable, Hashable, Sendable {
    var id: String
    var itemID: String
    var name: String
    var note: String
    var qty: Double?
    var unit: String?
    var forHomeID: String?
    var homeName: String?
    var sort: Double
    var addedHLC: HLC
    var checkedHLC: HLC?
    /// Who added it and who struck it: person ids from the events, named by the screen.
    var addedBy: String = ""
    var checkedBy: String?

    var isChecked: Bool { checkedHLC != nil }

    /// "2x", "500 g", "1.5 l": the quantity and unit, or empty.
    var quantity: String {
        guard let q = qty else { return "" }
        let n = q == q.rounded() ? String(Int64(q)) : String(q)
        let u = unit ?? "x"
        return u == "x" ? n + "x" : n + " " + u
    }

    /// The quantity with the note after it: what VoiceOver reads after the item.
    var detail: String {
        [quantity, note].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct RecentRow: Identifiable, Hashable, Sendable {
    var id: String { itemID }
    var itemID: String
    var name: String
    var clearedAt: Int64
}

struct Match: Identifiable, Hashable, Sendable {
    var id: String { itemID }
    var itemID: String
    var name: String
    var useCount: Int64
    var lastBought: Int64?
}

struct HomeRow: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
}

enum Queries {
    static let matchLimit = 8
    static let recentLimit = 30

    /// Shared lists first, then the person's own, each with its open count: entries still to
    /// get. Archived lists and other people's personal lists are left out.
    static func lists(_ db: Database, _ s: Scope) throws -> [ListSummary] {
        try Row.fetchAll(db, sql: """
            SELECT l.id, l.name, l.owner_person_id, l.is_default, l.colour,
              (SELECT COUNT(*) FROM entries e WHERE e.server_id = l.server_id AND e.household_id = l.household_id AND e.list_id = l.id AND e.cleared_hlc IS NULL AND e.checked_hlc IS NULL) AS open_count
            FROM lists l
            WHERE l.server_id = ? AND l.household_id = ? AND l.archived_at IS NULL AND (l.owner_person_id IS NULL OR l.owner_person_id = ?)
            ORDER BY l.owner_person_id IS NOT NULL, l.is_default DESC, l.sort, l.name COLLATE NOCASE, l.id
            """, arguments: [s.serverID, s.householdID, s.personID]).map { r in
            ListSummary(id: r["id"], name: r["name"], isPersonal: (r["owner_person_id"] as String?) != nil, isDefault: (r["is_default"] as Int64) != 0, openCount: r["open_count"], colour: r["colour"])
        }
    }

    static func list(_ db: Database, _ s: Scope, id: String) throws -> ListSummary? {
        try lists(db, s).first { $0.id == id }
    }

    /// A list's rows that are not cleared: the open ones by their order, then the struck ones
    /// newest first. The item's name comes from the catalog; a merged id reads through.
    static func entries(_ db: Database, _ s: Scope, listID: String) throws -> [EntryRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.*, COALESCE(o.name, i.name, '') AS item_name, h.name AS home_name
            FROM entries e
            LEFT JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = e.item_id
            LEFT JOIN items o ON o.server_id = i.server_id AND o.household_id = i.household_id AND o.id = i.merged_into
            LEFT JOIN homes h ON h.server_id = e.server_id AND h.household_id = e.household_id AND h.id = e.for_home_id
            WHERE e.server_id = ? AND e.household_id = ? AND e.list_id = ? AND e.cleared_hlc IS NULL
            """, arguments: [s.serverID, s.householdID, listID]).map { r in
            EntryRow(id: r["id"], itemID: r["item_id"], name: r["item_name"], note: r["note"], qty: r["qty"], unit: r["unit"], forHomeID: r["for_home_id"], homeName: r["home_name"],
                     sort: r["sort"], addedHLC: HLC(column: r["added_hlc"]) ?? HLC(wall: 0, device: "-"), checkedHLC: HLC(column: r["checked_hlc"]),
                     addedBy: r["added_by"] ?? "", checkedBy: r["checked_by"])
        }
        let open = rows.filter { !$0.isChecked }.sorted { ($0.sort, $0.addedHLC) < ($1.sort, $1.addedHLC) }
        let struck = rows.filter(\.isChecked).sorted { $0.checkedHLC! > $1.checkedHLC! }
        return open + struck
    }

    /// The last thirty cleared items of a list, one row per item, newest first.
    static func recent(_ db: Database, _ s: Scope, listID: String) throws -> [RecentRow] {
        try Row.fetchAll(db, sql: """
            SELECT e.item_id, COALESCE(o.name, i.name, '') AS item_name, MAX(CAST(substr(e.cleared_hlc, 1, 13) AS INTEGER)) AS cleared_at
            FROM entries e
            LEFT JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = e.item_id
            LEFT JOIN items o ON o.server_id = i.server_id AND o.household_id = i.household_id AND o.id = i.merged_into
            WHERE e.server_id = ? AND e.household_id = ? AND e.list_id = ? AND e.cleared_hlc IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM entries x WHERE x.server_id = e.server_id AND x.household_id = e.household_id AND x.list_id = e.list_id AND x.item_id = e.item_id AND x.cleared_hlc IS NULL)
            GROUP BY e.item_id
            ORDER BY cleared_at DESC
            LIMIT ?
            """, arguments: [s.serverID, s.householdID, listID, recentLimit]).map { r in
            RecentRow(itemID: r["item_id"], name: r["item_name"], clearedAt: r["cleared_at"])
        }
    }

    /// The catalog filtered by prefix on any word of the name or an alias, by use then recency,
    /// at most eight, each with when it was last bought.
    static func matches(_ db: Database, _ s: Scope, prefix: String) throws -> [Match] {
        let p = Norm.name(prefix)
        guard !p.isEmpty else { return [] }
        let like = p.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try Row.fetchAll(db, sql: """
            SELECT i.id, i.name, i.use_count,
              (SELECT MAX(CAST(substr(e.cleared_hlc, 1, 13) AS INTEGER)) FROM entries e WHERE e.server_id = i.server_id AND e.household_id = i.household_id AND e.item_id = i.id AND e.cleared_hlc IS NOT NULL) AS last_bought
            FROM items i
            WHERE i.server_id = ? AND i.household_id = ? AND i.merged_into IS NULL AND i.archived_at IS NULL AND (
              i.norm_name LIKE ? ESCAPE '\\' OR i.norm_name LIKE ? ESCAPE '\\'
              OR EXISTS (SELECT 1 FROM item_aliases a WHERE a.server_id = i.server_id AND a.household_id = i.household_id AND a.item_id = i.id AND (a.norm_name LIKE ? ESCAPE '\\' OR a.norm_name LIKE ? ESCAPE '\\'))
            )
            ORDER BY i.use_count DESC, i.last_used_at DESC, i.norm_name
            LIMIT ?
            """, arguments: [s.serverID, s.householdID, like + "%", "% " + like + "%", like + "%", "% " + like + "%", matchLimit]).map { r in
            Match(itemID: r["id"], name: r["name"], useCount: r["use_count"], lastBought: r["last_bought"])
        }
    }

    /// The household's most used items that are not on the list now: the chips over an empty
    /// add field.
    static func usual(_ db: Database, _ s: Scope, listID: String, limit: Int = 8) throws -> [Match] {
        try Row.fetchAll(db, sql: """
            SELECT i.id, i.name, i.use_count FROM items i
            WHERE i.server_id = ? AND i.household_id = ? AND i.merged_into IS NULL AND i.archived_at IS NULL AND i.use_count > 0
              AND NOT EXISTS (SELECT 1 FROM entries e WHERE e.server_id = i.server_id AND e.household_id = i.household_id AND e.list_id = ? AND e.item_id = i.id AND e.cleared_hlc IS NULL)
            ORDER BY i.use_count DESC, i.last_used_at DESC, i.norm_name
            LIMIT ?
            """, arguments: [s.serverID, s.householdID, listID, limit]).map { r in
            Match(itemID: r["id"], name: r["name"], useCount: r["use_count"], lastBought: nil)
        }
    }

    /// The item that owns a typed name exactly, by name or alias, or nil.
    static func itemID(_ db: Database, _ s: Scope, norm: String) throws -> String? {
        guard !norm.isEmpty else { return nil }
        if let id = try String.fetchOne(db, sql: "SELECT id FROM items WHERE server_id = ? AND household_id = ? AND merged_into IS NULL AND norm_name = ?", arguments: [s.serverID, s.householdID, norm]) {
            return id
        }
        return try String.fetchOne(db, sql: """
            SELECT COALESCE(i.merged_into, i.id) FROM item_aliases a JOIN items i ON i.server_id = a.server_id AND i.household_id = a.household_id AND i.id = a.item_id
            WHERE a.server_id = ? AND a.household_id = ? AND a.norm_name = ?
            """, arguments: [s.serverID, s.householdID, norm])
    }

    /// The open, not cleared entry of an item on a list, if any.
    static func openEntry(_ db: Database, _ s: Scope, listID: String, itemID: String) throws -> Entry? {
        let ids = try SQLFoldStore(db: db, scope: s).mergedIDs(itemID)
        return try SQLFoldStore(db: db, scope: s).entries(listID: listID, itemIDs: ids).first { $0.clearedHLC == nil }
    }

    static func homes(_ db: Database, _ s: Scope) throws -> [HomeRow] {
        try Row.fetchAll(db, sql: "SELECT id, name FROM homes WHERE server_id = ? AND household_id = ? AND archived_at IS NULL ORDER BY sort, name COLLATE NOCASE, id", arguments: [s.serverID, s.householdID]).map { r in
            HomeRow(id: r["id"], name: r["name"])
        }
    }

    /// Open entries across the shared lists and the person's own: the app icon's badge.
    static func openCount(_ db: Database, _ s: Scope) throws -> Int {
        try lists(db, s).reduce(0) { $0 + $1.openCount }
    }

    /// Items on a list other than one, for Merge with: the ones a person sees side by side.
    static func otherItems(_ db: Database, _ s: Scope, listID: String, except itemID: String) throws -> [Match] {
        try Row.fetchAll(db, sql: """
            SELECT DISTINCT i.id, i.name, i.use_count FROM entries e
            JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = e.item_id
            WHERE e.server_id = ? AND e.household_id = ? AND e.list_id = ? AND e.cleared_hlc IS NULL AND i.id != ? AND i.merged_into IS NULL
            ORDER BY i.name COLLATE NOCASE
            """, arguments: [s.serverID, s.householdID, listID, itemID]).map { r in
            Match(itemID: r["id"], name: r["name"], useCount: r["use_count"], lastBought: nil)
        }
    }
}
