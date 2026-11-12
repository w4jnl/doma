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
        // after v1, in order: a defer here would run after the struct was copied out
        // v2: what the fold's recount and the catalog's last-bought hint look entries up by
        m.registerMigration("v2") { db in
            try db.create(indexOn: "entries", columns: ["server_id", "household_id", "item_id"])
        }
        // v3: trips are planned before they are walked: the list they shop on, the plan's
        // stamp, arrived_at only once arrived, cancelled_at; SQLite cannot loosen a NOT NULL
        m.registerMigration("v3") { db in
            try db.create(table: "trips_new") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("from_home_id", .text).notNull().defaults(to: "")
                t.column("to_home_id", .text).notNull().defaults(to: "")
                t.column("date", .integer).notNull().defaults(to: 0)
                t.column("created_by", .text).notNull().defaults(to: "")
                t.column("list_id", .text)
                t.column("updated_hlc", .text)
                t.column("arrived_at", .integer)
                t.column("cancelled_at", .integer)
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.execute(sql: "INSERT INTO trips_new (server_id, household_id, id, from_home_id, to_home_id, date, created_by, arrived_at) SELECT server_id, household_id, id, from_home_id, to_home_id, date, created_by, arrived_at FROM trips")
            try db.drop(table: "trips")
            try db.rename(table: "trips_new", to: "trips")
        }
        // v4: a list's kind, '' for shopping and 'tasks' for things to do
        m.registerMigration("v4") { db in
            try db.alter(table: "lists") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "")
            }
        }
        // v5: what a vision model proposed after a photo, open until answered
        m.registerMigration("v5") { db in
            try db.create(table: "proposals") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("home_id", .text).notNull()
                t.column("item_id", .text).notNull()
                t.column("state", .text).notNull()
                t.column("photo_id", .text).notNull().defaults(to: "")
                t.column("proposed_hlc", .text).notNull()
                t.column("closed_hlc", .text)
                t.primaryKey(["server_id", "household_id", "id"])
            }
            try db.create(indexOn: "proposals", columns: ["server_id", "household_id", "home_id", "item_id"])
        }
        // v6: the family's loyalty cards
        m.registerMigration("v6") { db in
            try db.create(table: "cards") { t in
                t.column("server_id", .text).notNull()
                t.column("household_id", .text).notNull()
                t.column("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("colour", .text).notNull().defaults(to: "")
                t.column("owner_person_id", .text)
                t.column("format", .text).notNull()
                t.column("value", .text).notNull()
                t.column("domain", .text)
                t.column("logo_id", .text)
                t.column("logo_hlc", .text)
                t.column("updated_hlc", .text)
                t.column("archived_at", .integer)
                t.primaryKey(["server_id", "household_id", "id"])
            }
        }
        // v7: a staple's section, the name of the group it is shown under
        m.registerMigration("v7") { db in
            try db.alter(table: "staples") { t in
                t.add(column: "section", .text).notNull().defaults(to: "")
                t.add(column: "section_hlc", .text)
            }
        }
        return m
    }

    /// The household tables, in the order a wipe deletes them.
    static let householdTables = ["event_items", "events", "outbox", "cursors", "items", "item_aliases", "lists", "entries", "flags", "staples", "homes", "spots", "photos", "trips", "proposals", "cards"]
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

extension ShoppingList {
    init(row r: Row) {
        self.init(id: r["id"], name: r["name"], colour: r["colour"], ownerPersonID: r["owner_person_id"], sort: r["sort"],
                  isDefault: (r["is_default"] as Int64) != 0, archivedAt: r["archived_at"], updatedHLC: HLC(column: r["updated_hlc"]), kind: r["kind"] ?? "")
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, name, colour, ownerPersonID, sort, isDefault ? 1 : 0, archivedAt, updatedHLC?.description, kind]
    }
    static let insert = "INSERT OR REPLACE INTO lists (server_id, household_id, id, name, colour, owner_person_id, sort, is_default, archived_at, updated_hlc, kind) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
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

extension Proposal {
    init(row r: Row) {
        self.init(id: r["id"], homeID: r["home_id"], itemID: r["item_id"], state: r["state"], photoID: r["photo_id"] ?? "",
                  proposedHLC: HLC(column: r["proposed_hlc"]) ?? HLC(wall: 0, device: "-"), closedHLC: HLC(column: r["closed_hlc"]))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, homeID, itemID, state, photoID, proposedHLC.description, closedHLC?.description]
    }
    static let insert = "INSERT OR REPLACE INTO proposals (server_id, household_id, id, home_id, item_id, state, photo_id, proposed_hlc, closed_hlc) VALUES (?,?,?,?,?,?,?,?,?)"
}

extension Staple {
    init(row r: Row) {
        self.init(homeID: r["home_id"], itemID: r["item_id"], sort: r["sort"], section: r["section"], sectionHLC: HLC(column: r["section_hlc"]), addedHLC: HLC(column: r["added_hlc"]), removedHLC: HLC(column: r["removed_hlc"]))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, homeID, itemID, sort, section, sectionHLC?.description, addedHLC?.description, removedHLC?.description]
    }
    static let insert = "INSERT OR REPLACE INTO staples (server_id, household_id, home_id, item_id, sort, section, section_hlc, added_hlc, removed_hlc) VALUES (?,?,?,?,?,?,?,?,?)"
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

extension Card {
    init(row r: Row) {
        self.init(id: r["id"], name: r["name"], colour: r["colour"], ownerPersonID: r["owner_person_id"], format: r["format"], value: r["value"],
                  domain: r["domain"], logoID: r["logo_id"], updatedHLC: HLC(column: r["updated_hlc"]), archivedAt: r["archived_at"], logoHLC: HLC(column: r["logo_hlc"]))
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, name, colour, ownerPersonID, format, value, domain, logoID, logoHLC?.description, updatedHLC?.description, archivedAt]
    }
    static let insert = "INSERT OR REPLACE INTO cards (server_id, household_id, id, name, colour, owner_person_id, format, value, domain, logo_id, logo_hlc, updated_hlc, archived_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
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
        self.init(id: r["id"], fromHomeID: r["from_home_id"], toHomeID: r["to_home_id"], date: r["date"], createdBy: r["created_by"], listID: r["list_id"], updatedHLC: HLC(column: r["updated_hlc"]), arrivedAt: r["arrived_at"], cancelledAt: r["cancelled_at"])
    }
    func arguments(_ s: Scope) -> StatementArguments {
        [s.serverID, s.householdID, id, fromHomeID, toHomeID, date, createdBy, listID, updatedHLC?.description, arrivedAt, cancelledAt]
    }
    static let insert = "INSERT OR REPLACE INTO trips (server_id, household_id, id, from_home_id, to_home_id, date, created_by, list_id, updated_hlc, arrived_at, cancelled_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
}

extension Event {
    init(row r: Row) {
        let raw: String = r["payload"]
        let data = Data(raw.utf8)
        self.init(id: r["id"], personID: r["person_id"], hlc: HLC(column: r["hlc"]) ?? HLC(wall: 0, device: "-"), kind: r["kind"],
                  payload: (try? JSONValue(data: data)) ?? .object([:]))
        rawPayload = data
    }
}
