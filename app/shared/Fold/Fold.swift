// The fold applies events to the materialised tables: the Swift port of internal/fold, tested
// against the same docs/fixtures/fold.json and with the same rules, so a phone and the server
// fold the same events to the same tables in any arrival order:
//
//   - single values (names, colours, flags) are last-writer-wins on the stamp;
//   - sets (staples) keep the latest add and the latest remove;
//   - the catalog is derived by replaying every item event in stamp order;
//   - entries are derived per (list, item) by replaying that key's events.
//
// The one thing the port adds: a phone that joined through a snapshot has tables but not the
// events behind them. Rows the log cannot account for (an item without an item event, an entry
// whose opening event is missing, a flag or staple whose stamp no event carries) are a base, and
// a replay re-expresses them as the events that made them, at their own stamps, among the log's
// events: so a late event with an older stamp lands where the server put it. With a full log
// there are no base rows, so the fixture and the permutation tests hold unchanged.
import Foundation

enum Fold {
    /// Folds one event into the store. The caller has already appended it to the log the store
    /// reads for replays. An unknown kind is skipped, so an old app survives a new server.
    static func apply(_ e: Event, to s: some FoldStore) throws {
        switch e.kind {
        case Kind.itemNamed, Kind.itemRenamed, Kind.itemMerged:
            try Catalog.replay(s)
        case Kind.listCreated, Kind.listRenamed, Kind.listArchived:
            try Lists.applyList(s, e)
        case Kind.entryAdded, Kind.entryEdited, Kind.entryChecked, Kind.entryUnchecked, Kind.entryMoved, Kind.entryRemoved:
            try Entries.applyEntryEvent(s, e)
        case Kind.entryCleared:
            try Entries.applyEntryCleared(s, e)
        case Kind.flagSet:
            try Flags.applyFlagSet(s, e)
        case Kind.flagProposed, Kind.proposalDeclined:
            try Flags.applyProposal(s, e)
        case Kind.stapleAdded, Kind.stapleRemoved:
            try Flags.applyStaple(s, e)
        case Kind.homeCreated, Kind.homeRenamed, Kind.homeArchived:
            try Lists.applyHome(s, e)
        case Kind.spotCreated, Kind.spotRenamed, Kind.spotArchived:
            try Lists.applySpot(s, e)
        case Kind.photoAdded:
            try Flags.applyPhotoAdded(s, e)
        case Kind.tripPlanned:
            try Flags.applyTripPlanned(s, e)
        case Kind.tripCancelled:
            try Flags.applyTripCancelled(s, e)
        case Kind.tripArrived:
            try Flags.applyTripArrived(s, e)
        default:
            // member.removed and device.revoked are the sync layer's; anything else is a
            // kind this app does not know
            return
        }
    }

    static func need(_ e: Event, _ field: String, _ value: String?) throws {
        if value == nil || value == "" {
            throw FoldError.badPayload(kind: e.kind, id: e.id, reason: "\(field) is empty")
        }
    }

    /// Follows merged_into to the owning item. A missing id is returned as is: events may name
    /// an item whose item.named has not arrived.
    static func resolveItem(_ s: some FoldStore, _ id: String) throws -> String {
        var id = id
        var seen = 0
        while true {
            guard let it = try s.item(id), let into = it.mergedInto else { return id }
            id = into
            seen += 1
            if seen > 64 { throw FoldError.mergeCycle }
        }
    }

    static let flagStates: Set<String> = ["have", "low", "out"]
}
