// What the Homes, Home and Trip screens read: the homes with what they miss, a home's spots
// with their current photo, its staples and other flagged items with their flag as it stands
// now (a flag older than the household's staleness is unknown), a spot's photos, and the trips
// through a home. Every query is scoped to one household on one server.
import Foundation
import GRDB
import SwiftUI

/// The four states a flag can show: the three stored and unknown, which is no flag or a stale
/// one. Each has its glyph and its word; never colour alone.
enum FlagState: String, Hashable, Sendable, CaseIterable {
    case have, low, out, unknown

    var symbol: Symbol {
        switch self {
        case .have: .have
        case .low: .low
        case .out: .out
        case .unknown: .unknown
        }
    }

    var word: LocalizedStringKey {
        switch self {
        case .have: "have"
        case .low: "low"
        case .out: "out"
        case .unknown: "unknown"
        }
    }

    var color: Color {
        switch self {
        case .have: Tokens.have
        case .low: Tokens.low
        case .out: Tokens.out
        case .unknown: Tokens.unknown
        }
    }

    /// The three a person sets.
    static let settable: [FlagState] = [.have, .low, .out]
}

/// How old a flag may be before it reads as unknown, and when its age starts to show.
struct Staleness: Hashable, Sendable {
    var days: Int64
    var now: Int64

    static let defaultDays: Int64 = 60

    init(days: Int64?, now: Date = Date()) {
        self.days = days ?? Self.defaultDays
        self.now = millis(now)
    }

    var limit: Int64 { days * 86_400_000 }

    /// The state a flag set at wall shows now.
    func state(_ stored: String?, setAt: Int64?) -> FlagState {
        guard let stored, let setAt, now - setAt < limit, let s = FlagState(rawValue: stored) else { return .unknown }
        return s
    }

    /// Whether the age is shown: past half the threshold.
    func showsAge(_ setAt: Int64?) -> Bool {
        guard let setAt else { return false }
        return now - setAt > limit / 2
    }
}

struct SpotRow: Identifiable, Hashable, Sendable {
    var id: String
    var homeID: String
    var name: String
    var sort: Int64
    /// The newest photo of the spot, if any.
    var photoID: String?
    var photoTakenAt: Int64?
    var photoTakenBy: String?
}

/// A staple or another flagged item at a home, with its flag as it stands now.
struct FlagRow: Identifiable, Hashable, Sendable {
    var id: String { itemID }
    var itemID: String
    var name: String
    var state: FlagState
    var setAt: Int64?
    var setBy: String?
    var note: String
    var isStaple: Bool
    var ageShown: Bool
    /// The staple's place among the home's staples; 0 for the rest.
    var sort: Int64 = 0
    /// The section the staple is shown under, "" for none and for the rest.
    var section = ""
}

/// A home's staples as the screen lists them: a header before each section's staples.
enum StapleEntry: Identifiable, Hashable, Sendable {
    case header(String)
    case row(FlagRow)

    var id: String {
        switch self {
        case .header(let name): "section:" + name
        case .row(let row): row.itemID
        }
    }
}

/// The order of a home's staples and the sorts that keep it: the staples outside every section
/// first, then the sections in the order of their first staple, each staple by its sort. Pure,
/// so the screen, the actions and the tests agree.
enum StapleOrder {
    /// A section's name is at most this long, as the event schema says.
    static let maxName = 40

    static func display(_ staples: [FlagRow]) -> [FlagRow] {
        var first: [String: Int64] = [:]
        for r in staples { first[r.section] = min(first[r.section] ?? r.sort, r.sort) }
        return staples.sorted { a, b in
            if a.section != b.section {
                if a.section.isEmpty || b.section.isEmpty { return a.section.isEmpty }
                let fa = first[a.section] ?? 0, fb = first[b.section] ?? 0
                return fa != fb ? fa < fb : a.section < b.section
            }
            if a.sort != b.sort { return a.sort < b.sort }
            let x = a.name.lowercased(), y = b.name.lowercased()
            return x != y ? x < y : a.itemID < b.itemID
        }
    }

    /// The sections in the order they are shown.
    static func sections(_ staples: [FlagRow]) -> [String] {
        var seen: [String] = []
        for r in display(staples) where !r.section.isEmpty && seen.last != r.section { seen.append(r.section) }
        return seen
    }

    static func entries(_ staples: [FlagRow], collapsed: Set<String> = []) -> [StapleEntry] {
        var out: [StapleEntry] = []
        var section = ""
        for r in display(staples) {
            if r.section != section {
                section = r.section
                out.append(.header(section))
            }
            if !collapsed.contains(r.section) { out.append(.row(r)) }
        }
        return out
    }

    /// The staples after a drag of the screen's rows: a staple belongs to the header above it,
    /// and to no section above the first one. Headers stay where they are.
    /// The staples of a collapsed section are not among the rows: they keep their place under
    /// their header, and a staple dropped under it comes after them.
    static func moved(_ entries: [StapleEntry], from source: IndexSet, to destination: Int, hidden: [FlagRow] = []) -> (wanted: [FlagRow], changed: Set<String>) {
        var changed = Set<String>()
        for i in source {
            if case .row(let r) = entries[i] { changed.insert(r.itemID) }
        }
        var after = entries
        after.move(fromOffsets: source, toOffset: destination)
        var wanted: [FlagRow] = []
        var section = ""
        for e in after {
            switch e {
            case .header(let name):
                section = name
                wanted += display(hidden.filter { $0.section == name })
            case .row(var r):
                r.section = section
                wanted.append(r)
            }
        }
        return (wanted, changed)
    }

    /// The staples with rows put at the end of a section: after its last staple, before the
    /// first header for no section, and after everything for a section that is new.
    static func placed(_ rows: [FlagRow], in section: String, among staples: [FlagRow]) -> [FlagRow] {
        let ids = Set(rows.map(\.itemID))
        var out = display(staples.filter { !ids.contains($0.itemID) })
        let at: Int
        if let last = out.lastIndex(where: { $0.section == section }) {
            at = last + 1
        } else if section.isEmpty {
            at = 0
        } else {
            at = out.count
        }
        out.insert(contentsOf: rows.map { var r = $0; r.section = section; return r }, at: at)
        return out
    }

    /// The sorts to write so the staples read in this order: the changed ones only, each run
    /// spread between its neighbours, or every staple renumbered when the others are out of
    /// order or leave no room.
    static func sorts(_ wanted: [FlagRow], changed: Set<String>) -> [String: Int64] {
        let gap = HomeActions.sortGap
        var out: [String: Int64] = [:]
        let fixed = wanted.filter { !changed.contains($0.itemID) }
        var fits = zip(fixed, fixed.dropFirst()).allSatisfy { $0.sort < $1.sort }
        var i = 0
        while fits, i < wanted.count {
            guard changed.contains(wanted[i].itemID) else { i += 1; continue }
            var j = i
            while j < wanted.count, changed.contains(wanted[j].itemID) { j += 1 }
            let run = wanted[i..<j]
            let n = Int64(run.count)
            let prev = i > 0 ? wanted[i - 1].sort : nil
            let next = j < wanted.count ? wanted[j].sort : nil
            let inOrder = zip(run, run.dropFirst()).allSatisfy { $0.sort < $1.sort }
            if inOrder, prev.map({ $0 < run.first!.sort }) ?? true, next.map({ run.last!.sort < $0 }) ?? true {
                // in place already: only the section changed
                for r in run { out[r.itemID] = r.sort }
            } else {
                for (k, r) in run.enumerated() {
                    let k = Int64(k)
                    switch (prev, next) {
                    case (nil, nil): out[r.itemID] = (k + 1) * gap
                    case (let p?, nil): out[r.itemID] = p + (k + 1) * gap
                    case (nil, let q?): out[r.itemID] = q - (n - k) * gap
                    case (let p?, let q?):
                        if q - p > n {
                            out[r.itemID] = p + (k + 1) * ((q - p) / (n + 1))
                        } else {
                            fits = false
                        }
                    }
                }
            }
            i = j
        }
        if !fits {
            out = [:]
            for (k, r) in wanted.enumerated() {
                let s = Int64(k + 1) * gap
                if s != r.sort || changed.contains(r.itemID) { out[r.itemID] = s }
            }
        }
        return out
    }

    /// A typed section name as it is kept: trimmed, cut to the length the schema takes, and in
    /// the spelling of a section that is there already.
    static func name(_ typed: String, among sections: [String]) -> String {
        let t = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
        return sections.first { $0.caseInsensitiveCompare(t) == .orderedSame } ?? t
    }
}

/// What a picture suggested about an item at a home, still waiting for an answer.
struct ProposalRow: Identifiable, Hashable, Sendable {
    var id: String
    var itemID: String
    var name: String
    var state: FlagState
    /// The flag as it stands, after staleness.
    var current: FlagState
    var photoID: String
    var proposedAt: Int64
}

struct HomeCard: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Staples out, low or unknown.
    var missing: Int
    var staples: Int
    var spots: [SpotRow]
}

struct PhotoRow: Identifiable, Hashable, Sendable {
    var id: String
    var spotID: String
    var takenAt: Int64
    var takenBy: String
}

struct TripRow: Identifiable, Hashable, Sendable {
    var id: String
    var fromHomeID: String
    var toHomeID: String
    var fromName: String
    var toName: String
    var date: Int64
    var createdBy: String
    var listID: String?
    var listName: String?
    var arrivedAt: Int64?
    var cancelledAt: Int64?
    var moved: [String]

    /// Planned and neither arrived nor cancelled.
    var isOpen: Bool { arrivedAt == nil && cancelledAt == nil }
}

extension Queries {
    /// Every home that is not archived, with what it misses and its spots.
    static func homeCards(_ db: Database, _ s: Scope, staleness: Staleness) throws -> [HomeCard] {
        try homes(db, s).map { h in
            let rows = try flagRows(db, s, homeID: h.id, staleness: staleness)
            let staples = rows.filter(\.isStaple)
            return HomeCard(id: h.id, name: h.name, missing: staples.filter { $0.state != .have }.count, staples: staples.count, spots: try spots(db, s, homeID: h.id))
        }
    }

    /// A home's spots in order, each with its newest photo.
    static func spots(_ db: Database, _ s: Scope, homeID: String) throws -> [SpotRow] {
        try Row.fetchAll(db, sql: """
            SELECT sp.id, sp.home_id, sp.name, sp.sort,
              (SELECT p.id FROM photos p WHERE p.server_id = sp.server_id AND p.household_id = sp.household_id AND p.spot_id = sp.id ORDER BY p.taken_hlc DESC, p.id DESC LIMIT 1) AS photo_id,
              (SELECT CAST(substr(p.taken_hlc, 1, 13) AS INTEGER) FROM photos p WHERE p.server_id = sp.server_id AND p.household_id = sp.household_id AND p.spot_id = sp.id ORDER BY p.taken_hlc DESC, p.id DESC LIMIT 1) AS taken_at,
              (SELECT p.taken_by FROM photos p WHERE p.server_id = sp.server_id AND p.household_id = sp.household_id AND p.spot_id = sp.id ORDER BY p.taken_hlc DESC, p.id DESC LIMIT 1) AS taken_by
            FROM spots sp
            WHERE sp.server_id = ? AND sp.household_id = ? AND sp.home_id = ? AND sp.archived_at IS NULL
            ORDER BY sp.sort, sp.name COLLATE NOCASE, sp.id
            """, arguments: [s.serverID, s.householdID, homeID]).map { r in
            SpotRow(id: r["id"], homeID: r["home_id"], name: r["name"], sort: r["sort"], photoID: r["photo_id"], photoTakenAt: r["taken_at"], photoTakenBy: r["taken_by"])
        }
    }

    /// The home's staples first, then every other item with a flag there; staples in their
    /// sections' order (StapleOrder), the rest by name. Each with the flag as it stands now.
    static func flagRows(_ db: Database, _ s: Scope, homeID: String, staleness: Staleness) throws -> [FlagRow] {
        let all = try Row.fetchAll(db, sql: """
            SELECT i.id, i.name, f.state, CAST(substr(f.set_hlc, 1, 13) AS INTEGER) AS set_at, f.set_by, f.note,
              CASE WHEN st.item_id IS NOT NULL THEN 1 ELSE 0 END AS is_staple, COALESCE(st.sort, 0) AS sort, COALESCE(st.section, '') AS section
            FROM items i
            LEFT JOIN staples st ON st.server_id = i.server_id AND st.household_id = i.household_id AND st.item_id = i.id AND st.home_id = ?
              AND st.added_hlc IS NOT NULL AND (st.removed_hlc IS NULL OR st.removed_hlc < st.added_hlc)
            LEFT JOIN flags f ON f.server_id = i.server_id AND f.household_id = i.household_id AND f.item_id = i.id AND f.home_id = ?
            WHERE i.server_id = ? AND i.household_id = ? AND i.merged_into IS NULL AND i.archived_at IS NULL
              AND (st.item_id IS NOT NULL OR f.item_id IS NOT NULL)
            ORDER BY is_staple DESC, sort, i.name COLLATE NOCASE, i.id
            """, arguments: [homeID, homeID, s.serverID, s.householdID]).map { r in
            let setAt: Int64? = r["set_at"]
            let isStaple: Int64 = r["is_staple"]
            return FlagRow(itemID: r["id"], name: r["name"], state: staleness.state(r["state"], setAt: setAt), setAt: setAt, setBy: r["set_by"], note: r["note"] ?? "", isStaple: isStaple == 1, ageShown: staleness.showsAge(setAt), sort: r["sort"], section: r["section"])
        }
        return StapleOrder.display(all.filter(\.isStaple)) + all.filter { !$0.isStaple }
    }

    /// The home's open proposals, newest first, with the flag as it stands next to each.
    static func proposals(_ db: Database, _ s: Scope, homeID: String, staleness: Staleness) throws -> [ProposalRow] {
        try Row.fetchAll(db, sql: """
            SELECT p.id, p.item_id, COALESCE(o.name, i.name, '') AS name, p.state, p.photo_id,
              CAST(substr(p.proposed_hlc, 1, 13) AS INTEGER) AS proposed_at,
              f.state AS cur, CAST(substr(f.set_hlc, 1, 13) AS INTEGER) AS set_at
            FROM proposals p
            LEFT JOIN items i ON i.server_id = p.server_id AND i.household_id = p.household_id AND i.id = p.item_id
            LEFT JOIN items o ON o.server_id = i.server_id AND o.household_id = i.household_id AND o.id = i.merged_into
            LEFT JOIN flags f ON f.server_id = p.server_id AND f.household_id = p.household_id AND f.home_id = p.home_id AND f.item_id = p.item_id
            WHERE p.server_id = ? AND p.household_id = ? AND p.home_id = ? AND p.closed_hlc IS NULL
            ORDER BY proposed_at DESC, p.id
            """, arguments: [s.serverID, s.householdID, homeID]).map { r in
            let setAt: Int64? = r["set_at"]
            return ProposalRow(id: r["id"], itemID: r["item_id"], name: r["name"], state: FlagState(rawValue: r["state"]) ?? .unknown,
                               current: staleness.state(r["cur"], setAt: setAt), photoID: r["photo_id"], proposedAt: r["proposed_at"])
        }
    }

    /// The sort a new staple takes: after the home's last one, so staples read in the order
    /// they were added until someone drags them.
    static func nextStapleSort(_ db: Database, _ s: Scope, homeID: String) throws -> Int64 {
        let last = try Int64.fetchOne(db, sql: """
            SELECT MAX(sort) FROM staples
            WHERE server_id = ? AND household_id = ? AND home_id = ? AND added_hlc IS NOT NULL AND (removed_hlc IS NULL OR removed_hlc < added_hlc)
            """, arguments: [s.serverID, s.householdID, homeID]) ?? 0
        return last + HomeActions.sortGap
    }

    /// A spot's photos, newest first.
    static func photos(_ db: Database, _ s: Scope, spotID: String) throws -> [PhotoRow] {
        try Row.fetchAll(db, sql: "SELECT id, spot_id, CAST(substr(taken_hlc, 1, 13) AS INTEGER) AS taken_at, taken_by FROM photos WHERE server_id = ? AND household_id = ? AND spot_id = ? ORDER BY taken_hlc DESC, id DESC", arguments: [s.serverID, s.householdID, spotID]).map { r in
            PhotoRow(id: r["id"], spotID: r["spot_id"], takenAt: r["taken_at"], takenBy: r["taken_by"])
        }
    }

    /// The household's trips, or those from or to a home: the open ones by date, nearest first,
    /// then the arrived and cancelled ones, newest first, with the names of what moved.
    static func trips(_ db: Database, _ s: Scope, homeID: String? = nil) throws -> [TripRow] {
        try Row.fetchAll(db, sql: """
            SELECT t.id, t.from_home_id, t.to_home_id, t.date, t.created_by, t.list_id, t.arrived_at, t.cancelled_at,
              COALESCE((SELECT name FROM homes h WHERE h.server_id = t.server_id AND h.household_id = t.household_id AND h.id = t.from_home_id), '') AS from_name,
              COALESCE((SELECT name FROM homes h WHERE h.server_id = t.server_id AND h.household_id = t.household_id AND h.id = t.to_home_id), '') AS to_name,
              (SELECT name FROM lists l WHERE l.server_id = t.server_id AND l.household_id = t.household_id AND l.id = t.list_id) AS list_name,
              (SELECT group_concat(i.name, char(31)) FROM events e
                 JOIN event_items ei ON ei.server_id = e.server_id AND ei.household_id = e.household_id AND ei.event_id = e.id
                 JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = ei.item_id
               WHERE e.server_id = t.server_id AND e.household_id = t.household_id AND e.kind = 'trip.arrived' AND json_extract(e.payload, '$.trip_id') = t.id) AS moved
            FROM trips t
            WHERE t.server_id = ? AND t.household_id = ? AND t.from_home_id != '' AND (? IS NULL OR t.from_home_id = ? OR t.to_home_id = ?)
            ORDER BY (t.arrived_at IS NULL AND t.cancelled_at IS NULL) DESC,
              CASE WHEN t.arrived_at IS NULL AND t.cancelled_at IS NULL THEN t.date END ASC,
              CASE WHEN t.arrived_at IS NULL AND t.cancelled_at IS NULL THEN NULL ELSE COALESCE(t.arrived_at, t.cancelled_at) END DESC,
              t.id
            """, arguments: [s.serverID, s.householdID, homeID, homeID, homeID]).map { r in
            let moved: String? = r["moved"]
            return TripRow(id: r["id"], fromHomeID: r["from_home_id"], toHomeID: r["to_home_id"], fromName: r["from_name"], toName: r["to_name"], date: r["date"], createdBy: r["created_by"], listID: r["list_id"], listName: r["list_name"], arrivedAt: r["arrived_at"], cancelledAt: r["cancelled_at"], moved: moved.map { $0.split(separator: "\u{1f}").map(String.init).sorted() } ?? [])
        }
    }
}
