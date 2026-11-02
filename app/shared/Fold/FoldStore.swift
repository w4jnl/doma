// FoldStore is the fold's view of one household's tables and log, the port of fold.Store. Get
// methods return nil when there is no row, put methods upsert, event methods return events in
// stamp order. MemStore implements it for the tests; the GRDB store inside a write transaction
// for the app.
import Foundation

protocol FoldStore {
    func item(_ id: String) throws -> Item?
    func items() throws -> [Item]
    func putItem(_ item: Item) throws
    /// Replaces the whole alias table.
    func replaceAliases(_ aliases: [ItemAlias]) throws
    func aliases() throws -> [ItemAlias]
    /// id and every item id merged into it, transitively; id first, the rest sorted.
    func mergedIDs(_ id: String) throws -> [String]
    /// Sets use_count and last_used_at from the entries table.
    func recountItemUsage(_ id: String) throws
    /// Every item.* event.
    func itemEvents() throws -> [Event]
    /// The flag.set, staple.added, staple.removed and trip.arrived events naming one of the ids.
    func itemEvents(for itemIDs: [String]) throws -> [Event]
    /// Whether the log holds an event with this id. Rows whose opening event is not in the log
    /// came from a snapshot and are a base the replays start from.
    func hasEvent(_ id: String) throws -> Bool
    /// Whether the log holds an event with this stamp. A flag or staple whose stamp no event
    /// carries is a snapshot's base; one derived from the log is rebuilt from it.
    func hasEvent(stamp: HLC) throws -> Bool

    func list(_ id: String) throws -> List?
    func putList(_ list: List) throws
    func defaultListID() throws -> String?

    /// Every event a key's replay needs: entry events for the list and any of the item ids
    /// (nil: any item), clears of the list, and, on the default list, out flags and trips that
    /// name one of the ids.
    func entryEvents(listID: String, itemIDs: [String]?, isDefault: Bool) throws -> [Event]
    /// The lists with entry events naming any of the ids, from the log.
    func entryListIDs(itemIDs: [String]) throws -> [String]
    func entries(listID: String, itemIDs: [String]) throws -> [Entry]
    /// Deletes the rows for the list and the item ids and inserts rows.
    func replaceEntries(listID: String, itemIDs: [String], rows: [Entry]) throws
    /// The cleared rows of the item ids that were for the home, on any list.
    func clearedEntries(itemIDs: [String], forHome homeID: String) throws -> [Entry]

    func flag(homeID: String, itemID: String) throws -> Flag?
    func putFlag(_ flag: Flag) throws
    func deleteFlag(homeID: String, itemID: String) throws
    func deleteFlags(forItems itemIDs: [String]) throws
    func flags(forItems itemIDs: [String]) throws -> [Flag]

    func staple(homeID: String, itemID: String) throws -> Staple?
    func putStaple(_ staple: Staple) throws
    func deleteStaples(forItems itemIDs: [String]) throws
    func staples(forItems itemIDs: [String]) throws -> [Staple]

    func home(_ id: String) throws -> Home?
    func putHome(_ home: Home) throws
    func spot(_ id: String) throws -> Spot?
    func putSpot(_ spot: Spot) throws
    func putPhoto(_ photo: Photo) throws
    func putTrip(_ trip: Trip) throws
}

enum FoldError: Error, CustomStringConvertible {
    case badPayload(kind: String, id: String, reason: String)
    case mergeCycle

    var description: String {
        switch self {
        case .badPayload(let kind, let id, let reason): "fold: bad payload: \(kind) \(id): \(reason)"
        case .mergeCycle: "fold: merged_into cycle"
        }
    }
}
