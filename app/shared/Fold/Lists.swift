// Lists, homes, spots and cards: create is add-wins and carries what never changes, name and
// colour are last-writer-wins on the stamp, an archive sticks (internal/fold/lists.go and
// cards.go).
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

    /// card.added fixes the owner; name, colour, format, value and domain are last-writer-wins
    /// between the add and the edits; an archive sticks; card.logo, the server's, is
    /// last-writer-wins among logos on its own stamp.
    static func applyCard(_ s: some FoldStore, _ e: Event) throws {
        let p = try e.decode(CardPayload.self)
        try Fold.need(e, "card_id", p.cardID)
        var c = try s.card(p.cardID) ?? Card(id: p.cardID)
        switch e.kind {
        case Kind.cardAdded, Kind.cardEdited:
            try Fold.need(e, "name", p.name)
            try Fold.need(e, "value", p.value)
            guard let format = p.format, Card.formats.contains(format) else {
                throw FoldError.badPayload(kind: e.kind, id: e.id, reason: "format is empty")
            }
            if e.kind == Kind.cardAdded, c.ownerPersonID == nil { c.ownerPersonID = p.ownerPersonID }
            if c.updatedHLC == nil || c.updatedHLC! < e.hlc {
                c.name = p.name!
                c.colour = p.colour ?? ""
                c.format = format
                c.value = p.value!
                c.domain = p.domain
                c.updatedHLC = e.hlc
            }
        case Kind.cardArchived:
            if c.archivedAt == nil || e.hlc.wall < c.archivedAt! {
                c.archivedAt = e.hlc.wall
            }
        case Kind.cardLogo:
            try Fold.need(e, "logo_id", p.logoID)
            if c.logoHLC == nil || c.logoHLC! < e.hlc {
                c.logoID = p.logoID
                c.logoHLC = e.hlc
            }
        default:
            break
        }
        try s.putCard(c)
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
