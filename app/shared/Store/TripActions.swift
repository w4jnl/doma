// Trips: planned and shared, derived on the device. A plan is from, to, a date and the list it
// shops on; Bring is out or low at the to-home and have at the from-home; Buy is out or low at
// the to-home and not have at the from-home, plus every open entry on a shared list for the
// to-home; Check on arrival is the to-home's unknown staples. A to-home's needs show on the
// nearest upcoming trip to that home and nowhere else. Arrived commits one trip.arrived with
// what was packed; the fold moves the flags.
import Foundation
import GRDB

struct TripItem: Identifiable, Hashable, Sendable {
    var id: String { itemID }
    var itemID: String
    var name: String
    /// The flag at the to-home, which says why it is on the trip.
    var toState: FlagState
    var fromState: FlagState
    /// Already open on a shared list for the to-home.
    var onList: Bool
}

struct TripPlan: Hashable, Sendable {
    var bring: [TripItem] = []
    var buy: [TripItem] = []
    var check: [TripItem] = []

    var isEmpty: Bool { bring.isEmpty && buy.isEmpty && check.isEmpty }

    /// The plan from the tables, pure: the flags of both homes as they stand now, the to-home's
    /// staples, and the open entries for the to-home on shared lists.
    static func derive(from fromHome: String, to toHome: String, flags: [FlagRow], toFlags: [FlagRow], listed: [String: String]) -> TripPlan {
        var plan = TripPlan()
        let fromByItem = Dictionary(uniqueKeysWithValues: flags.map { ($0.itemID, $0) })
        var seen = Set<String>()
        for row in toFlags {
            seen.insert(row.itemID)
            let fromState = fromByItem[row.itemID]?.state ?? .unknown
            let item = TripItem(itemID: row.itemID, name: row.name, toState: row.state, fromState: fromState, onList: listed[row.itemID] != nil)
            switch row.state {
            case .out, .low:
                if fromState == .have { plan.bring.append(item) } else { plan.buy.append(item) }
            case .unknown:
                if row.isStaple { plan.check.append(item) }
            case .have:
                break
            }
        }
        for (itemID, name) in listed where !seen.contains(itemID) {
            plan.buy.append(TripItem(itemID: itemID, name: name, toState: .unknown, fromState: fromByItem[itemID]?.state ?? .unknown, onList: true))
        }
        plan.buy.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return plan
    }

    /// Whether a trip's to-home needs show on it: only on the nearest upcoming trip to that
    /// home among the ones still open.
    static func carries(_ trip: TripRow, among trips: [TripRow]) -> Bool {
        guard trip.isOpen else { return false }
        let same = trips.filter { $0.isOpen && $0.toHomeID == trip.toHomeID }
        return same.min { ($0.date, $0.id) < ($1.date, $1.id) }?.id == trip.id
    }
}

@MainActor
enum TripActions {
    /// The plan for a trip as the store stands; empty when another, nearer trip to the same
    /// home carries its needs.
    static func plan(for trip: TripRow, among trips: [TripRow], in session: Session, staleness: Staleness) throws -> TripPlan {
        guard let scope = session.scope, trip.fromHomeID != trip.toHomeID, TripPlan.carries(trip, among: trips) else { return TripPlan() }
        return try session.store.read(scope) { db, s in try plan(db, s, from: trip.fromHomeID, to: trip.toHomeID, staleness: staleness) }
    }

    /// nonisolated: the screens' live queries read it off the main actor.
    nonisolated static func plan(_ db: Database, _ s: Scope, from fromHome: String, to toHome: String, staleness: Staleness) throws -> TripPlan {
        let fromFlags = try Queries.flagRows(db, s, homeID: fromHome, staleness: staleness)
        let toFlags = try Queries.flagRows(db, s, homeID: toHome, staleness: staleness)
        let listed = try Queries.openForHome(db, s, homeID: toHome)
        return TripPlan.derive(from: fromHome, to: toHome, flags: fromFlags, toFlags: toFlags, listed: listed)
    }

    /// Plans a trip: from, to, a date (the day, in milliseconds) and the list it shops on; the
    /// same call with the trip's id changes it.
    @discardableResult
    static func plan(id: String = ULID.make(), from fromHome: String, to toHome: String, date: Date, list listID: String?, in session: Session) throws -> String? {
        guard fromHome != toHome, !fromHome.isEmpty, !toHome.isEmpty else { return nil }
        var p = TripPlanPayload(tripID: id, fromHomeID: fromHome, toHomeID: toHome)
        p.date = millis(Calendar.current.startOfDay(for: date))
        p.listID = listID
        try session.record(Kind.tripPlanned, p)
        return id
    }

    static func cancel(_ tripID: String, in session: Session) throws {
        try session.record(Kind.tripCancelled, TripPlanPayload(tripID: tripID))
    }

    /// Adds an item to a list for the to-home; one already open on any shared list for that
    /// home is left alone. Without a list, the household's default.
    static func addToList(_ itemID: String, forHome homeID: String, list listID: String? = nil, in session: Session) throws {
        guard let scope = session.scope else { return }
        let lists = try session.store.read(scope) { db, s in try Queries.lists(db, s) }
        guard let list = listID.flatMap({ id in lists.first { $0.id == id }?.id }) ?? lists.first(where: \.isDefault)?.id else { return }
        if try session.store.read(scope, { db, s in try Queries.openForHome(db, s, homeID: homeID) })[itemID] != nil { return }
        if let open = try session.store.read(scope, { db, s in try Queries.openEntry(db, s, listID: list, itemID: itemID) }), open.checkedHLC == nil { return }
        var p = EntryPayload(listID: list, itemID: itemID)
        p.forHomeID = homeID
        try session.record(Kind.entryAdded, p)
    }

    /// Arrived: one trip.arrived with the packed items; the fold flags them out at the from-home
    /// and have at the to-home.
    @discardableResult
    static func arrive(_ trip: TripRow, packed: [String], in session: Session) throws -> String? {
        guard !packed.isEmpty, trip.fromHomeID != trip.toHomeID else { return nil }
        try session.record(Kind.tripArrived, TripPayload(tripID: trip.id, fromHomeID: trip.fromHomeID, toHomeID: trip.toHomeID, moved: packed))
        return trip.id
    }
}

extension Queries {
    /// Items open on a shared list for a home: item id to name.
    static func openForHome(_ db: Database, _ s: Scope, homeID: String) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT i.id, i.name FROM entries e
            JOIN lists l ON l.server_id = e.server_id AND l.household_id = e.household_id AND l.id = e.list_id
            JOIN items i ON i.server_id = e.server_id AND i.household_id = e.household_id AND i.id = e.item_id
            WHERE e.server_id = ? AND e.household_id = ? AND e.for_home_id = ? AND e.cleared_hlc IS NULL
              AND l.owner_person_id IS NULL AND l.archived_at IS NULL AND i.merged_into IS NULL
            """, arguments: [s.serverID, s.householdID, homeID])
        return Dictionary(rows.map { ($0["id"] as String, $0["name"] as String) }, uniquingKeysWith: { a, _ in a })
    }
}
