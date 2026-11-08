// What the History screen reads: the household's purchases, which are the cleared entries,
// by month, and within a month per item with the totals of qty by unit, per home and per
// person. Everything comes from the entries table; no event is made for it.
import Foundation
import GRDB

/// A month with purchases in it, "YYYY-MM" in the device's calendar, and how many.
struct PurchaseMonth: Identifiable, Hashable, Sendable {
    var id: String { month }
    var month: String
    var count: Int
}

/// One unit's total for an item: "x" is the plain count, an entry without a quantity counts one.
struct PurchaseTotal: Hashable, Sendable {
    var unit: String
    var qty: Double

    var text: String { EntryRow.quantity(qty, unit) }
}

/// An item bought in the month: how many times, what it added up to per unit, and when last.
struct PurchasedItem: Identifiable, Hashable, Sendable {
    var id: String { itemID }
    var itemID: String
    var name: String
    var times: Int
    var totals: [PurchaseTotal]
    var lastAt: Int64
}

/// A home or a person with how many purchases were theirs in the month.
struct PurchaseCount: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var times: Int
}

struct MonthOverview: Hashable, Sendable {
    var total = 0
    var items: [PurchasedItem] = []
    var homes: [PurchaseCount] = []
    /// By the person who struck the entry, as an id; the screen names them.
    var people: [PurchaseCount] = []
}

extension Queries {
    /// The month a stamp falls in, in the device's calendar, as SQL on the entry's cleared stamp.
    /// A done task is not a purchase.
    private static let notTasks = "e.list_id NOT IN (SELECT x.id FROM lists x WHERE x.server_id = e.server_id AND x.household_id = e.household_id AND x.kind = 'tasks')"
    private static let clearedMonth = "strftime('%Y-%m', CAST(substr(e.cleared_hlc, 1, 13) AS INTEGER) / 1000, 'unixepoch', 'localtime')"
    /// A retired item, or the item a merged one reads through to, is out of sight here; its
    /// rows stay for the export and come back with it. Needs the i and o joins.
    static let notRetired = "(CASE WHEN o.id IS NULL THEN i.archived_at ELSE o.archived_at END) IS NULL"

    /// Every month with a purchase, newest first.
    static func purchaseMonths(_ db: Database, _ s: Scope) throws -> [PurchaseMonth] {
        try Row.fetchAll(db, sql: """
            SELECT \(clearedMonth) AS month, COUNT(*) AS n
            FROM entries e
            LEFT JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = e.item_id
            LEFT JOIN items o ON o.server_id = i.server_id AND o.household_id = i.household_id AND o.id = i.merged_into
            WHERE e.server_id = ? AND e.household_id = ? AND e.cleared_hlc IS NOT NULL AND \(notTasks) AND \(notRetired)
            GROUP BY month
            ORDER BY month DESC
            """, arguments: [s.serverID, s.householdID]).map { r in
            PurchaseMonth(month: r["month"], count: r["n"])
        }
    }

    /// One month's purchases: per item, most bought first, with the totals of qty by unit (a
    /// merged item reads through to the one it was merged into); per home; per person.
    static func purchases(_ db: Database, _ s: Scope, month: String) throws -> MonthOverview {
        var out = MonthOverview()
        var items: [String: PurchasedItem] = [:]
        var order: [String] = []
        for r in try Row.fetchAll(db, sql: """
            SELECT COALESCE(o.id, i.id, e.item_id) AS item_id, COALESCE(o.name, i.name, '') AS name,
              COALESCE(NULLIF(e.unit, ''), 'x') AS unit, COUNT(*) AS times, SUM(COALESCE(e.qty, 1)) AS qty,
              MAX(CAST(substr(e.cleared_hlc, 1, 13) AS INTEGER)) AS last_at
            FROM entries e
            LEFT JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = e.item_id
            LEFT JOIN items o ON o.server_id = i.server_id AND o.household_id = i.household_id AND o.id = i.merged_into
            WHERE e.server_id = ? AND e.household_id = ? AND e.cleared_hlc IS NOT NULL AND \(notTasks) AND \(notRetired) AND \(clearedMonth) = ?
            GROUP BY item_id, unit
            ORDER BY name COLLATE NOCASE, unit
            """, arguments: [s.serverID, s.householdID, month]) {
            let id: String = r["item_id"]
            let times: Int = r["times"]
            let total = PurchaseTotal(unit: r["unit"], qty: r["qty"])
            let lastAt: Int64 = r["last_at"]
            if var it = items[id] {
                // a merged item's rows come per original id: the same unit adds up
                it.times += times
                if let j = it.totals.firstIndex(where: { $0.unit == total.unit }) {
                    it.totals[j].qty += total.qty
                } else {
                    it.totals.append(total)
                }
                it.lastAt = max(it.lastAt, lastAt)
                items[id] = it
            } else {
                items[id] = PurchasedItem(itemID: id, name: r["name"], times: times, totals: [total], lastAt: lastAt)
                order.append(id)
            }
            out.total += times
        }
        out.items = order.compactMap { items[$0] }.sorted { ($1.times, $0.name.lowercased()) < ($0.times, $1.name.lowercased()) }
        out.homes = try Row.fetchAll(db, sql: """
            SELECT h.id, h.name, COUNT(*) AS times
            FROM entries e
            LEFT JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = e.item_id
            LEFT JOIN items o ON o.server_id = i.server_id AND o.household_id = i.household_id AND o.id = i.merged_into
            JOIN homes h ON h.server_id = e.server_id AND h.household_id = e.household_id AND h.id = e.for_home_id
            WHERE e.server_id = ? AND e.household_id = ? AND e.cleared_hlc IS NOT NULL AND \(notTasks) AND \(notRetired) AND \(clearedMonth) = ?
            GROUP BY h.id
            ORDER BY times DESC, h.name COLLATE NOCASE
            """, arguments: [s.serverID, s.householdID, month]).map { r in
            PurchaseCount(id: r["id"], name: r["name"], times: r["times"])
        }
        out.people = try Row.fetchAll(db, sql: """
            SELECT e.checked_by AS person, COUNT(*) AS times
            FROM entries e
            LEFT JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = e.item_id
            LEFT JOIN items o ON o.server_id = i.server_id AND o.household_id = i.household_id AND o.id = i.merged_into
            WHERE e.server_id = ? AND e.household_id = ? AND e.cleared_hlc IS NOT NULL AND \(notTasks) AND \(notRetired) AND e.checked_by IS NOT NULL AND \(clearedMonth) = ?
            GROUP BY e.checked_by
            ORDER BY times DESC, person
            """, arguments: [s.serverID, s.householdID, month]).map { r in
            PurchaseCount(id: r["person"], name: "", times: r["times"])
        }
        return out
    }
}
