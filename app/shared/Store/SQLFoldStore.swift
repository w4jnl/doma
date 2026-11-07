// The fold's store over the local database, inside one write transaction, for one household on
// one server: the port of internal/foldsql. Every statement carries server_id and household_id
// first.
import Foundation
import GRDB

struct SQLFoldStore: FoldStore {
    let db: Database
    let scope: Scope

    private var sh: StatementArguments { [scope.serverID, scope.householdID] }

    private func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    // MARK: items

    func item(_ id: String) throws -> Item? {
        try Row.fetchOne(db, sql: "SELECT * FROM items WHERE server_id = ? AND household_id = ? AND id = ?", arguments: sh + [id]).map(Item.init(row:))
    }

    func items() throws -> [Item] {
        try Row.fetchAll(db, sql: "SELECT * FROM items WHERE server_id = ? AND household_id = ? ORDER BY id", arguments: sh).map(Item.init(row:))
    }

    func putItem(_ item: Item) throws {
        try db.execute(sql: Item.insert, arguments: item.arguments(scope))
    }

    func replaceAliases(_ aliases: [ItemAlias]) throws {
        try db.execute(sql: "DELETE FROM item_aliases WHERE server_id = ? AND household_id = ?", arguments: sh)
        for a in aliases {
            try db.execute(sql: "INSERT OR REPLACE INTO item_aliases (server_id, household_id, item_id, norm_name) VALUES (?,?,?,?)", arguments: sh + [a.itemID, a.normName])
        }
    }

    func aliases() throws -> [ItemAlias] {
        try Row.fetchAll(db, sql: "SELECT * FROM item_aliases WHERE server_id = ? AND household_id = ? ORDER BY norm_name", arguments: sh).map(ItemAlias.init(row:))
    }

    func mergedIDs(_ id: String) throws -> [String] {
        var out = [id]
        var i = 0
        while i < out.count {
            let more = try String.fetchAll(db, sql: "SELECT id FROM items WHERE server_id = ? AND household_id = ? AND merged_into = ? ORDER BY id", arguments: sh + [out[i]])
            for m in more where !out.contains(m) { out.append(m) }
            i += 1
        }
        return [out[0]] + out.dropFirst().sorted()
    }

    func recountItemUsage(_ id: String) throws {
        try db.execute(sql: """
            UPDATE items SET
              use_count = (SELECT COUNT(*) FROM entries WHERE server_id = items.server_id AND household_id = items.household_id AND item_id = items.id),
              last_used_at = (SELECT MAX(CAST(substr(added_hlc, 1, 13) AS INTEGER)) FROM entries WHERE server_id = items.server_id AND household_id = items.household_id AND item_id = items.id)
            WHERE server_id = ? AND household_id = ? AND id = ?
            """, arguments: sh + [id])
    }

    func itemEvents() throws -> [Event] {
        try Row.fetchAll(db, sql: "SELECT * FROM events WHERE server_id = ? AND household_id = ? AND kind IN ('item.named','item.renamed','item.merged') ORDER BY hlc", arguments: sh).map(Event.init(row:))
    }

    func itemEvents(for itemIDs: [String]) throws -> [Event] {
        guard !itemIDs.isEmpty else { return [] }
        let sql = """
            SELECT e.* FROM events e WHERE e.server_id = ? AND e.household_id = ? AND (
              (e.kind IN ('flag.set','staple.added','staple.removed') AND e.item_id IN (\(marks(itemIDs.count))))
              OR (e.kind = 'trip.arrived' AND EXISTS (SELECT 1 FROM event_items ei WHERE ei.server_id = e.server_id AND ei.household_id = e.household_id AND ei.event_id = e.id AND ei.item_id IN (\(marks(itemIDs.count)))))
            ) ORDER BY e.hlc
            """
        return try Row.fetchAll(db, sql: sql, arguments: sh + StatementArguments(itemIDs) + StatementArguments(itemIDs)).map(Event.init(row:))
    }

    func hasEvent(_ id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM events WHERE server_id = ? AND household_id = ? AND id = ?)", arguments: sh + [id]) ?? false
    }

    func hasEvent(stamp: HLC) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM events WHERE server_id = ? AND household_id = ? AND hlc = ?)", arguments: sh + [stamp.description]) ?? false
    }

    // MARK: lists

    func list(_ id: String) throws -> ShoppingList? {
        try Row.fetchOne(db, sql: "SELECT * FROM lists WHERE server_id = ? AND household_id = ? AND id = ?", arguments: sh + [id]).map(ShoppingList.init(row:))
    }

    func putList(_ list: ShoppingList) throws {
        try db.execute(sql: ShoppingList.insert, arguments: list.arguments(scope))
    }

    func defaultListID() throws -> String? {
        try String.fetchOne(db, sql: "SELECT id FROM lists WHERE server_id = ? AND household_id = ? AND is_default = 1 ORDER BY id LIMIT 1", arguments: sh)
    }

    // MARK: entries

    /// The entry kinds a key's replay reads, spelled out so the (kind, list_id) index serves.
    static let entryKinds = "('entry.added','entry.edited','entry.checked','entry.unchecked','entry.moved','entry.removed')"

    func checkedItemIDs(listID: String, before: HLC) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM events WHERE server_id = ? AND household_id = ? AND kind = 'entry.checked' AND list_id = ? AND hlc < ? AND item_id IS NOT NULL",
                            arguments: sh + [listID, before.description])
    }

    func entryEvents(listID: String, itemIDs: [String]?, isDefault: Bool) throws -> [Event] {
        var clauses = ["(kind = 'entry.cleared' AND list_id = ?)"]
        var args: StatementArguments = sh + [listID]
        if let itemIDs {
            if itemIDs.isEmpty { return try cleared(listID) }
            clauses.append("(kind IN \(Self.entryKinds) AND list_id = ? AND item_id IN (\(marks(itemIDs.count))))")
            args += [listID] + StatementArguments(itemIDs)
            if isDefault {
                clauses.append("(kind = 'flag.set' AND item_id IN (\(marks(itemIDs.count))))")
                args += StatementArguments(itemIDs)
                clauses.append("(kind = 'trip.arrived' AND EXISTS (SELECT 1 FROM event_items ei WHERE ei.server_id = events.server_id AND ei.household_id = events.household_id AND ei.event_id = events.id AND ei.item_id IN (\(marks(itemIDs.count)))))")
                args += StatementArguments(itemIDs)
            }
        } else {
            clauses.append("(kind IN \(Self.entryKinds) AND list_id = ?)")
            args += [listID]
            if isDefault {
                clauses.append("(kind = 'flag.set')")
                clauses.append("(kind = 'trip.arrived')")
            }
        }
        let sql = "SELECT * FROM events WHERE server_id = ? AND household_id = ? AND (" + clauses.joined(separator: " OR ") + ") ORDER BY hlc"
        let events = try Row.fetchAll(db, sql: sql, arguments: args).map(Event.init(row:))
        return events.filter { ev in
            guard ev.kind == Kind.flagSet else { return true }
            return (try? ev.decode(FlagPayload.self))?.state == "out"
        }
    }

    private func cleared(_ listID: String) throws -> [Event] {
        try Row.fetchAll(db, sql: "SELECT * FROM events WHERE server_id = ? AND household_id = ? AND kind = 'entry.cleared' AND list_id = ? ORDER BY hlc", arguments: sh + [listID]).map(Event.init(row:))
    }

    func entryListIDs(itemIDs: [String]) throws -> [String] {
        guard !itemIDs.isEmpty else { return [] }
        return try String.fetchAll(db, sql: "SELECT DISTINCT list_id FROM events WHERE server_id = ? AND household_id = ? AND kind LIKE 'entry.%' AND list_id IS NOT NULL AND item_id IN (\(marks(itemIDs.count))) ORDER BY list_id", arguments: sh + StatementArguments(itemIDs))
    }

    func entries(listID: String, itemIDs: [String]) throws -> [Entry] {
        if itemIDs.isEmpty {
            return try Row.fetchAll(db, sql: "SELECT * FROM entries WHERE server_id = ? AND household_id = ? AND list_id = ? ORDER BY id", arguments: sh + [listID]).map(Entry.init(row:))
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM entries WHERE server_id = ? AND household_id = ? AND list_id = ? AND item_id IN (\(marks(itemIDs.count))) ORDER BY id", arguments: sh + [listID] + StatementArguments(itemIDs)).map(Entry.init(row:))
    }

    func replaceEntries(listID: String, itemIDs: [String], rows: [Entry]) throws {
        if !itemIDs.isEmpty {
            try db.execute(sql: "DELETE FROM entries WHERE server_id = ? AND household_id = ? AND list_id = ? AND item_id IN (\(marks(itemIDs.count)))", arguments: sh + [listID] + StatementArguments(itemIDs))
        }
        for r in rows {
            try db.execute(sql: Entry.insert, arguments: r.arguments(scope))
        }
    }

    func clearedEntries(itemIDs: [String], forHome homeID: String) throws -> [Entry] {
        guard !itemIDs.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: "SELECT * FROM entries WHERE server_id = ? AND household_id = ? AND cleared_hlc IS NOT NULL AND for_home_id = ? AND item_id IN (\(marks(itemIDs.count))) ORDER BY id", arguments: sh + [homeID] + StatementArguments(itemIDs)).map(Entry.init(row:))
    }

    // MARK: flags and staples

    func flag(homeID: String, itemID: String) throws -> Flag? {
        try Row.fetchOne(db, sql: "SELECT * FROM flags WHERE server_id = ? AND household_id = ? AND home_id = ? AND item_id = ?", arguments: sh + [homeID, itemID]).map(Flag.init(row:))
    }

    func putFlag(_ flag: Flag) throws {
        try db.execute(sql: Flag.insert, arguments: flag.arguments(scope))
    }

    func deleteFlag(homeID: String, itemID: String) throws {
        try db.execute(sql: "DELETE FROM flags WHERE server_id = ? AND household_id = ? AND home_id = ? AND item_id = ?", arguments: sh + [homeID, itemID])
    }

    func deleteFlags(forItems itemIDs: [String]) throws {
        guard !itemIDs.isEmpty else { return }
        try db.execute(sql: "DELETE FROM flags WHERE server_id = ? AND household_id = ? AND item_id IN (\(marks(itemIDs.count)))", arguments: sh + StatementArguments(itemIDs))
    }

    func flags(forItems itemIDs: [String]) throws -> [Flag] {
        guard !itemIDs.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: "SELECT * FROM flags WHERE server_id = ? AND household_id = ? AND item_id IN (\(marks(itemIDs.count))) ORDER BY home_id, item_id", arguments: sh + StatementArguments(itemIDs)).map(Flag.init(row:))
    }

    func staple(homeID: String, itemID: String) throws -> Staple? {
        try Row.fetchOne(db, sql: "SELECT * FROM staples WHERE server_id = ? AND household_id = ? AND home_id = ? AND item_id = ?", arguments: sh + [homeID, itemID]).map(Staple.init(row:))
    }

    func putStaple(_ staple: Staple) throws {
        try db.execute(sql: Staple.insert, arguments: staple.arguments(scope))
    }

    func deleteStaples(forItems itemIDs: [String]) throws {
        guard !itemIDs.isEmpty else { return }
        try db.execute(sql: "DELETE FROM staples WHERE server_id = ? AND household_id = ? AND item_id IN (\(marks(itemIDs.count)))", arguments: sh + StatementArguments(itemIDs))
    }

    func staples(forItems itemIDs: [String]) throws -> [Staple] {
        guard !itemIDs.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: "SELECT * FROM staples WHERE server_id = ? AND household_id = ? AND item_id IN (\(marks(itemIDs.count))) ORDER BY home_id, item_id", arguments: sh + StatementArguments(itemIDs)).map(Staple.init(row:))
    }

    // MARK: homes, spots, photos, trips

    func home(_ id: String) throws -> Home? {
        try Row.fetchOne(db, sql: "SELECT * FROM homes WHERE server_id = ? AND household_id = ? AND id = ?", arguments: sh + [id]).map(Home.init(row:))
    }

    func putHome(_ home: Home) throws {
        try db.execute(sql: Home.insert, arguments: home.arguments(scope))
    }

    func spot(_ id: String) throws -> Spot? {
        try Row.fetchOne(db, sql: "SELECT * FROM spots WHERE server_id = ? AND household_id = ? AND id = ?", arguments: sh + [id]).map(Spot.init(row:))
    }

    func putSpot(_ spot: Spot) throws {
        try db.execute(sql: Spot.insert, arguments: spot.arguments(scope))
    }

    func putPhoto(_ photo: Photo) throws {
        try db.execute(sql: Photo.insert, arguments: photo.arguments(scope))
    }

    func trip(_ id: String) throws -> Trip? {
        try Row.fetchOne(db, sql: "SELECT * FROM trips WHERE server_id = ? AND household_id = ? AND id = ?", arguments: [scope.serverID, scope.householdID, id]).map(Trip.init(row:))
    }

    func putTrip(_ trip: Trip) throws {
        try db.execute(sql: Trip.insert, arguments: trip.arguments(scope))
    }

    // MARK: the whole household

    /// Every materialised table, sorted.
    func tables() throws -> Tables {
        var t = Tables()
        t.items = try items()
        t.aliases = try aliases()
        t.lists = try Row.fetchAll(db, sql: "SELECT * FROM lists WHERE server_id = ? AND household_id = ?", arguments: sh).map(ShoppingList.init(row:))
        t.entries = try Row.fetchAll(db, sql: "SELECT * FROM entries WHERE server_id = ? AND household_id = ?", arguments: sh).map(Entry.init(row:))
        t.flags = try Row.fetchAll(db, sql: "SELECT * FROM flags WHERE server_id = ? AND household_id = ?", arguments: sh).map(Flag.init(row:))
        t.staples = try Row.fetchAll(db, sql: "SELECT * FROM staples WHERE server_id = ? AND household_id = ?", arguments: sh).map(Staple.init(row:))
        t.homes = try Row.fetchAll(db, sql: "SELECT * FROM homes WHERE server_id = ? AND household_id = ?", arguments: sh).map(Home.init(row:))
        t.spots = try Row.fetchAll(db, sql: "SELECT * FROM spots WHERE server_id = ? AND household_id = ?", arguments: sh).map(Spot.init(row:))
        t.photos = try Row.fetchAll(db, sql: "SELECT * FROM photos WHERE server_id = ? AND household_id = ?", arguments: sh).map(Photo.init(row:))
        t.trips = try Row.fetchAll(db, sql: "SELECT * FROM trips WHERE server_id = ? AND household_id = ?", arguments: sh).map(Trip.init(row:))
        t.sort()
        return t
    }

    /// Writes a snapshot's tables in place of the household's.
    func replaceTables(_ t: Tables) throws {
        for table in ["items", "item_aliases", "lists", "entries", "flags", "staples", "homes", "spots", "photos", "trips"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ? AND household_id = ?", arguments: sh)
        }
        for r in t.items { try putItem(r) }
        try replaceAliases(t.aliases)
        for r in t.lists { try putList(r) }
        for r in t.entries { try db.execute(sql: Entry.insert, arguments: r.arguments(scope)) }
        for r in t.flags { try putFlag(r) }
        for r in t.staples { try putStaple(r) }
        for r in t.homes { try putHome(r) }
        for r in t.spots { try putSpot(r) }
        for r in t.photos { try putPhoto(r) }
        for r in t.trips { try putTrip(r) }
    }

    /// Appends an event to the log, folds it, and returns false when the id was there already.
    /// seq is the server's number, nil for an event of this device not yet accepted.
    @discardableResult
    func append(_ e: Event, seq: Int64?) throws -> Bool {
        if let had = try Int64?.fetchOne(db, sql: "SELECT seq FROM events WHERE server_id = ? AND household_id = ? AND id = ?", arguments: sh + [e.id]) {
            if had == nil, let seq {
                try db.execute(sql: "UPDATE events SET seq = ? WHERE server_id = ? AND household_id = ? AND id = ?", arguments: [seq] + sh + [e.id])
            }
            return false
        }
        let refs = try? e.decode(ItemRefs.self)
        try db.execute(sql: "INSERT INTO events (server_id, household_id, id, seq, person_id, hlc, kind, payload, list_id, item_id) VALUES (?,?,?,?,?,?,?,?,?,?)",
                       arguments: sh + [e.id, seq, e.personID, e.hlc.description, e.kind, e.payload.string, refs?.listID, refs?.itemID])
        for item in refs?.moved ?? [] {
            try db.execute(sql: "INSERT OR IGNORE INTO event_items (server_id, household_id, event_id, item_id) VALUES (?,?,?,?)", arguments: sh + [e.id, item])
        }
        try Fold.apply(e, to: self)
        return true
    }
}
