// What a list screen does to the store, as events: the add field's one tap (match a typed line
// to the catalog, or make the item), strike and restore, clear, reorder, the long-press menu,
// and a new list. The screen stays thin; these are tested without it.
import Foundation
import GRDB

enum AddOutcome: Equatable, Sendable {
    /// A new entry, or a struck one restored by the add.
    case added(itemID: String)
    /// The item is open on the list already: the screen flashes that row.
    case alreadyOpen(entryID: String)
    case nothingTyped
}

@MainActor
enum ListActions {
    /// The typed line: a leading or trailing quantity and unit, a note in brackets, the rest
    /// the item. An exact name reuses the item, anything else creates one; adding what is open
    /// already flashes the row; adding what is struck restores it.
    static func add(_ text: String, to listID: String, in session: Session) throws -> AddOutcome {
        guard let scope = session.scope else { return .nothingTyped }
        let parsed = EntryText.parse(text)
        let norm = Norm.name(parsed.name)
        guard !norm.isEmpty else { return .nothingTyped }
        let store = session.store
        let existing = try store.read(scope) { db, s in try Queries.itemID(db, s, norm: norm) }
        if let itemID = existing, let open = try store.read(scope, { db, s in try Queries.openEntry(db, s, listID: listID, itemID: itemID) }), open.checkedHLC == nil {
            return .alreadyOpen(entryID: open.id)
        }
        let itemID = existing ?? ULID.make()
        try session.record { events, clock, person in
            if existing == nil {
                events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.itemNamed, payload: ItemPayload(itemID: itemID, name: parsed.name).jsonValue))
            }
            var p = EntryPayload(listID: listID, itemID: itemID)
            if !parsed.note.isEmpty { p.note = parsed.note }
            if let q = parsed.qty {
                p.qty = q
                p.unit = parsed.unit.isEmpty ? "x" : parsed.unit
            }
            events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.entryAdded, payload: p.jsonValue))
        }
        return .added(itemID: itemID)
    }

    /// Re-adds an item from Recent or a match row, as it was typed once.
    static func add(itemID: String, to listID: String, in session: Session) throws -> AddOutcome {
        guard let scope = session.scope else { return .nothingTyped }
        if let open = try session.store.read(scope, { db, s in try Queries.openEntry(db, s, listID: listID, itemID: itemID) }), open.checkedHLC == nil {
            return .alreadyOpen(entryID: open.id)
        }
        try session.record(Kind.entryAdded, EntryPayload(listID: listID, itemID: itemID))
        return .added(itemID: itemID)
    }

    static func toggle(_ row: EntryRow, on listID: String, in session: Session) throws {
        try session.record(row.isChecked ? Kind.entryUnchecked : Kind.entryChecked, EntryPayload(listID: listID, itemID: row.itemID))
    }

    /// Takes a row off the list as not needed: no purchase record, nothing counted.
    static func remove(_ row: EntryRow, on listID: String, in session: Session) throws {
        try session.record(Kind.entryRemoved, EntryPayload(listID: listID, itemID: row.itemID))
    }

    /// Clears the struck rows: everything checked before now.
    static func clear(_ listID: String, in session: Session) throws {
        guard let clock = session.clock else { return }
        let before = clock.next()
        try session.record(Kind.entryCleared, EntryPayload(listID: listID, beforeHLC: before.description))
    }

    /// A row moved by drag: its sort lands between its new neighbours, which did not move. When
    /// two neighbours share a sort there is no room between them, and every row is renumbered.
    static func move(_ rows: [EntryRow], from source: IndexSet, to destination: Int, on listID: String, in session: Session) throws {
        let before = rows.filter { !$0.isChecked }
        var open = before
        open.move(fromOffsets: source, toOffset: destination)
        let moved = Set(source.map { before[$0].id })
        var sorts = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0.sort) })
        for (i, row) in open.enumerated() where moved.contains(row.id) {
            let prev = open[..<i].last { !moved.contains($0.id) || sorts[$0.id] != $0.sort }.map { sorts[$0.id]! }
            let next = open[(i + 1)...].first { !moved.contains($0.id) }.map { sorts[$0.id]! }
            let sort: Double
            switch (prev, next) {
            case (nil, nil): continue
            case (let p?, nil): sort = p + 1000
            case (nil, let n?): sort = n - 1000
            case (let p?, let n?) where p < n: sort = (p + n) / 2
            default:
                // no room: renumber the whole list in its new order
                for (j, r) in open.enumerated() {
                    let s = Double(j + 1) * 1000
                    if sorts[r.id] != s {
                        sorts[r.id] = s
                        try session.record(Kind.entryMoved, EntryPayload(listID: listID, itemID: r.itemID, sort: s))
                    }
                }
                return
            }
            sorts[row.id] = sort
            try session.record(Kind.entryMoved, EntryPayload(listID: listID, itemID: row.itemID, sort: sort))
        }
    }

    static func setHome(_ row: EntryRow, _ homeID: String?, on listID: String, in session: Session) throws {
        var p = EntryPayload(listID: listID, itemID: row.itemID, note: row.note.isEmpty ? nil : row.note, qty: row.qty, unit: row.unit)
        p.forHomeID = homeID
        try session.record(Kind.entryAdded, p)
    }

    /// Bought: the quantity and unit as the shop had them ("2 kg", "500 g", "3"), on a struck
    /// row. Text that is not a quantity goes into the note, so nothing typed is lost.
    static func edit(_ row: EntryRow, text: String, on listID: String, in session: Session) throws {
        let parsed = EntryText.parse("item " + text.trimmingCharacters(in: .whitespacesAndNewlines))
        var p = EntryPayload(listID: listID, itemID: row.itemID, note: row.note.isEmpty ? nil : row.note)
        if let q = parsed.qty, parsed.name == "item" {
            p.qty = q
            p.unit = parsed.unit.isEmpty ? "x" : parsed.unit
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p.note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try session.record(Kind.entryEdited, p)
    }

    /// Edit, as the row's line would be typed ("melk 2 (the small jar)"): a changed name renames
    /// the item, the quantity, unit and note replace the entry's, and a changed home sets it.
    static func editLine(_ row: EntryRow, text: String, home: String?, on listID: String, in session: Session) throws {
        let parsed = EntryText.parse(text)
        guard !Norm.name(parsed.name).isEmpty else { return }
        if Norm.name(parsed.name) != Norm.name(row.name) {
            try rename(row, to: parsed.name, in: session)
        }
        var p = EntryPayload(listID: listID, itemID: row.itemID, note: parsed.note.isEmpty ? nil : parsed.note)
        if let q = parsed.qty {
            p.qty = q
            p.unit = parsed.unit.isEmpty ? "x" : parsed.unit
        }
        if home != row.forHomeID {
            p.forHomeID = home
            try session.record(Kind.entryAdded, p)
        } else {
            try session.record(Kind.entryEdited, p)
        }
    }

    static func rename(_ row: EntryRow, to name: String, in session: Session) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Norm.name(n).isEmpty else { return }
        try session.record(Kind.itemRenamed, ItemPayload(itemID: row.itemID, name: n))
    }

    static func merge(_ row: EntryRow, into keepID: String, in session: Session) throws {
        guard keepID != row.itemID else { return }
        try session.record(Kind.itemMerged, ItemPayload(keepID: keepID, dropID: row.itemID))
    }

    /// The first list colour no list wears yet, or, with all six taken, the next in turn.
    static func nextColour(_ lists: [ListSummary]) -> String {
        Tokens.listColours.first { c in !lists.contains { $0.colour == c } } ?? Tokens.listColours[lists.count % Tokens.listColours.count]
    }

    /// A new list, shared with the household or just for this person.
    @discardableResult
    static func createList(named name: String, personal: Bool, tasks: Bool = false, colour: String, in session: Session) throws -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let scope = session.scope else { return nil }
        let id = ULID.make()
        try session.record(Kind.listCreated, ListPayload(listID: id, name: n, colour: colour, ownerPersonID: personal ? scope.personID : nil, isDefault: false, kind: tasks ? "tasks" : nil))
        return id
    }

    /// A rename carries the list's colour: name and colour are one last-writer-wins value in
    /// the fold, so a rename without it would blank the colour.
    static func renameList(_ listID: String, to name: String, colour: String, in session: Session) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        try session.record(Kind.listRenamed, ListPayload(listID: listID, name: n, colour: colour))
    }

    static func archiveList(_ listID: String, in session: Session) throws {
        try session.record(Kind.listArchived, ListPayload(listID: listID))
    }

    /// A personal list shared with the family: a household list of the same name and colour
    /// takes what is still open, in order, and the personal one is archived, its history with
    /// it. One write, so the family sees the list whole or not yet; the new list's id comes back
    /// for the screen to follow.
    @discardableResult
    static func shareList(_ l: ListSummary, in session: Session) throws -> String? {
        guard l.isPersonal, let scope = session.scope else { return nil }
        let open = try session.store.read(scope) { db, s in try Queries.entries(db, s, listID: l.id) }
            .filter { !$0.isChecked }
            .sorted { $0.sort < $1.sort }
        let id = ULID.make()
        try session.record { events, clock, person in
            events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.listCreated,
                                payload: ListPayload(listID: id, name: l.name, colour: l.colour, ownerPersonID: nil, isDefault: false).jsonValue))
            for row in open {
                var p = EntryPayload(listID: id, itemID: row.itemID, note: row.note.isEmpty ? nil : row.note, qty: row.qty, unit: row.unit)
                p.forHomeID = row.forHomeID
                events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.entryAdded, payload: p.jsonValue))
            }
            events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.listArchived, payload: ListPayload(listID: l.id).jsonValue))
        }
        return id
    }
}
