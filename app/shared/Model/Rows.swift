// The rows of the materialised tables, as internal/fold/fold.go has them and as the store keeps
// them. Field names in JSON are the server's, so a snapshot decodes straight into these and the
// fixture's expectations compare against them.
import Foundation

struct Item: Hashable, Sendable, Codable {
    var id: String
    var name: String
    var normName: String?
    var category: String?
    var lastUsedAt: Int64?
    var useCount: Int64 = 0
    var archivedAt: Int64?
    var mergedInto: String?
    var createdHLC: HLC
    var updatedHLC: HLC
    enum CodingKeys: String, CodingKey {
        case id, name, category
        case normName = "norm_name", lastUsedAt = "last_used_at", useCount = "use_count", archivedAt = "archived_at"
        case mergedInto = "merged_into", createdHLC = "created_hlc", updatedHLC = "updated_hlc"
    }
}

struct ItemAlias: Hashable, Sendable, Codable {
    var itemID: String
    var normName: String
    enum CodingKeys: String, CodingKey {
        case itemID = "item_id", normName = "norm_name"
    }
}

struct ShoppingList: Hashable, Sendable, Codable {
    var id: String
    var name: String = ""
    var colour: String = ""
    var ownerPersonID: String?
    var sort: Int64 = 0
    var isDefault: Bool = false
    var archivedAt: Int64?
    var updatedHLC: HLC?
    enum CodingKeys: String, CodingKey {
        case id, name, colour, sort
        case ownerPersonID = "owner_person_id", isDefault = "is_default", archivedAt = "archived_at", updatedHLC = "updated_hlc"
    }
}

struct Entry: Hashable, Sendable, Codable {
    var id: String
    var listID: String
    var itemID: String
    var note: String = ""
    var qty: Double?
    var unit: String?
    var forHomeID: String?
    var sort: Double = 0
    var addedHLC: HLC
    var addedBy: String
    var checkedHLC: HLC?
    var checkedBy: String?
    var clearedHLC: HLC?
    enum CodingKeys: String, CodingKey {
        case id, note, qty, unit, sort
        case listID = "list_id", itemID = "item_id", forHomeID = "for_home_id", addedHLC = "added_hlc", addedBy = "added_by"
        case checkedHLC = "checked_hlc", checkedBy = "checked_by", clearedHLC = "cleared_hlc"
    }

    var isOpen: Bool { clearedHLC == nil }
    var isChecked: Bool { checkedHLC != nil && clearedHLC == nil }
}

struct Flag: Hashable, Sendable, Codable {
    var homeID: String
    var itemID: String
    var state: String
    var setHLC: HLC
    var setBy: String
    var note: String = ""
    enum CodingKeys: String, CodingKey {
        case state, note
        case homeID = "home_id", itemID = "item_id", setHLC = "set_hlc", setBy = "set_by"
    }
}

struct Staple: Hashable, Sendable, Codable {
    var homeID: String
    var itemID: String
    var sort: Int64 = 0
    /// The latest add, nil when only a remove has been seen.
    var addedHLC: HLC?
    var removedHLC: HLC?
    enum CodingKeys: String, CodingKey {
        case sort
        case homeID = "home_id", itemID = "item_id", addedHLC = "added_hlc", removedHLC = "removed_hlc"
    }

    /// On the home's list: the latest add is newer than the latest remove.
    var isPresent: Bool {
        guard let a = addedHLC else { return false }
        guard let r = removedHLC else { return true }
        return r < a
    }
}

struct Home: Hashable, Sendable, Codable {
    var id: String
    var name: String = ""
    var sort: Int64 = 0
    var archivedAt: Int64?
    var updatedHLC: HLC?
    enum CodingKeys: String, CodingKey {
        case id, name, sort
        case archivedAt = "archived_at", updatedHLC = "updated_hlc"
    }
}

struct Spot: Hashable, Sendable, Codable {
    var id: String
    var homeID: String = ""
    var name: String = ""
    var sort: Int64 = 0
    var archivedAt: Int64?
    var updatedHLC: HLC?
    enum CodingKeys: String, CodingKey {
        case id, name, sort
        case homeID = "home_id", archivedAt = "archived_at", updatedHLC = "updated_hlc"
    }
}

struct Photo: Hashable, Sendable, Codable {
    var id: String
    var spotID: String
    var takenHLC: HLC
    var takenBy: String
    var bytes: Int64 = 0
    var width: Int64 = 0
    var height: Int64 = 0
    enum CodingKeys: String, CodingKey {
        case id, bytes, width, height
        case spotID = "spot_id", takenHLC = "taken_hlc", takenBy = "taken_by"
    }
}

struct Trip: Hashable, Sendable, Codable {
    var id: String
    var fromHomeID: String
    var toHomeID: String
    var date: Int64
    var createdBy: String
    var arrivedAt: Int64
    enum CodingKeys: String, CodingKey {
        case id, date
        case fromHomeID = "from_home_id", toHomeID = "to_home_id", createdBy = "created_by", arrivedAt = "arrived_at"
    }
}

/// Every materialised table, the form a snapshot carries and the fixture states expectations
/// in. Canonical drops every zero field, so two stores compare on what matters.
struct Tables: Hashable, Sendable, Codable {
    var items: [Item] = []
    var aliases: [ItemAlias] = []
    var lists: [ShoppingList] = []
    var entries: [Entry] = []
    var flags: [Flag] = []
    var staples: [Staple] = []
    var homes: [Home] = []
    var spots: [Spot] = []
    var photos: [Photo] = []
    var trips: [Trip] = []
    enum CodingKeys: String, CodingKey {
        case items, lists, entries, flags, staples, homes, spots, photos, trips
        case aliases = "item_aliases"
    }

    static let names = ["items", "item_aliases", "lists", "entries", "flags", "staples", "homes", "spots", "photos", "trips"]

    mutating func sort() {
        items.sort { $0.id < $1.id }
        aliases.sort { $0.normName < $1.normName }
        lists.sort { $0.id < $1.id }
        entries.sort { $0.id < $1.id }
        flags.sort { ($0.homeID, $0.itemID) < ($1.homeID, $1.itemID) }
        staples.sort { ($0.homeID, $0.itemID) < ($1.homeID, $1.itemID) }
        homes.sort { $0.id < $1.id }
        spots.sort { $0.id < $1.id }
        photos.sort { $0.id < $1.id }
        trips.sort { $0.id < $1.id }
    }

    /// Sorted keys, pruned of zero fields, integral numbers as integers.
    var canonical: String {
        var t = self
        t.sort()
        let enc = JSONEncoder()
        guard let data = try? enc.encode(t), let v = try? JSONValue(data: data) else { return "" }
        return v.pruned.string
    }

    /// A fixture expectation rendered the same way: short stamps padded, missing tables empty.
    static func canonical(expectation raw: JSONValue) -> String {
        var v = padHLC(raw)
        if case .object(var o) = v {
            for name in names where o[name] == nil {
                o[name] = .array([])
            }
            v = .object(o)
        }
        return v.pruned.string
    }

    private static func padHLC(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o): return .object(o.mapValues(padHLC))
        case .array(let a): return .array(a.map(padHLC))
        case .string(let s):
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 3, Int64(parts[0]) != nil, Int(parts[1]) != nil, let h = HLC(parsing: s) {
                return .string(h.description)
            }
            return v
        default: return v
        }
    }
}
