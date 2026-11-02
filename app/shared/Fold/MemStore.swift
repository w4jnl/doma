// MemStore is an in-memory FoldStore for the fixture and property tests (internal/fold/mem.go).
// It keeps the log it was given, as the GRDB store reads its events table.
import Foundation

final class MemStore: FoldStore {
    private(set) var log: [Event] = []
    private var logIDs = Set<String>()
    private var itemRows: [String: Item] = [:]
    private var aliasRows: [String: ItemAlias] = [:] // by norm
    private var listRows: [String: ShoppingList] = [:]
    private var entryRows: [String: Entry] = [:]
    private var flagRows: [Key: Flag] = [:]
    private var stapleRows: [Key: Staple] = [:]
    private var homeRows: [String: Home] = [:]
    private var spotRows: [String: Spot] = [:]
    private var photoRows: [String: Photo] = [:]
    private var tripRows: [String: Trip] = [:]

    struct Key: Hashable { var home: String; var item: String }

    init() {}

    /// A store that starts from a snapshot's tables, with no log behind them.
    init(base: Tables) {
        for r in base.items { itemRows[r.id] = r }
        for r in base.aliases { aliasRows[r.normName] = r }
        for r in base.lists { listRows[r.id] = r }
        for r in base.entries { entryRows[r.id] = r }
        for r in base.flags { flagRows[Key(home: r.homeID, item: r.itemID)] = r }
        for r in base.staples { stapleRows[Key(home: r.homeID, item: r.itemID)] = r }
        for r in base.homes { homeRows[r.id] = r }
        for r in base.spots { spotRows[r.id] = r }
        for r in base.photos { photoRows[r.id] = r }
        for r in base.trips { tripRows[r.id] = r }
    }

    /// Adds e to the log and folds it, skipping an id seen before.
    func append(_ e: Event) throws {
        guard logIDs.insert(e.id).inserted else { return }
        log.append(e)
        try Fold.apply(e, to: self)
    }

    func item(_ id: String) throws -> Item? { itemRows[id] }
    func items() throws -> [Item] { itemRows.values.sorted { $0.id < $1.id } }
    func putItem(_ item: Item) throws { itemRows[item.id] = item }
    func replaceAliases(_ aliases: [ItemAlias]) throws {
        aliasRows = [:]
        for a in aliases { aliasRows[a.normName] = a }
    }
    func aliases() throws -> [ItemAlias] { aliasRows.values.sorted { $0.normName < $1.normName } }

    func mergedIDs(_ id: String) throws -> [String] {
        var out = [id]
        var i = 0
        while i < out.count {
            for it in itemRows.values where it.mergedInto == out[i] && !out.contains(it.id) {
                out.append(it.id)
            }
            i += 1
        }
        return [out[0]] + out.dropFirst().sorted()
    }

    func recountItemUsage(_ id: String) throws {
        guard var it = itemRows[id] else { return }
        var n: Int64 = 0
        var last: Int64?
        for e in entryRows.values where e.itemID == id {
            n += 1
            if last == nil || last! < e.addedHLC.wall { last = e.addedHLC.wall }
        }
        it.useCount = n
        it.lastUsedAt = last
        itemRows[id] = it
    }

    func itemEvents() throws -> [Event] {
        log.filter { $0.kind.hasPrefix("item.") }.sorted { $0.hlc < $1.hlc }
    }

    func itemEvents(for itemIDs: [String]) throws -> [Event] {
        var out: [Event] = []
        for ev in log {
            guard let p = try? ev.decode(ItemRefs.self) else { continue }
            switch ev.kind {
            case Kind.flagSet, Kind.stapleAdded, Kind.stapleRemoved:
                if let id = p.itemID, itemIDs.contains(id) { out.append(ev) }
            case Kind.tripArrived:
                if (p.moved ?? []).contains(where: itemIDs.contains) { out.append(ev) }
            default:
                break
            }
        }
        return out.sorted { $0.hlc < $1.hlc }
    }

    func hasEvent(_ id: String) throws -> Bool { logIDs.contains(id) }
    func hasEvent(stamp: HLC) throws -> Bool { log.contains { $0.hlc == stamp } }

    func list(_ id: String) throws -> ShoppingList? { listRows[id] }
    func putList(_ list: ShoppingList) throws { listRows[list.id] = list }
    func defaultListID() throws -> String? {
        listRows.values.filter(\.isDefault).map(\.id).sorted().first
    }

    func checkedItemIDs(listID: String, before: HLC) throws -> [String] {
        var out: [String] = []
        for ev in log where ev.kind == Kind.entryChecked && ev.hlc < before {
            guard let p = try? ev.decode(ItemRefs.self), p.listID == listID, let id = p.itemID, !out.contains(id) else { continue }
            out.append(id)
        }
        return out
    }

    func entryEvents(listID: String, itemIDs: [String]?, isDefault: Bool) throws -> [Event] {
        var out: [Event] = []
        func match(_ id: String?) -> Bool {
            guard let itemIDs else { return true }
            guard let id else { return false }
            return itemIDs.contains(id)
        }
        for ev in log {
            guard let p = try? ev.decode(ItemRefs.self) else { continue }
            switch ev.kind {
            case Kind.entryAdded, Kind.entryEdited, Kind.entryChecked, Kind.entryUnchecked, Kind.entryMoved:
                if p.listID == listID, match(p.itemID) { out.append(ev) }
            case Kind.entryCleared:
                if p.listID == listID { out.append(ev) }
            case Kind.flagSet:
                if isDefault, p.state == "out", match(p.itemID) { out.append(ev) }
            case Kind.tripArrived:
                if isDefault, (p.moved ?? []).contains(where: match) { out.append(ev) }
            default:
                break
            }
        }
        return out.sorted { $0.hlc < $1.hlc }
    }

    func entryListIDs(itemIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        for ev in log where ev.kind.hasPrefix("entry.") {
            guard let p = try? ev.decode(ItemRefs.self), let id = p.itemID, itemIDs.contains(id), let l = p.listID else { continue }
            seen.insert(l)
        }
        return seen.sorted()
    }

    func entries(listID: String, itemIDs: [String]) throws -> [Entry] {
        entryRows.values.filter { $0.listID == listID && (itemIDs.isEmpty || itemIDs.contains($0.itemID)) }.sorted { $0.id < $1.id }
    }

    func clearedEntries(itemIDs: [String], forHome homeID: String) throws -> [Entry] {
        entryRows.values.filter { $0.clearedHLC != nil && $0.forHomeID == homeID && itemIDs.contains($0.itemID) }.sorted { $0.id < $1.id }
    }

    func replaceEntries(listID: String, itemIDs: [String], rows: [Entry]) throws {
        for (id, e) in entryRows where e.listID == listID && itemIDs.contains(e.itemID) {
            entryRows[id] = nil
        }
        for r in rows { entryRows[r.id] = r }
    }

    func flag(homeID: String, itemID: String) throws -> Flag? { flagRows[Key(home: homeID, item: itemID)] }
    func putFlag(_ flag: Flag) throws { flagRows[Key(home: flag.homeID, item: flag.itemID)] = flag }
    func deleteFlag(homeID: String, itemID: String) throws { flagRows[Key(home: homeID, item: itemID)] = nil }
    func deleteFlags(forItems itemIDs: [String]) throws {
        for (k, f) in flagRows where itemIDs.contains(f.itemID) { flagRows[k] = nil }
    }
    func flags(forItems itemIDs: [String]) throws -> [Flag] {
        flagRows.values.filter { itemIDs.contains($0.itemID) }.sorted { ($0.homeID, $0.itemID) < ($1.homeID, $1.itemID) }
    }

    func staple(homeID: String, itemID: String) throws -> Staple? { stapleRows[Key(home: homeID, item: itemID)] }
    func putStaple(_ staple: Staple) throws { stapleRows[Key(home: staple.homeID, item: staple.itemID)] = staple }
    func deleteStaples(forItems itemIDs: [String]) throws {
        for (k, s) in stapleRows where itemIDs.contains(s.itemID) { stapleRows[k] = nil }
    }
    func staples(forItems itemIDs: [String]) throws -> [Staple] {
        stapleRows.values.filter { itemIDs.contains($0.itemID) }.sorted { ($0.homeID, $0.itemID) < ($1.homeID, $1.itemID) }
    }

    func home(_ id: String) throws -> Home? { homeRows[id] }
    func putHome(_ home: Home) throws { homeRows[home.id] = home }
    func spot(_ id: String) throws -> Spot? { spotRows[id] }
    func putSpot(_ spot: Spot) throws { spotRows[spot.id] = spot }
    func putPhoto(_ photo: Photo) throws {
        if photoRows[photo.id] == nil { photoRows[photo.id] = photo }
    }
    func putTrip(_ trip: Trip) throws {
        if tripRows[trip.id] == nil { tripRows[trip.id] = trip }
    }

    /// Every materialised table, sorted.
    var tables: Tables {
        var t = Tables(items: Array(itemRows.values), aliases: Array(aliasRows.values), lists: Array(listRows.values),
                       entries: Array(entryRows.values), flags: Array(flagRows.values), staples: Array(stapleRows.values),
                       homes: Array(homeRows.values), spots: Array(spotRows.values), photos: Array(photoRows.values), trips: Array(tripRows.values))
        t.sort()
        return t
    }
}
