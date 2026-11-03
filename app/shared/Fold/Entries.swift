// Entries, the one structure with eras (open, checked, cleared, re-added), derived per
// (list, item) by replaying that key's events in stamp order (internal/fold/entries.go).
import Foundation

enum Entries {
    /// Replays the (list, item) key the event belongs to.
    static func applyEntryEvent(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(EntryPayload.self)
        try Fold.need(e, "list_id", p.listID)
        try Fold.need(e, "item_id", p.itemID)
        let item = try Fold.resolveItem(s, p.itemID!)
        try replay(s, listID: p.listID, itemID: item)
    }

    /// Replays the keys of the list the clear can close: those with an entry.checked stamped
    /// before it, and base rows that stand checked without their events. The server replays
    /// every key of the list; the result is the same, since a clear only closes an era that is
    /// checked at its point in the stamp order, and a checked event that arrives later replays
    /// its own key with the clear in the log.
    static func applyEntryCleared(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(EntryPayload.self)
        try Fold.need(e, "list_id", p.listID)
        guard let b = p.beforeHLC, HLC(parsing: b) != nil else {
            throw FoldError.badPayload(kind: e.kind, id: e.id, reason: "before_hlc is empty")
        }
        var seen = Set<String>()
        var items: [String] = []
        func add(_ raw: String) throws {
            let id = try Fold.resolveItem(s, raw)
            if seen.insert(id).inserted { items.append(id) }
        }
        for raw in try s.checkedItemIDs(listID: p.listID, before: e.hlc) {
            try add(raw)
        }
        for row in try s.entries(listID: p.listID, itemIDs: []) where row.isChecked {
            if try !s.hasEvent(openingEventID(of: row)) {
                try add(row.itemID)
            }
        }
        for item in items {
            try replay(s, listID: p.listID, itemID: item)
        }
    }

    /// The canonical item ids with events on a list, from the events the store returns for the
    /// list with no item filter; with isDefault, the items of out flags and trips as well. A
    /// key whose rows are a base (no events) counts too, so a clear can take a base entry.
    static func listItemIDs(_ s: some FoldStore, listID: String, isDefault: Bool) throws -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ raw: String?) throws {
            guard let raw, !raw.isEmpty else { return }
            let id = try Fold.resolveItem(s, raw)
            if seen.insert(id).inserted { out.append(id) }
        }
        for ev in try s.entryEvents(listID: listID, itemIDs: nil, isDefault: isDefault) {
            guard let p = try? ev.decode(ItemRefs.self) else { continue }
            try add(p.itemID)
            for id in p.moved ?? [] { try add(id) }
        }
        for row in try s.entries(listID: listID, itemIDs: []) where row.isChecked {
            if try !s.hasEvent(openingEventID(of: row)) {
                try add(row.itemID)
            }
        }
        return out
    }

    /// Derives the rows of one (list, item) key from the key's events in stamp order. An era
    /// opens with an add (or an out flag or a trip on the default list), may be checked and
    /// unchecked, and closes when a clear sees it checked; a cleared era is a purchase record
    /// and the next add opens a new one. Rows whose opening event the log does not hold are a
    /// base the replay starts from.
    static func replay(_ s: some FoldStore, listID: String, itemID: String) throws {
        let l = try s.list(listID)
        let isDefault = l?.isDefault ?? false
        let ids = try s.mergedIDs(itemID)
        var events = try s.entryEvents(listID: listID, itemIDs: ids, isDefault: isDefault)
        events.sort { $0.hlc < $1.hlc }
        // the homes whose flags the old and the new rows can reach
        var homes = Set<String>()
        let before = try s.entries(listID: listID, itemIDs: ids)
        for e in before {
            if let h = e.forHomeID { homes.insert(h) }
        }

        var eras: [Entry] = []
        var cur: Int? // index into eras
        // rows whose opening event the log does not hold are a snapshot's base: replayed as the
        // events that made them, at their own stamps, among the log's events
        var seed: [Event] = []
        for row in before {
            guard try !s.hasEvent(openingEventID(of: row)) else { continue }
            var add = EntryPayload(listID: listID, itemID: itemID, note: row.note, qty: row.qty, unit: row.unit, forHomeID: row.forHomeID)
            if add.note == "" { add.note = nil }
            seed.append(Event(id: row.id, personID: row.addedBy, hlc: row.addedHLC, kind: Kind.entryAdded, payload: add.jsonValue))
            if row.sort != Double(row.addedHLC.wall) {
                seed.append(Event(id: "base:moved:" + row.id, personID: row.addedBy, hlc: row.addedHLC, kind: Kind.entryMoved, payload: EntryPayload(listID: listID, itemID: itemID, sort: row.sort).jsonValue))
            }
            if let checked = row.checkedHLC {
                seed.append(Event(id: "base:checked:" + row.id, personID: row.checkedBy ?? row.addedBy, hlc: checked, kind: Kind.entryChecked, payload: EntryPayload(listID: listID, itemID: itemID).jsonValue))
                if let cleared = row.clearedHLC {
                    var before = checked
                    if before.counter < HLC.maxCounter { before.counter += 1 } else { before.wall += 1; before.counter = 0 }
                    seed.append(Event(id: "base:cleared:" + row.id, personID: row.checkedBy ?? row.addedBy, hlc: cleared, kind: Kind.entryCleared, payload: EntryPayload(listID: listID, beforeHLC: before.description).jsonValue))
                }
            }
        }
        if !seed.isEmpty {
            events = (seed + events).enumerated().sorted { a, b in
                a.element.hlc != b.element.hlc ? a.element.hlc < b.element.hlc : a.offset < b.offset
            }.map(\.element)
        }
        // an era's id is the id of the event that opened it; a trip opens one era per moved
        // item, so those carry the item id as well
        func open(_ id: String, _ ev: Event, _ forHome: String?) {
            eras.append(Entry(id: id, listID: listID, itemID: itemID, forHomeID: forHome, sort: Double(ev.hlc.wall), addedHLC: ev.hlc, addedBy: ev.personID))
            cur = eras.count - 1
        }
        for ev in events {
            switch ev.kind {
            case Kind.entryAdded:
                let p = try ev.decode(EntryPayload.self)
                if cur == nil {
                    open(ev.id, ev, nil)
                } else if eras[cur!].checkedHLC != nil {
                    eras[cur!].checkedHLC = nil
                    eras[cur!].checkedBy = nil
                }
                eras[cur!].note = p.note ?? ""
                eras[cur!].qty = p.qty
                eras[cur!].unit = p.unit
                if let h = p.forHomeID { eras[cur!].forHomeID = h }
            case Kind.entryEdited:
                guard let i = cur else { continue }
                let p = try ev.decode(EntryPayload.self)
                eras[i].note = p.note ?? ""
                eras[i].qty = p.qty
                eras[i].unit = p.unit
            case Kind.entryChecked:
                if let i = cur, eras[i].checkedHLC == nil {
                    eras[i].checkedHLC = ev.hlc
                    eras[i].checkedBy = ev.personID
                }
            case Kind.entryUnchecked:
                if let i = cur {
                    eras[i].checkedHLC = nil
                    eras[i].checkedBy = nil
                }
            case Kind.entryMoved:
                guard let i = cur else { continue }
                let p = try ev.decode(EntryPayload.self)
                if let sort = p.sort { eras[i].sort = sort }
            case Kind.entryCleared:
                guard let i = cur, let checked = eras[i].checkedHLC else { continue }
                let p = try ev.decode(EntryPayload.self)
                guard let b = p.beforeHLC, let before = HLC(parsing: b) else { continue }
                if checked < before {
                    eras[i].clearedHLC = ev.hlc
                    cur = nil
                }
            case Kind.flagSet:
                guard isDefault, cur == nil else { continue }
                let p = try ev.decode(FlagPayload.self)
                if p.state == "out" {
                    open(ev.id, ev, p.homeID)
                }
            case Kind.tripArrived:
                guard isDefault, cur == nil else { continue }
                let p = try ev.decode(TripPayload.self)
                open(ev.id + ":" + itemID, ev, p.fromHomeID)
            default:
                break
            }
        }
        try s.replaceEntries(listID: listID, itemIDs: ids, rows: eras)
        for id in ids {
            try s.recountItemUsage(id)
        }
        // clearing an entry that was for a home means it is there now: the flags of the homes
        // involved are derived again from everything
        for era in eras {
            if let h = era.forHomeID { homes.insert(h) }
        }
        for h in homes.sorted() {
            try Flags.recompute(s, homeID: h, itemID: itemID)
        }
    }

    /// The event that opened an era: its id, or the event id of a trip's era "event:item".
    static func openingEventID(of row: Entry) -> String {
        if let colon = row.id.lastIndex(of: ":"), row.id[row.id.index(after: colon)...] == row.itemID {
            return String(row.id[..<colon])
        }
        return row.id
    }

    static func cleanedBy(_ e: Entry) -> String { e.checkedBy ?? e.addedBy }
}
