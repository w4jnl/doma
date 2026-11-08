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
    /// Things to do rather than to buy: done instead of got, no homes, no purchases.
    var isTasks: Bool = false
}

/// An open entry, light, for counting what is unseen: the stamp is the column's string, which
/// sorts as the clock does.
struct OpenMark: Hashable, Sendable {
    var listID: String
    var addedHLC: String
    var addedBy: String
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
        return Self.quantity(q, unit)
    }

    /// A quantity with its unit as the rows show it: "2x", "500 g", "1.5 l".
    static func quantity(_ q: Double, _ unit: String?) -> String {
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
            SELECT l.id, l.name, l.owner_person_id, l.is_default, l.colour, l.kind,
              (SELECT COUNT(*) FROM entries e WHERE e.server_id = l.server_id AND e.household_id = l.household_id AND e.list_id = l.id AND e.cleared_hlc IS NULL AND e.checked_hlc IS NULL) AS open_count
            FROM lists l
            WHERE l.server_id = ? AND l.household_id = ? AND l.archived_at IS NULL AND (l.owner_person_id IS NULL OR l.owner_person_id = ?)
            ORDER BY l.owner_person_id IS NOT NULL, l.is_default DESC, l.sort, l.name COLLATE NOCASE, l.id
            """, arguments: [s.serverID, s.householdID, s.personID]).map { r in
            ListSummary(id: r["id"], name: r["name"], isPersonal: (r["owner_person_id"] as String?) != nil, isDefault: (r["is_default"] as Int64) != 0, openCount: r["open_count"], colour: r["colour"], isTasks: (r["kind"] as String? ?? "") == "tasks")
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
            WHERE e.server_id = ? AND e.household_id = ? AND e.list_id = ? AND e.cleared_hlc IS NOT NULL AND \(notRetired)
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
    /// Only the names used on lists of the same kind match: what the family buys does not come
    /// up while typing a chore, nor the other way round. `last_bought` is the latest clear on
    /// such a list, which on a tasks list is when it was last done.
    static func matches(_ db: Database, _ s: Scope, prefix: String, tasks: Bool = false) throws -> [Match] {
        let p = Norm.name(prefix)
        guard !p.isEmpty else { return [] }
        let like = p.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let kind = tasks ? "tasks" : ""
        return try Row.fetchAll(db, sql: """
            SELECT i.id, i.name, i.use_count,
              (SELECT MAX(CAST(substr(e.cleared_hlc, 1, 13) AS INTEGER)) FROM entries e JOIN lists l ON l.server_id = e.server_id AND l.household_id = e.household_id AND l.id = e.list_id
               WHERE e.server_id = i.server_id AND e.household_id = i.household_id AND e.item_id = i.id AND e.cleared_hlc IS NOT NULL AND l.kind = ?) AS last_bought
            FROM items i
            WHERE i.server_id = ? AND i.household_id = ? AND i.merged_into IS NULL AND i.archived_at IS NULL
              AND EXISTS (SELECT 1 FROM entries e JOIN lists l ON l.server_id = e.server_id AND l.household_id = e.household_id AND l.id = e.list_id
                          WHERE e.server_id = i.server_id AND e.household_id = i.household_id AND e.item_id = i.id AND l.kind = ?)
              AND (
              i.norm_name LIKE ? ESCAPE '\\' OR i.norm_name LIKE ? ESCAPE '\\'
              OR EXISTS (SELECT 1 FROM item_aliases a WHERE a.server_id = i.server_id AND a.household_id = i.household_id AND a.item_id = i.id AND (a.norm_name LIKE ? ESCAPE '\\' OR a.norm_name LIKE ? ESCAPE '\\'))
            )
            ORDER BY i.use_count DESC, i.last_used_at DESC, i.norm_name
            LIMIT ?
            """, arguments: [kind, s.serverID, s.householdID, kind, like + "%", "% " + like + "%", like + "%", "% " + like + "%", matchLimit]).map { r in
            Match(itemID: r["id"], name: r["name"], useCount: r["use_count"], lastBought: r["last_bought"])
        }
    }

    /// The household's most used items that are not on the list now: the chips over an empty
    /// add field. Items used on lists of the list's kind only.
    static func usual(_ db: Database, _ s: Scope, listID: String, limit: Int = 8) throws -> [Match] {
        try Row.fetchAll(db, sql: """
            SELECT i.id, i.name, i.use_count FROM items i
            WHERE i.server_id = ? AND i.household_id = ? AND i.merged_into IS NULL AND i.archived_at IS NULL AND i.use_count > 0
              AND NOT EXISTS (SELECT 1 FROM entries e WHERE e.server_id = i.server_id AND e.household_id = i.household_id AND e.list_id = ? AND e.item_id = i.id AND e.cleared_hlc IS NULL)
              AND EXISTS (SELECT 1 FROM entries e JOIN lists l ON l.server_id = e.server_id AND l.household_id = e.household_id AND l.id = e.list_id
                          WHERE e.server_id = i.server_id AND e.household_id = i.household_id AND e.item_id = i.id
                            AND l.kind = (SELECT kind FROM lists x WHERE x.server_id = i.server_id AND x.household_id = i.household_id AND x.id = ?))
            ORDER BY i.use_count DESC, i.last_used_at DESC, i.norm_name
            LIMIT ?
            """, arguments: [s.serverID, s.householdID, listID, listID, limit]).map { r in
            Match(itemID: r["id"], name: r["name"], useCount: r["use_count"], lastBought: nil)
        }
    }

    /// The item that owns a typed name exactly, by name or alias, or nil.
    /// Every name in the catalog, for splitting a spoken line into the items it names.
    static func itemNames(_ db: Database, _ s: Scope) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM items WHERE server_id = ? AND household_id = ? AND merged_into IS NULL AND archived_at IS NULL", arguments: [s.serverID, s.householdID])
    }

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

    /// Every open entry of the household, light: which list, when it was added and by whom.
    /// What is unseen on this device is counted over these against the seen marks.
    static func openMarks(_ db: Database, _ s: Scope) throws -> [OpenMark] {
        try Row.fetchAll(db, sql: """
            SELECT e.list_id, e.added_hlc, e.added_by FROM entries e
            JOIN lists l ON l.server_id = e.server_id AND l.household_id = e.household_id AND l.id = e.list_id
            WHERE e.server_id = ? AND e.household_id = ? AND e.checked_hlc IS NULL AND e.cleared_hlc IS NULL AND l.archived_at IS NULL
              AND (l.owner_person_id IS NULL OR l.owner_person_id = ?)
            """, arguments: [s.serverID, s.householdID, s.personID]).map { r in
            OpenMark(listID: r["list_id"], addedHLC: r["added_hlc"], addedBy: r["added_by"] ?? "")
        }
    }

    /// Whether an item was retired from History: it is named again when typed in full.
    static func isRetired(_ db: Database, _ s: Scope, itemID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT archived_at IS NOT NULL FROM items WHERE server_id = ? AND household_id = ? AND id = ?", arguments: [s.serverID, s.householdID, itemID]) ?? false
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
