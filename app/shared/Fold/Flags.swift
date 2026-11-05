// Flags, staples, photos and trips (internal/fold/flags.go).
import Foundation

enum Flags {
    /// Last-writer-wins on the stamp. An out flag also adds the item to the default list,
    /// through that list's replay.
    static func applyFlagSet(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(FlagPayload.self)
        try Fold.need(e, "home_id", p.homeID)
        try Fold.need(e, "item_id", p.itemID)
        guard Fold.flagStates.contains(p.state) else {
            throw FoldError.badPayload(kind: e.kind, id: e.id, reason: "state \(p.state)")
        }
        let item = try Fold.resolveItem(s, p.itemID)
        try putLWW(s, Flag(homeID: p.homeID, itemID: item, state: p.state, setHLC: e.hlc, setBy: e.personID, note: p.note ?? ""))
        guard p.state == "out", let def = try s.defaultListID() else { return }
        try Entries.replay(s, listID: def, itemID: item)
    }

    /// Derives the flag of one (home, item) from every write that can reach it: flag.set
    /// events, trips through the home, clears of entries for the home, and a base row (a
    /// snapshot's, whose stamp no event in the log carries); the latest stamp wins.
    static func recompute(_ s: some FoldStore, homeID: String, itemID: String, base: [Flag] = []) throws {
        let ids = try s.mergedIDs(itemID)
        var best: Flag?
        func consider(_ f: Flag) {
            if best == nil || best!.setHLC < f.setHLC { best = f }
        }
        for ev in try s.itemEvents(for: ids) {
            switch ev.kind {
            case Kind.flagSet:
                let p = try ev.decode(FlagPayload.self)
                if p.homeID == homeID, Fold.flagStates.contains(p.state) {
                    consider(Flag(homeID: homeID, itemID: itemID, state: p.state, setHLC: ev.hlc, setBy: ev.personID, note: p.note ?? ""))
                }
            case Kind.tripArrived:
                let p = try ev.decode(TripPayload.self)
                if p.fromHomeID == homeID {
                    consider(Flag(homeID: homeID, itemID: itemID, state: "out", setHLC: ev.hlc, setBy: ev.personID))
                }
                if p.toHomeID == homeID {
                    consider(Flag(homeID: homeID, itemID: itemID, state: "have", setHLC: ev.hlc, setBy: ev.personID))
                }
            default:
                break
            }
        }
        for e in try s.clearedEntries(itemIDs: ids, forHome: homeID) {
            consider(Flag(homeID: homeID, itemID: itemID, state: "have", setHLC: e.clearedHLC!, setBy: Entries.cleanedBy(e)))
        }
        for var b in base where b.homeID == homeID {
            b.itemID = itemID
            consider(b)
        }
        if var standing = try s.flag(homeID: homeID, itemID: itemID), try !s.hasEvent(stamp: standing.setHLC) {
            standing.itemID = itemID
            consider(standing)
        }
        guard let best else {
            try s.deleteFlag(homeID: homeID, itemID: itemID)
            return
        }
        try s.putFlag(best)
    }

    /// Writes f unless the stored flag is newer.
    static func putLWW(_ s: some FoldStore, _ f: Flag) throws {
        if let cur = try s.flag(homeID: f.homeID, itemID: f.itemID), !(cur.setHLC < f.setHLC) {
            return
        }
        try s.putFlag(f)
    }

    /// Keeps the latest add and the latest remove; the staple is present when the add is newer.
    static func applyStaple(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(StaplePayload.self)
        try Fold.need(e, "home_id", p.homeID)
        try Fold.need(e, "item_id", p.itemID)
        let item = try Fold.resolveItem(s, p.itemID)
        try putStaple(s, e, p, item: item)
    }

    static func putStaple(_ s: some FoldStore, _ e: Event, _ p: StaplePayload, item: String) throws {
        var cur = try s.staple(homeID: p.homeID, itemID: item) ?? Staple(homeID: p.homeID, itemID: item)
        switch e.kind {
        case Kind.stapleAdded:
            if cur.addedHLC == nil || cur.addedHLC! < e.hlc {
                cur.addedHLC = e.hlc
                if let sort = p.sort { cur.sort = sort }
            }
        case Kind.stapleRemoved:
            if cur.removedHLC == nil || cur.removedHLC! < e.hlc {
                cur.removedHLC = e.hlc
            }
        default:
            break
        }
        try s.putStaple(cur)
    }

    /// Appends; the newest stamp per spot is the current photo, computed at read time.
    static func applyPhotoAdded(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(PhotoPayload.self)
        try Fold.need(e, "photo_id", p.photoID)
        try Fold.need(e, "spot_id", p.spotID)
        try s.putPhoto(Photo(id: p.photoID, spotID: p.spotID, takenHLC: e.hlc, takenBy: e.personID, bytes: p.bytes ?? 0, width: p.width ?? 0, height: p.height ?? 0))
    }

    /// Records the trip and moves every item: out at the from-home, have at the to-home, with
    /// the trip's stamp. The out flags add the items to the default list through its replay.
    /// Keeps the latest plan: from, to, date, the list it shops on and who planned it are
    /// last-writer-wins on the stamp; an arrival or a cancel that came first stays on the row.
    static func applyTripPlanned(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(TripPlanPayload.self)
        try Fold.need(e, "trip_id", p.tripID)
        try Fold.need(e, "from_home_id", p.fromHomeID)
        try Fold.need(e, "to_home_id", p.toHomeID)
        var cur = try s.trip(p.tripID) ?? Trip(id: p.tripID)
        if cur.updatedHLC == nil || cur.updatedHLC! < e.hlc {
            cur.fromHomeID = p.fromHomeID!
            cur.toHomeID = p.toHomeID!
            cur.date = p.date ?? 0
            cur.createdBy = e.personID
            cur.listID = (p.listID?.isEmpty ?? true) ? nil : p.listID
            cur.updatedHLC = e.hlc
        }
        try s.putTrip(cur)
    }

    /// Marks the trip cancelled at the earliest cancel; a cancel that lands before its plan
    /// makes the row the plan then fills.
    static func applyTripCancelled(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(TripPlanPayload.self)
        try Fold.need(e, "trip_id", p.tripID)
        var cur = try s.trip(p.tripID) ?? Trip(id: p.tripID)
        if cur.cancelledAt == nil || e.hlc.wall < cur.cancelledAt! {
            cur.cancelledAt = e.hlc.wall
        }
        try s.putTrip(cur)
    }

    static func applyTripArrived(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(TripPayload.self)
        try Fold.need(e, "trip_id", p.tripID)
        try Fold.need(e, "from_home_id", p.fromHomeID)
        try Fold.need(e, "to_home_id", p.toHomeID)
        var cur = try s.trip(p.tripID) ?? Trip(id: p.tripID)
        let first = cur.arrivedAt == nil || e.hlc.wall < cur.arrivedAt!
        if cur.updatedHLC == nil, first {
            // no plan: the earliest arrival names the homes and the date
            cur.fromHomeID = p.fromHomeID
            cur.toHomeID = p.toHomeID
            cur.date = e.hlc.wall
            cur.createdBy = e.personID
        }
        if first { cur.arrivedAt = e.hlc.wall }
        try s.putTrip(cur)
        let def = try s.defaultListID()
        for raw in p.moved {
            let item = try Fold.resolveItem(s, raw)
            try putLWW(s, Flag(homeID: p.fromHomeID, itemID: item, state: "out", setHLC: e.hlc, setBy: e.personID))
            try putLWW(s, Flag(homeID: p.toHomeID, itemID: item, state: "have", setHLC: e.hlc, setBy: e.personID))
            if let def {
                try Entries.replay(s, listID: def, itemID: item)
            }
        }
    }
}
