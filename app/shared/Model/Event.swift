// Event is one log entry as the fold sees it (internal/fold/fold.go): the client's fields and
// the person it is attributed to. Payloads stay JSON so an unknown kind survives; the typed
// payloads below are what the fold decodes and what the app writes, built so they match
// docs/event-schema.json (EventSchemaTests checks every builder against the file).
import Foundation

struct Event: Hashable, Sendable, Codable {
    var id: String
    var personID: String
    var hlc: HLC
    var kind: String
    var payload: JSONValue
    /// The payload as it came from the log, when it did: decode reads it without re-encoding.
    var rawPayload: Data?

    enum CodingKeys: String, CodingKey {
        case id, hlc, kind, payload
        case personID = "person_id"
    }

    init(id: String, personID: String, hlc: HLC, kind: String, payload: JSONValue) {
        self.id = id
        self.personID = personID
        self.hlc = hlc
        self.kind = kind
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        personID = try c.decodeIfPresent(String.self, forKey: .personID) ?? ""
        hlc = try c.decode(HLC.self, forKey: .hlc)
        kind = try c.decode(String.self, forKey: .kind)
        payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:])
    }

    /// The payload as one of the typed shapes below.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: rawPayload ?? payload.data)
        } catch {
            throw FoldError.badPayload(kind: kind, id: id, reason: String(describing: error))
        }
    }
}

/// Every event kind the fold knows, in the order of the design document's table.
enum Kind {
    static let itemNamed = "item.named", itemRenamed = "item.renamed", itemMerged = "item.merged"
    static let listCreated = "list.created", listRenamed = "list.renamed", listArchived = "list.archived"
    static let entryAdded = "entry.added", entryEdited = "entry.edited", entryChecked = "entry.checked"
    static let entryUnchecked = "entry.unchecked", entryCleared = "entry.cleared", entryMoved = "entry.moved"
    static let flagSet = "flag.set"
    static let stapleAdded = "staple.added", stapleRemoved = "staple.removed"
    static let homeCreated = "home.created", homeRenamed = "home.renamed", homeArchived = "home.archived"
    static let spotCreated = "spot.created", spotRenamed = "spot.renamed", spotArchived = "spot.archived"
    static let photoAdded = "photo.added"
    static let tripArrived = "trip.arrived"
    static let memberRemoved = "member.removed", deviceRevoked = "device.revoked"

    static let all = [itemNamed, itemRenamed, itemMerged, listCreated, listRenamed, listArchived,
                      entryAdded, entryEdited, entryChecked, entryUnchecked, entryCleared, entryMoved,
                      flagSet, stapleAdded, stapleRemoved, homeCreated, homeRenamed, homeArchived,
                      spotCreated, spotRenamed, spotArchived, photoAdded, tripArrived, memberRemoved, deviceRevoked]
}

// MARK: Payloads

struct ItemPayload: Codable, Sendable {
    var itemID: String?
    var name: String?
    var keepID: String?
    var dropID: String?
    enum CodingKeys: String, CodingKey {
        case name
        case itemID = "item_id", keepID = "keep_id", dropID = "drop_id"
    }
}

struct ListPayload: Codable, Sendable {
    var listID: String
    var name: String?
    var colour: String?
    var ownerPersonID: String?
    var isDefault: Bool?
    enum CodingKeys: String, CodingKey {
        case name, colour
        case listID = "list_id", ownerPersonID = "owner_person_id", isDefault = "default"
    }
}

struct EntryPayload: Codable, Sendable {
    var listID: String
    var itemID: String?
    var note: String?
    var qty: Double?
    var unit: String?
    var forHomeID: String?
    var sort: Double?
    var beforeHLC: String?
    enum CodingKeys: String, CodingKey {
        case note, qty, unit, sort
        case listID = "list_id", itemID = "item_id", forHomeID = "for_home_id", beforeHLC = "before_hlc"
    }
}

struct FlagPayload: Codable, Sendable {
    var homeID: String
    var itemID: String
    var state: String
    var note: String?
    enum CodingKeys: String, CodingKey {
        case state, note
        case homeID = "home_id", itemID = "item_id"
    }
}

struct StaplePayload: Codable, Sendable {
    var homeID: String
    var itemID: String
    var sort: Int64?
    enum CodingKeys: String, CodingKey {
        case sort
        case homeID = "home_id", itemID = "item_id"
    }
}

struct HomePayload: Codable, Sendable {
    var homeID: String
    var name: String?
    enum CodingKeys: String, CodingKey {
        case name
        case homeID = "home_id"
    }
}

struct SpotPayload: Codable, Sendable {
    var spotID: String
    var homeID: String?
    var name: String?
    enum CodingKeys: String, CodingKey {
        case name
        case spotID = "spot_id", homeID = "home_id"
    }
}

struct PhotoPayload: Codable, Sendable {
    var photoID: String
    var spotID: String
    var bytes: Int64?
    var width: Int64?
    var height: Int64?
    enum CodingKeys: String, CodingKey {
        case bytes, width, height
        case photoID = "photo_id", spotID = "spot_id"
    }
}

struct TripPayload: Codable, Sendable {
    var tripID: String
    var fromHomeID: String
    var toHomeID: String
    var moved: [String]
    enum CodingKeys: String, CodingKey {
        case moved
        case tripID = "trip_id", fromHomeID = "from_home_id", toHomeID = "to_home_id"
    }
}

/// The item ids an event names, for the store's indexes: item_id, or a trip's moved list.
struct ItemRefs: Decodable {
    var listID: String?
    var itemID: String?
    var homeID: String?
    var state: String?
    var moved: [String]?
    enum CodingKeys: String, CodingKey {
        case state, moved
        case listID = "list_id", itemID = "item_id", homeID = "home_id"
    }
}

extension Encodable {
    /// The payload as JSON, with nil fields left out.
    var jsonValue: JSONValue {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self), let v = try? JSONValue(data: data) else { return .object([:]) }
        return v
    }
}
