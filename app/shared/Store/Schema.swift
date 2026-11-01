// The local store's schema: the server's household tables mirrored, every row keyed by
// (server_id, household_id), with the household's event log, the outbox, the cursors and the
// server context. GRDB migrations; a new table or column is a new migration.
import Foundation
import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "contexts") { t in
                t.column("server_id", .text).primaryKey()
                t.column("base_url", .text).notNull()
                t.column("credential_id", .text).notNull()
                t.column("person_id", .text).notNull()
                t.column("display_name", .text).notNull().defaults(to: "")
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "households") { t in
                t.column("server_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("timezone", .text).notNull().defaults(to: "")
                t.column("staleness_days", .integer)
                t.column("role", .text).notNull()
                t.primaryKey(["server_id", "id"])
            }
            try db.create(table: "events") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("seq", .integer)
                t.column("person_id", .text).notNull()
                t.column("hlc", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("payload", .text).notNull()
                // what the fold's queries filter by, lifted out of the payload at insert
                t.column("list_id", .text)
                t.column("item_id", .text)
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.create(indexOn: "events", columns: ["server_id", "household_id", "kind", "list_id"])
            try db.create(indexOn: "events", columns: ["server_id", "household_id", "item_id"])
            try db.create(indexOn: "events", columns: ["server_id", "household_id", "hlc"])
            try db.create(indexOn: "events", columns: ["server_id", "household_id", "seq"])
            try db.create(table: "event_items") { t in
                // the moved items of a trip, one row each
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("event_id", .text).notNull()
                t.column("item_id", .text).notNull()
                t.primaryKey(["server_id", "household_id", "event_id", "item_id"])
            }
            try db.create(table: "outbox") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("event_id", .text).notNull()
                t.column("body", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.primaryKey(["server_id", "household_id", "event_id"])
            }
            try db.create(table: "cursors") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("since", .integer).notNull().defaults(to: 0)
                t.primaryKey(["server_id", "household_id"])
            }
            try db.create(table: "items") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("norm_name", .text)
                t.column("category", .text)
                t.column("last_used_at", .integer)
                t.column("use_count", .integer).notNull().defaults(to: 0)
                t.column("archived_at", .integer)
                t.column("merged_into", .text)
                t.column("created_hlc", .text).notNull()
                t.column("updated_hlc", .text).notNull()
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.create(indexOn: "items", columns: ["server_id", "household_id", "norm_name"])
            try db.create(table: "item_aliases") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("item_id", .text).notNull()
                t.column("norm_name", .text).notNull()
                t.primaryKey(["server_id", "household_id", "norm_name"])
            }
            try db.create(table: "lists") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("colour", .text).notNull().defaults(to: "")
                t.column("owner_person_id", .text)
                t.column("sort", .integer).notNull().defaults(to: 0)
                t.column("is_default", .integer).notNull().defaults(to: 0)
                t.column("archived_at", .integer)
                t.column("updated_hlc", .text)
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.create(table: "entries") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("list_id", .text).notNull()
                t.column("item_id", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("qty", .double)
                t.column("unit", .text)
                t.column("for_home_id", .text)
                t.column("sort", .double).notNull().defaults(to: 0)
                t.column("added_hlc", .text).notNull()
                t.column("added_by", .text).notNull()
                t.column("checked_hlc", .text)
                t.column("checked_by", .text)
                t.column("cleared_hlc", .text)
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.create(indexOn: "entries", columns: ["server_id", "household_id", "list_id", "item_id"])
            try db.create(table: "flags") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("home_id", .text).notNull()
                t.column("item_id", .text).notNull()
                t.column("state", .text).notNull()
                t.column("set_hlc", .text).notNull()
                t.column("set_by", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.primaryKey(["server_id", "household_id", "home_id", "item_id"])
            }
            try db.create(table: "staples") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("home_id", .text).notNull()
                t.column("item_id", .text).notNull()
                t.column("sort", .integer).notNull().defaults(to: 0)
                t.column("added_hlc", .text)
                t.column("removed_hlc", .text)
                t.primaryKey(["server_id", "household_id", "home_id", "item_id"])
            }
            try db.create(table: "homes") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("sort", .integer).notNull().defaults(to: 0)
                t.column("archived_at", .integer)
                t.column("updated_hlc", .text)
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.create(table: "spots") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("home_id", .text).notNull().defaults(to: "")
                t.column("name", .text).notNull().defaults(to: "")
                t.column("sort", .integer).notNull().defaults(to: 0)
                t.column("archived_at", .integer)
                t.column("updated_hlc", .text)
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.create(table: "photos") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("spot_id", .text).notNull()
                t.column("taken_hlc", .text).notNull()
                t.column("taken_by", .text).notNull()
                t.column("bytes", .integer).notNull().defaults(to: 0)
                t.column("width", .integer).notNull().defaults(to: 0)
                t.column("height", .integer).notNull().defaults(to: 0)
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.create(table: "trips") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("from_home_id", .text).notNull()
                t.column("to_home_id", .text).notNull()
                t.column("date", .integer).notNull()
                t.column("created_by", .text).notNull()
                t.column("arrived_at", .integer).notNull()
                t.primaryKey(["server_id", "household_id", "id"])
            }
        }
        return m
    }

    /// The household tables, in the order a wipe deletes them.
    static let householdTables = ["event_items", "events", "outbox", "cursors", "items", "item_aliases", "lists", "entries", "flags", "staples", "homes", "spots", "photos", "trips"]
}

/// One household on one server, as every query is scoped.
struct Scope: Hashable, Sendable {
    var serverID: String
    var householdID: String
    var personID: String
}

// MARK: Rows from and to SQL

extension HLC {
    init?(column v: String?) {
        guard let v, let h = HLC(parsing: v) else { return nil }
        self = h
    }
}

extension Item {
    init(row r: Row) {
        self.init(id: r["id"], name: r["name"], normName: r["norm_name"], category: r["category"], lastUsedAt: r["last_used_at"],
                  useCount: r["use_count"], archivedAt: r["archived_at"], mergedInto: r["merged_into"],
                  createdHLC: HLC(column: r["created_hlc"]) ?? HLC(wall: 0, device: "-"), updatedHLC: HLC(column: r["updated_hlc"]) ?? HLC(wall: 0, device: "-"))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, name, normName, category, lastUsedAt, useCount, archivedAt, mergedInto, createdHLC.description, updatedHLC.description]
    }
    static let insert = "INSERT OR REPLACE INTO items (server_id, household_id, id, name, norm_name, category, last_used_at, use_count, archived_at, merged_into, created_hlc, updated_hlc) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
}

extension ItemAlias {
    init(row r: Row) { self.init(itemID: r["item_id"], normName: r["norm_name"]) }
}

extension List {
    init(row r: Row) {
        self.init(id: r["id"], name: r["name"], colour: r["colour"], ownerPersonID: r["owner_person_id"], sort: r["sort"],
                  isDefault: (r["is_default"] as Int64) != 0, archivedAt: r["archived_at"], updatedHLC: HLC(column: r["updated_hlc"]))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, name, colour, ownerPersonID, sort, isDefault ? 1 : 0, archivedAt, updatedHLC?.description]
    }
    static let insert = "INSERT OR REPLACE INTO lists (server_id, household_id, id, name, colour, owner_person_id, sort, is_default, archived_at, updated_hlc) VALUES (?,?,?,?,?,?,?,?,?,?)"
}

extension Entry {
    init(row r: Row) {
        self.init(id: r["id"], listID: r["list_id"], itemID: r["item_id"], note: r["note"], qty: r["qty"], unit: r["unit"], forHomeID: r["for_home_id"],
                  sort: r["sort"], addedHLC: HLC(column: r["added_hlc"]) ?? HLC(wall: 0, device: "-"), addedBy: r["added_by"],
                  checkedHLC: HLC(column: r["checked_hlc"]), checkedBy: r["checked_by"], clearedHLC: HLC(column: r["cleared_hlc"]))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, listID, itemID, note, qty, unit, forHomeID, sort, addedHLC.description, addedBy, checkedHLC?.description, checkedBy, clearedHLC?.description]
    }
    static let insert = "INSERT OR REPLACE INTO entries (server_id, household_id, id, list_id, item_id, note, qty, unit, for_home_id, sort, added_hlc, added_by, checked_hlc, checked_by, cleared_hlc) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
}

extension Flag {
    init(row r: Row) {
        self.init(homeID: r["home_id"], itemID: r["item_id"], state: r["state"], setHLC: HLC(column: r["set_hlc"]) ?? HLC(wall: 0, device: "-"), setBy: r["set_by"], note: r["note"])
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, homeID, itemID, state, setHLC.description, setBy, note]
    }
    static let insert = "INSERT OR REPLACE INTO flags (server_id, household_id, home_id, item_id, state, set_hlc, set_by, note) VALUES (?,?,?,?,?,?,?,?)"
}

extension Staple {
    init(row r: Row) {
        self.init(homeID: r["home_id"], itemID: r["item_id"], sort: r["sort"], addedHLC: HLC(column: r["added_hlc"]), removedHLC: HLC(column: r["removed_hlc"]))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, homeID, itemID, sort, addedHLC?.description, removedHLC?.description]
    }
    static let insert = "INSERT OR REPLACE INTO staples (server_id, household_id, home_id, item_id, sort, added_hlc, removed_hlc) VALUES (?,?,?,?,?,?,?)"
}

extension Home {
    init(row r: Row) {
        self.init(id: r["id"], name: r["name"], sort: r["sort"], archivedAt: r["archived_at"], updatedHLC: HLC(column: r["updated_hlc"]))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, name, sort, archivedAt, updatedHLC?.description]
    }
    static let insert = "INSERT OR REPLACE INTO homes (server_id, household_id, id, name, sort, archived_at, updated_hlc) VALUES (?,?,?,?,?,?,?)"
}

extension Spot {
    init(row r: Row) {
        self.init(id: r["id"], homeID: r["home_id"], name: r["name"], sort: r["sort"], archivedAt: r["archived_at"], updatedHLC: HLC(column: r["updated_hlc"]))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, homeID, name, sort, archivedAt, updatedHLC?.description]
    }
    static let insert = "INSERT OR REPLACE INTO spots (server_id, household_id, id, home_id, name, sort, archived_at, updated_hlc) VALUES (?,?,?,?,?,?,?,?)"
}

extension Photo {
    init(row r: Row) {
        self.init(id: r["id"], spotID: r["spot_id"], takenHLC: HLC(column: r["taken_hlc"]) ?? HLC(wall: 0, device: "-"), takenBy: r["taken_by"], bytes: r["bytes"], width: r["width"], height: r["height"])
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, spotID, takenHLC.description, takenBy, bytes, width, height]
    }
    static let insert = "INSERT OR IGNORE INTO photos (server_id, household_id, id, spot_id, taken_hlc, taken_by, bytes, width, height) VALUES (?,?,?,?,?,?,?,?,?)"
}

extension Trip {
    init(row r: Row) {
        self.init(id: r["id"], fromHomeID: r["from_home_id"], toHomeID: r["to_home_id"], date: r["date"], createdBy: r["created_by"], arrivedAt: r["arrived_at"])
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, fromHomeID, toHomeID, date, createdBy, arrivedAt]
    }
    static let insert = "INSERT OR IGNORE INTO trips (server_id, household_id, id, from_home_id, to_home_id, date, created_by, arrived_at) VALUES (?,?,?,?,?,?,?,?)"
}

extension Event {
    init(row r: Row) {
        let raw: String = r["payload"]
        self.init(id: r["id"], personID: r["person_id"], hlc: HLC(column: r["hlc"]) ?? HLC(wall: 0, device: "-"), kind: r["kind"],
                  payload: (try? JSONValue(data: Data(raw.utf8))) ?? .object([:]))
    }
}
