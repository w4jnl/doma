// Lists, homes and spots: create is add-wins and carries what never changes, name and colour
// are last-writer-wins on the stamp, an archive sticks (internal/fold/lists.go).
import Foundation

enum Lists {
    static func applyList(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(ListPayload.self)
        try Fold.need(e, "list_id", p.listID)
        var l = try s.list(p.listID) ?? ShoppingList(id: p.listID)
        switch e.kind {
        case Kind.listCreated, Kind.listRenamed:
            if e.kind == Kind.listCreated {
                try Fold.need(e, "name", p.name)
                if l.ownerPersonID == nil { l.ownerPersonID = p.ownerPersonID }
                l.isDefault = l.isDefault || (p.isDefault ?? false)
                if l.kind.isEmpty, p.kind == "tasks" { l.kind = "tasks" }
            }
            if l.updatedHLC == nil || l.updatedHLC! < e.hlc {
                if let name = p.name, !name.isEmpty { l.name = name }
                l.colour = p.colour ?? ""
                l.updatedHLC = e.hlc
            }
        case Kind.listArchived:
            if l.archivedAt == nil || e.hlc.wall < l.archivedAt! {
                l.archivedAt = e.hlc.wall
            }
        default:
            break
        }
        try s.putList(l)
        if e.kind == Kind.listCreated, l.isDefault {
            // out flags and trips that arrived before the default list existed now add their
            // items to it
            for item in try Entries.listItemIDs(s, listID: l.id, isDefault: true) {
                try Entries.replay(s, listID: l.id, itemID: item)
            }
        }
    }

    static func applyHome(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(HomePayload.self)
        try Fold.need(e, "home_id", p.homeID)
        var h = try s.home(p.homeID) ?? Home(id: p.homeID)
        switch e.kind {
        case Kind.homeCreated, Kind.homeRenamed:
            try Fold.need(e, "name", p.name)
            if h.updatedHLC == nil || h.updatedHLC! < e.hlc {
                h.name = p.name!
                h.updatedHLC = e.hlc
            }
        case Kind.homeArchived:
            if h.archivedAt == nil || e.hlc.wall < h.archivedAt! {
                h.archivedAt = e.hlc.wall
            }
        default:
            break
        }
        try s.putHome(h)
    }

    static func applySpot(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(SpotPayload.self)
        try Fold.need(e, "spot_id", p.spotID)
        var sp = try s.spot(p.spotID) ?? Spot(id: p.spotID)
        if let home = p.homeID, !home.isEmpty { sp.homeID = home }
        switch e.kind {
        case Kind.spotCreated, Kind.spotRenamed:
            try Fold.need(e, "name", p.name)
            if e.kind == Kind.spotCreated {
                try Fold.need(e, "home_id", p.homeID)
            }
            if sp.updatedHLC == nil || sp.updatedHLC! < e.hlc {
                sp.name = p.name!
                sp.updatedHLC = e.hlc
            }
        case Kind.spotArchived:
            if sp.archivedAt == nil || e.hlc.wall < sp.archivedAt! {
                sp.archivedAt = e.hlc.wall
            }
        default:
            break
        }
        try s.putSpot(sp)
    }
}
