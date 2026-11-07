// The catalog: items, which ids are one item, and aliases, derived by replaying every item
// event in stamp order with the sequential rules of the design document (internal/fold/items.go).
import Foundation

enum Catalog {
    /// One item while the catalog is replayed.
    final class CatItem {
        var id: String
        var name: String
        var norm: String
        var mergedInto: String
        var created: HLC
        var updated: HLC
        init(id: String, name: String, norm: String, mergedInto: String, created: HLC, updated: HLC) {
            self.id = id
            self.name = name
            self.norm = norm
            self.mergedInto = mergedInto
            self.created = created
            self.updated = updated
        }
    }

    final class State {
        var items: [String: CatItem] = [:]
        var aliases: [String: String] = [:] // norm -> owner id

        func resolve(_ id: String) -> String {
            var id = id
            for _ in 0..<64 {
                guard let it = items[id], !it.mergedInto.isEmpty else { return id }
                id = it.mergedInto
            }
            return id
        }

        /// The item that owns norm, by name or alias, or nil.
        func owner(of norm: String) -> String? {
            // at most one unmerged item carries a norm, so the walk order does not matter
            for (_, it) in items where it.mergedInto.isEmpty && it.norm == norm {
                return it.id
            }
            if let id = aliases[norm] { return resolve(id) }
            return nil
        }

        func named(_ id: String, _ name: String, _ h: HLC) {
            if items[id] != nil {
                renamed(id, name, h)
                return
            }
            let norm = Norm.name(name)
            let it = CatItem(id: id, name: name, norm: "", mergedInto: "", created: h, updated: h)
            if let owner = owner(of: norm) {
                // two phones typed the same thing: one item, the newcomer an alias id
                it.mergedInto = owner
            } else {
                it.norm = norm
            }
            items[id] = it
        }

        func renamed(_ id: String, _ name: String, _ h: HLC) {
            let owner = resolve(id)
            guard let it = items[owner] else {
                named(id, name, h)
                return
            }
            let norm = Norm.name(name)
            if let other = self.owner(of: norm), other != owner {
                // renamed into a name another item has: they are one item now; the old name
                // is not kept as an alias, only an explicit merge does that
                if let raw = items[id] {
                    raw.name = name
                    raw.updated = h
                }
                mergeInto(keep: other, drop: owner, alias: false)
                return
            }
            if let a = aliases[norm], a == owner || resolve(a) == owner {
                aliases[norm] = nil
            }
            it.name = name
            it.norm = norm
            it.updated = h
        }

        func merged(keep: String, drop: String) {
            let k = resolve(keep), d = resolve(drop)
            guard k != d, items[k] != nil, items[d] != nil else { return }
            mergeInto(keep: k, drop: d, alias: true)
        }

        /// Makes drop part of keep: drop's name becomes an alias of keep when alias is set,
        /// drop's aliases move to keep, items merged into drop now point at keep.
        func mergeInto(keep: String, drop: String, alias: Bool) {
            guard let d = items[drop], let k = items[keep] else { return }
            if alias, !d.norm.isEmpty, k.norm != d.norm {
                aliases[d.norm] = keep
            }
            for (norm, id) in aliases where id == drop {
                aliases[norm] = keep
            }
            d.norm = ""
            d.mergedInto = keep
            for (_, it) in items where it.mergedInto == drop {
                it.mergedInto = keep
            }
        }
    }

    /// Derives items and aliases from every item event, writes the rows that changed, and
    /// re-derives the flags, staples and entries of every item whose owner changed.
    static func replay(_ s: some FoldStore) throws {
        var events = try s.itemEvents()
        events.sort { $0.hlc < $1.hlc }
        let old = try s.items()
        var oldRows: [String: Item] = [:]
        for it in old { oldRows[it.id] = it }

        let c = State()
        // base: items the log does not know (a snapshot's), replayed as the events that made
        // them, at their own stamps, among the log's events
        var logged = Set<String>()
        for ev in events {
            let p = try ev.decode(ItemPayload.self)
            for id in [p.itemID, p.keepID, p.dropID] {
                if let id { logged.insert(id) }
            }
        }
        let base = old.filter { !logged.contains($0.id) }
        let baseIDs = Set(base.map(\.id))
        var pseudo = Set<String>()
        if !base.isEmpty {
            func oldOwnerOf(_ id: String) -> String {
                var id = id
                for _ in 0..<64 {
                    guard let it = oldRows[id], let into = it.mergedInto else { return id }
                    id = into
                }
                return id
            }
            var seed: [Event] = []
            func named(_ id: String, _ name: String, _ h: HLC) {
                seed.append(Event(id: "base:" + id, personID: "", hlc: h, kind: Kind.itemNamed, payload: ItemPayload(itemID: id, name: name).jsonValue))
            }
            func merged(_ keep: String, _ drop: String, _ h: HLC) {
                seed.append(Event(id: "base:" + keep + ":" + drop, personID: "", hlc: h, kind: Kind.itemMerged, payload: ItemPayload(keepID: keep, dropID: drop).jsonValue))
            }
            for it in base where it.mergedInto == nil {
                named(it.id, it.name, it.createdHLC)
            }
            for it in base where it.mergedInto != nil {
                let owner = oldOwnerOf(it.id)
                let h = max(it.createdHLC, oldRows[owner]?.createdHLC ?? it.createdHLC)
                named(it.id, it.name, h)
                merged(owner, it.id, h)
            }
            for a in try s.aliases() where baseIDs.contains(a.itemID) {
                let id = "alias:" + a.normName
                pseudo.insert(id)
                let h = oldRows[a.itemID]?.createdHLC ?? HLC(wall: 0, device: "-")
                named(id, a.normName, h)
                merged(a.itemID, id, h)
            }
            // stable: a base event before a log event with the same stamp
            events = (seed + events).enumerated().sorted { a, b in
                a.element.hlc != b.element.hlc ? a.element.hlc < b.element.hlc : a.offset < b.offset
            }.map(\.element)
        }
        var touched = Set<String>()

        for ev in events {
            let p = try ev.decode(ItemPayload.self)
            if !ev.id.hasPrefix("base:") {
                for id in [p.itemID, p.keepID, p.dropID] {
                    if let id { touched.insert(id) }
                }
            }
            switch ev.kind {
            case Kind.itemNamed:
                guard let id = p.itemID, !id.isEmpty, let name = p.name, !Norm.name(name).isEmpty else {
                    throw FoldError.badPayload(kind: ev.kind, id: ev.id, reason: "item_id and name is empty")
                }
                c.named(id, name, ev.hlc)
            case Kind.itemRenamed:
                guard let id = p.itemID, !id.isEmpty, let name = p.name, !Norm.name(name).isEmpty else {
                    throw FoldError.badPayload(kind: ev.kind, id: ev.id, reason: "item_id and name is empty")
                }
                c.renamed(id, name, ev.hlc)
            case Kind.itemMerged:
                guard let keep = p.keepID, !keep.isEmpty, let drop = p.dropID, !drop.isEmpty else {
                    throw FoldError.badPayload(kind: ev.kind, id: ev.id, reason: "keep_id and drop_id is empty")
                }
                c.merged(keep: keep, drop: drop)
            default:
                break
            }
        }

        // a base row's stamps are the server's facts: kept, unless a log event moved it on
        for id in baseIDs {
            guard let it = c.items[id], let row = oldRows[id] else { continue }
            it.created = row.createdHLC
            if touched.contains(id) {
                it.updated = max(it.updated, row.updatedHLC)
            } else {
                it.updated = row.updatedHLC
            }
        }
        func oldOwner(_ id: String) -> String {
            var id = id
            for _ in 0..<64 {
                guard let it = oldRows[id], let into = it.mergedInto else { return id }
                id = into
            }
            return id
        }
        // write the rows, keeping what item events do not decide; rows that give up a name go
        // first, so a unique index on norm_name never sees two owners while a name changes hands
        var changed = Set<String>()
        var later: [Item] = []
        for id in c.items.keys.sorted() where !pseudo.contains(id) {
            let ci = c.items[id]!
            var row = Item(id: ci.id, name: ci.name, createdHLC: ci.created, updatedHLC: ci.updated)
            if !ci.norm.isEmpty { row.normName = ci.norm }
            if !ci.mergedInto.isEmpty { row.mergedInto = ci.mergedInto }
            let prev = oldRows[ci.id]
            if let prev {
                row.category = prev.category
                row.lastUsedAt = prev.lastUsedAt
                row.useCount = prev.useCount
                row.archivedAt = prev.archivedAt
            }
            if prev == nil || oldOwner(ci.id) != c.resolve(ci.id) {
                changed.insert(c.resolve(ci.id))
                changed.insert(oldOwner(ci.id))
            }
            if let prev, sameItem(prev, row) { continue }
            if let prev, prev.normName != nil, prev.normName != row.normName {
                try s.putItem(row)
                continue
            }
            later.append(row)
        }
        for row in later {
            try s.putItem(row)
        }
        let aliases = c.aliases.map { ItemAlias(itemID: c.resolve($0.value), normName: $0.key) }.filter { !pseudo.contains($0.itemID) }.sorted { $0.normName < $1.normName }
        try s.replaceAliases(aliases)
        let owners = changed.sorted().filter { c.resolve($0) == $0 && !pseudo.contains($0) }
        for id in owners {
            try rederiveItem(s, id)
        }
        // an entry that changed hands between two of these items was counted for the one
        // re-derived first while it still held it; count again now that every row is where it
        // belongs
        for id in owners {
            try s.recountItemUsage(id)
        }
    }

    private static func sameItem(_ a: Item, _ b: Item) -> Bool {
        a.name == b.name && a.normName == b.normName && a.mergedInto == b.mergedInto && a.createdHLC == b.createdHLC && a.updatedHLC == b.updatedHLC
    }

    /// Rebuilds, from the log, everything stored under an item and the ids merged into it:
    /// staples from their events, the entries of every list that names the item, and the flags
    /// of every home those touch.
    static func rederiveItem(_ s: some FoldStore, _ itemID: String) throws {
        let ids = try s.mergedIDs(itemID)
        // a snapshot's base rows (stamps no event carries) survive the rebuild
        var baseFlags: [Flag] = []
        for f in try s.flags(forItems: ids) where try !s.hasEvent(stamp: f.setHLC) {
            baseFlags.append(f)
        }
        var baseStaples: [Staple] = []
        for st in try s.staples(forItems: ids) {
            let logged = try (st.addedHLC.map { try s.hasEvent(stamp: $0) } ?? false) || (st.removedHLC.map { try s.hasEvent(stamp: $0) } ?? false)
            if !logged { baseStaples.append(st) }
        }
        try s.deleteFlags(forItems: ids)
        try s.deleteStaples(forItems: ids)
        for var st in baseStaples {
            st.itemID = itemID
            var cur = try s.staple(homeID: st.homeID, itemID: itemID) ?? Staple(homeID: st.homeID, itemID: itemID)
            if let a = st.addedHLC, cur.addedHLC == nil || cur.addedHLC! < a {
                cur.addedHLC = a
                cur.sort = st.sort
            }
            if let r = st.removedHLC, cur.removedHLC == nil || cur.removedHLC! < r {
                cur.removedHLC = r
            }
            try s.putStaple(cur)
        }
        let events = try s.itemEvents(for: ids)
        var homes = Set(baseFlags.map(\.homeID))
        for ev in events {
            switch ev.kind {
            case Kind.flagSet:
                let p = try ev.decode(FlagPayload.self)
                homes.insert(p.homeID)
            case Kind.flagProposed, Kind.proposalDeclined:
                let p = try ev.decode(ProposalPayload.self)
                homes.insert(p.homeID)
            case Kind.stapleAdded, Kind.stapleRemoved:
                let p = try ev.decode(StaplePayload.self)
                try Flags.putStaple(s, ev, p, item: itemID)
            case Kind.tripArrived:
                let p = try ev.decode(TripPayload.self)
                homes.insert(p.fromHomeID)
                homes.insert(p.toHomeID)
            default:
                break
            }
        }
        var lists = try s.entryListIDs(itemIDs: ids)
        if let def = try s.defaultListID() {
            lists.append(def)
        }
        var seen = Set<String>()
        for l in lists where seen.insert(l).inserted {
            try Entries.replay(s, listID: l, itemID: itemID)
        }
        for h in homes.sorted() {
            try Flags.recompute(s, homeID: h, itemID: itemID, base: baseFlags)
        }
        for id in ids {
            try s.recountItemUsage(id)
        }
    }
}
