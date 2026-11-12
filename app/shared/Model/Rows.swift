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
    /// "" for a shopping list, "tasks" for things to do; set by list.created and never changed.
    var kind: String = ""
    var isTasks: Bool { kind == "tasks" }
    enum CodingKeys: String, CodingKey {
        case id, name, colour, sort, kind
        case ownerPersonID = "owner_person_id", isDefault = "is_default", archivedAt = "archived_at", updatedHLC = "updated_hlc"
    }

    init(id: String, name: String = "", colour: String = "", ownerPersonID: String? = nil, sort: Int64 = 0, isDefault: Bool = false, archivedAt: Int64? = nil, updatedHLC: HLC? = nil, kind: String = "") {
        self.id = id
        self.name = name
        self.colour = colour
        self.ownerPersonID = ownerPersonID
        self.sort = sort
        self.isDefault = isDefault
        self.archivedAt = archivedAt
        self.updatedHLC = updatedHLC
        self.kind = kind
    }

    /// A snapshot from a server older than the kind column has no `kind`; it reads as shopping.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colour = try c.decodeIfPresent(String.self, forKey: .colour) ?? ""
        ownerPersonID = try c.decodeIfPresent(String.self, forKey: .ownerPersonID)
        sort = try c.decodeIfPresent(Int64.self, forKey: .sort) ?? 0
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        archivedAt = try c.decodeIfPresent(Int64.self, forKey: .archivedAt)
        updatedHLC = try c.decodeIfPresent(HLC.self, forKey: .updatedHLC)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
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
    /// The group the staple is shown under, "" for none.
    var section = ""
    /// The latest add that named a section, nil when none has.
    var sectionHLC: HLC?
    /// The latest add, nil when only a remove has been seen.
    var addedHLC: HLC?
    var removedHLC: HLC?
    enum CodingKeys: String, CodingKey {
        case sort, section
        case homeID = "home_id", itemID = "item_id", sectionHLC = "section_hlc", addedHLC = "added_hlc", removedHLC = "removed_hlc"
    }

    init(homeID: String, itemID: String, sort: Int64 = 0, section: String = "", sectionHLC: HLC? = nil, addedHLC: HLC? = nil, removedHLC: HLC? = nil) {
        self.homeID = homeID
        self.itemID = itemID
        self.sort = sort
        self.section = section
        self.sectionHLC = sectionHLC
        self.addedHLC = addedHLC
        self.removedHLC = removedHLC
    }

    /// A server from before sections sends a staple without one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homeID = try c.decode(String.self, forKey: .homeID)
        itemID = try c.decode(String.self, forKey: .itemID)
        sort = try c.decodeIfPresent(Int64.self, forKey: .sort) ?? 0
        section = try c.decodeIfPresent(String.self, forKey: .section) ?? ""
        sectionHLC = try c.decodeIfPresent(HLC.self, forKey: .sectionHLC)
        addedHLC = try c.decodeIfPresent(HLC.self, forKey: .addedHLC)
        removedHLC = try c.decodeIfPresent(HLC.self, forKey: .removedHLC)
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

/// A planned trip (trip.planned, last-writer-wins on updatedHLC for from, to, date, list and
/// planner), arrived (arrivedAt), cancelled (cancelledAt), or arrived without a plan (the
/// arrival's wall as its date).
struct Trip: Hashable, Sendable, Codable {
    var id: String
    var fromHomeID: String = ""
    var toHomeID: String = ""
    var date: Int64 = 0
    var createdBy: String = ""
    var listID: String?
    var updatedHLC: HLC?
    var arrivedAt: Int64?
    var cancelledAt: Int64?
    enum CodingKeys: String, CodingKey {
        case id, date
        case fromHomeID = "from_home_id", toHomeID = "to_home_id", createdBy = "created_by", listID = "list_id"
        case updatedHLC = "updated_hlc", arrivedAt = "arrived_at", cancelledAt = "cancelled_at"
    }
}

/// Every materialised table, the form a snapshot carries and the fixture states expectations
/// in. Canonical drops every zero field, so two stores compare on what matters.
/// What a vision model suggested after a photo: a flag change at a home, open until a flag is
/// written after it, it is declined, or a newer proposal for the item arrives.
struct Proposal: Hashable, Sendable, Codable {
    var id: String
    var homeID: String
    var itemID: String
    var state: String
    var photoID: String = ""
    var proposedHLC: HLC
    var closedHLC: HLC?
    var isOpen: Bool { closedHLC == nil }
    enum CodingKeys: String, CodingKey {
        case id, state
        case homeID = "home_id", itemID = "item_id", photoID = "photo_id", proposedHLC = "proposed_hlc", closedHLC = "closed_hlc"
    }
}

/// A loyalty card: the household's (no owner) or one person's, with its barcode and, once the
/// server fetched it, its logo; logoHLC orders the server's card.logo events among themselves.
struct Card: Hashable, Sendable, Codable {
    var id: String
    var name: String = ""
    var colour: String = ""
    var ownerPersonID: String?
    var format: String = ""
    var value: String = ""
    var domain: String?
    var logoID: String?
    var updatedHLC: HLC?
    var archivedAt: Int64?
    var logoHLC: HLC?
    enum CodingKeys: String, CodingKey {
        case id, name, colour, format, value, domain
        case ownerPersonID = "owner_person_id", logoID = "logo_id", updatedHLC = "updated_hlc", archivedAt = "archived_at", logoHLC = "logo_hlc"
    }

    /// The barcode symbologies the apps draw and read, as the event schema spells them.
    static let formats = ["ean13", "ean8", "upca", "upce", "code128", "code39", "code93", "itf14", "codabar", "qr", "aztec", "pdf417", "datamatrix"]
}

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
    var proposals: [Proposal] = []
    var cards: [Card] = []
    enum CodingKeys: String, CodingKey {
        case items, lists, entries, flags, staples, homes, spots, photos, trips, proposals, cards
        case aliases = "item_aliases"
    }

    static let names = ["items", "item_aliases", "lists", "entries", "flags", "staples", "homes", "spots", "photos", "trips", "proposals", "cards"]

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
        proposals.sort { $0.id < $1.id }
        cards.sort { $0.id < $1.id }
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

extension Tables {
    /// A snapshot from a server older than a table reads with that table empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        aliases = try c.decodeIfPresent([ItemAlias].self, forKey: .aliases) ?? []
        lists = try c.decodeIfPresent([ShoppingList].self, forKey: .lists) ?? []
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        flags = try c.decodeIfPresent([Flag].self, forKey: .flags) ?? []
        staples = try c.decodeIfPresent([Staple].self, forKey: .staples) ?? []
        homes = try c.decodeIfPresent([Home].self, forKey: .homes) ?? []
        spots = try c.decodeIfPresent([Spot].self, forKey: .spots) ?? []
        photos = try c.decodeIfPresent([Photo].self, forKey: .photos) ?? []
        trips = try c.decodeIfPresent([Trip].self, forKey: .trips) ?? []
        proposals = try c.decodeIfPresent([Proposal].self, forKey: .proposals) ?? []
    }
}
