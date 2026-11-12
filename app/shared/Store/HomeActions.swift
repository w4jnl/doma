// What the Homes and Home screens do to the store, as events: a flag set, a staple added or
// removed, a home or a spot made, renamed or archived, and a photo taken for a spot, whose
// picture waits on disk until its photo.added is accepted and the upload lands.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum HomeActions {
    static func setFlag(_ state: FlagState, home homeID: String, item itemID: String, in session: Session) throws {
        guard state != .unknown else { return }
        try session.record(Kind.flagSet, FlagPayload(homeID: homeID, itemID: itemID, state: state.rawValue))
    }

    /// Accepts what a picture suggested: the flag is set to the proposed state, which closes it.
    static func accept(_ p: ProposalRow, home homeID: String, in session: Session) throws {
        try setFlag(p.state, home: homeID, item: p.itemID, in: session)
    }

    /// Keeps the flag as it is: the proposal is declined and leaves the screen.
    static func decline(_ p: ProposalRow, home homeID: String, in session: Session) throws {
        try session.record(Kind.proposalDeclined, ProposalPayload(proposalID: p.id, homeID: homeID, itemID: p.itemID))
    }

    /// Adds a staple by a typed or spoken line: read as a list's line is, so a quantity or a
    /// note said with it does not become part of the name; an exact name reuses the item,
    /// anything else creates one. It lands at the end of the section the bar points at, or
    /// outside every section when it points at none; a staple that is there already stays
    /// where it is unless a section is named.
    @discardableResult
    static func addStaple(_ text: String, home homeID: String, section: String? = nil, in session: Session) throws -> String? {
        guard let scope = session.scope else { return nil }
        let name = EntryText.parse(text).name
        let norm = Norm.name(name)
        guard !norm.isEmpty else { return nil }
        let existing = try session.store.read(scope) { db, s in try Queries.itemID(db, s, norm: norm) }
        let itemID = existing ?? ULID.make()
        try place(itemID, name: name, isNew: existing == nil, section: section, home: homeID, in: session)
        return itemID
    }

    /// Adds a known item as a staple, at the end of the section or outside every one.
    static func addStaple(itemID: String, home homeID: String, section: String? = nil, in session: Session) throws {
        try place(itemID, name: "", isNew: false, section: section, home: homeID, in: session)
    }

    private static func place(_ itemID: String, name: String, isNew: Bool, section: String?, home homeID: String, in session: Session) throws {
        let current = try staples(homeID, in: session)
        if section == nil, current.contains(where: { $0.itemID == itemID }) { return }
        let target = StapleOrder.name(section ?? "", among: StapleOrder.sections(current))
        let row = FlagRow(itemID: itemID, name: name, state: .unknown, note: "", isStaple: true, ageShown: false, section: target)
        let wanted = StapleOrder.placed([row], in: target, among: current)
        try write(wanted, changed: [itemID], home: homeID, in: session) { events, clock, person in
            if isNew {
                events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.itemNamed, payload: ItemPayload(itemID: itemID, name: name).jsonValue))
            }
        }
    }

    /// The home's staples as they stand, in the order the screen lists them.
    private static func staples(_ homeID: String, in session: Session) throws -> [FlagRow] {
        guard let scope = session.scope else { return [] }
        return try session.store.read(scope) { db, s in
            try Queries.flagRows(db, s, homeID: homeID, staleness: Staleness(days: nil)).filter(\.isStaple)
        }
    }

    /// Writes the order: each staple whose sort has to change is added again, which is the
    /// newest add and so wins the fold; the changed ones say their section as well.
    private static func write(_ wanted: [FlagRow], changed: Set<String>, home homeID: String, in session: Session, first: (inout [Event], HLCClock, String) -> Void = { _, _, _ in }) throws {
        let sorts = StapleOrder.sorts(wanted, changed: changed)
        try session.record { events, clock, person in
            first(&events, clock, person)
            for r in wanted {
                guard let sort = sorts[r.itemID] else { continue }
                let payload = StaplePayload(homeID: homeID, itemID: r.itemID, sort: sort, section: changed.contains(r.itemID) ? r.section : nil)
                events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.stapleAdded, payload: payload.jsonValue))
            }
        }
    }

    /// The room left between two staples' sorts; a drag takes the middle, and renumbers the
    /// home's staples when there is none.
    nonisolated static let sortGap: Int64 = 1000

    /// Moves staples as the screen's rows move, headers among them: each moved staple is added
    /// again with a sort between its new neighbours and the section of the header above it.
    static func moveStaples(_ entries: [StapleEntry], from source: IndexSet, to destination: Int, home homeID: String, in session: Session) throws {
        let (wanted, changed) = StapleOrder.moved(entries, from: source, to: destination)
        guard !changed.isEmpty else { return }
        try write(wanted, changed: changed, home: homeID, in: session)
    }

    /// The same for a home's rows as the query gives them, the staples counted without headers.
    static func moveStaples(_ rows: [FlagRow], from source: IndexSet, to destination: Int, home homeID: String, in session: Session) throws {
        try moveStaples(rows.filter(\.isStaple).map(StapleEntry.row), from: source, to: destination, home: homeID, in: session)
    }

    /// Moves a staple to the end of a section, one that is there or a new one; "" is none.
    static func moveStaple(_ itemID: String, to section: String, home homeID: String, in session: Session) throws {
        let current = try staples(homeID, in: session)
        guard let row = current.first(where: { $0.itemID == itemID }) else { return }
        let target = StapleOrder.name(section, among: StapleOrder.sections(current))
        guard target != row.section else { return }
        try write(StapleOrder.placed([row], in: target, among: current), changed: [itemID], home: homeID, in: session)
    }

    /// Renames a section: each of its staples is added again under the new name. Another
    /// section's name joins the two, this one's staples after the other's.
    static func renameSection(_ old: String, to typed: String, home homeID: String, in session: Session) throws {
        let current = try staples(homeID, in: session)
        let new = StapleOrder.name(typed, among: StapleOrder.sections(current).filter { $0 != old })
        let rows = current.filter { $0.section == old }
        guard !new.isEmpty, new != old, !rows.isEmpty else { return }
        let wanted: [FlagRow]
        if current.contains(where: { $0.section == new }) {
            wanted = StapleOrder.placed(rows, in: new, among: current)
        } else {
            wanted = current.map { var r = $0; if r.section == old { r.section = new }; return r }
        }
        try write(wanted, changed: Set(rows.map(\.itemID)), home: homeID, in: session)
    }

    /// Removes a section and keeps its staples: they go after the ones outside every section.
    static func removeSection(_ name: String, home homeID: String, in session: Session) throws {
        let current = try staples(homeID, in: session)
        let rows = current.filter { $0.section == name }
        guard !name.isEmpty, !rows.isEmpty else { return }
        try write(StapleOrder.placed(rows, in: "", among: current), changed: Set(rows.map(\.itemID)), home: homeID, in: session)
    }

    static func removeStaple(itemID: String, home homeID: String, in session: Session) throws {
        try session.record(Kind.stapleRemoved, StaplePayload(homeID: homeID, itemID: itemID))
    }

    /// A staple's name is the item's name: on every list and at every home.
    static func renameItem(_ itemID: String, to name: String, in session: Session) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Norm.name(n).isEmpty else { return }
        try session.record(Kind.itemRenamed, ItemPayload(itemID: itemID, name: n))
    }

    /// Retires an item, from History: it stops coming up while typing and keeps its place in
    /// the past months; typing its name again in full brings it back.
    static func retireItem(_ itemID: String, in session: Session) throws {
        try session.record(Kind.itemArchived, ItemPayload(itemID: itemID))
    }

    /// Folds one item into another, from History: the kept item takes the dropped one's entries,
    /// flags and staples, and the dropped name becomes an alias of it. One way.
    static func mergeItem(_ dropID: String, into keepID: String, in session: Session) throws {
        guard keepID != dropID else { return }
        try session.record(Kind.itemMerged, ItemPayload(keepID: keepID, dropID: dropID))
    }

    @discardableResult
    static func createHome(named name: String, in session: Session) throws -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let id = ULID.make()
        try session.record(Kind.homeCreated, HomePayload(homeID: id, name: name))
        return id
    }

    static func renameHome(_ homeID: String, to name: String, in session: Session) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try session.record(Kind.homeRenamed, HomePayload(homeID: homeID, name: name))
    }

    static func archiveHome(_ homeID: String, in session: Session) throws {
        try session.record(Kind.homeArchived, HomePayload(homeID: homeID))
    }

    @discardableResult
    static func createSpot(named name: String, home homeID: String, in session: Session) throws -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let id = ULID.make()
        try session.record(Kind.spotCreated, SpotPayload(spotID: id, homeID: homeID, name: name))
        return id
    }

    static func renameSpot(_ spotID: String, to name: String, in session: Session) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try session.record(Kind.spotRenamed, SpotPayload(spotID: spotID, name: name))
    }

    static func archiveSpot(_ spotID: String, in session: Session) throws {
        try session.record(Kind.spotArchived, SpotPayload(spotID: spotID))
    }

    /// A picture taken for a spot: the JPEG, at most 1600 px on its long side at quality 0.8,
    /// waits under the server's pending folder; photo.added goes to the outbox; the syncer
    /// uploads the file once the event is accepted, and keeps it as the picture's cache.
    @discardableResult
    static func addPhoto(_ picture: Data, spot spotID: String, in session: Session) throws -> String? {
        guard let scope = session.scope, let jpeg = Pictures.jpeg(from: picture) else { return nil }
        let id = ULID.make()
        try PhotoFiles.savePending(jpeg.data, server: scope.serverID, household: scope.householdID, photoID: id)
        try session.record(Kind.photoAdded, PhotoPayload(photoID: id, spotID: spotID, bytes: Int64(jpeg.data.count), width: Int64(jpeg.width), height: Int64(jpeg.height)))
        return id
    }
}

/// The picture pipeline on the device: whatever the camera gives, turned the right way up,
/// scaled to the spec's long edge and written as a JPEG with nothing but the pixels.
enum Pictures {
    static let longEdge = 1600
    static let quality = 0.8

    struct JPEG: Sendable {
        var data: Data
        var width: Int
        var height: Int
    }

    /// nonisolated: ImageIO does the work, on whatever thread asks.
    nonisolated static func jpeg(from raw: Data, longEdge: Int = longEdge) -> JPEG? {
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image)
    }

    nonisolated static func encode(_ image: CGImage) -> JPEG? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return JPEG(data: out as Data, width: image.width, height: image.height)
    }
}

/// Where pictures live on the device: under Application Support, per server, a pending folder
/// for what has not gone up and a cache for what came down or went up.
enum PhotoFiles {
    nonisolated static var root: URL {
        if let override = overrideRoot { return override }
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("doma/photos", isDirectory: true)
    }

    /// The tests point the files at a folder of their own.
    nonisolated(unsafe) static var overrideRoot: URL?

    nonisolated static func pendingDir(server: String) -> URL { root.appendingPathComponent(server + "/pending", isDirectory: true) }
    nonisolated static func pendingURL(server: String, household: String, photoID: String) -> URL {
        pendingDir(server: server).appendingPathComponent(household + "." + photoID + ".jpg")
    }

    nonisolated static func cacheURL(server: String, photoID: String, thumb: Bool) -> URL {
        root.appendingPathComponent(server, isDirectory: true).appendingPathComponent(photoID + (thumb ? ".t.jpg" : ".jpg"))
    }

    nonisolated static func savePending(_ data: Data, server: String, household: String, photoID: String) throws {
        let url = pendingURL(server: server, household: household, photoID: photoID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// One pending picture: its household and photo id, from the file's name.
    struct Pending: Hashable, Sendable {
        var household: String
        var photoID: String
        var url: URL
    }

    nonisolated static func pending(server: String) -> [Pending] {
        let dir = pendingDir(server: server)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().compactMap { name in
            let parts = name.split(separator: ".")
            guard parts.count == 3, parts[2] == "jpg" else { return nil }
            return Pending(household: String(parts[0]), photoID: String(parts[1]), url: dir.appendingPathComponent(name))
        }
    }

    /// The picture went up: the file becomes the cache entry.
    nonisolated static func landed(_ p: Pending, server: String) {
        let dest = cacheURL(server: server, photoID: p.photoID, thumb: false)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: p.url, to: dest)
    }

    nonisolated static func drop(_ p: Pending) {
        try? FileManager.default.removeItem(at: p.url)
    }

    nonisolated static func cache(_ data: Data, server: String, photoID: String, thumb: Bool) {
        let url = cacheURL(server: server, photoID: photoID, thumb: thumb)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The picture as it is on this device: the cache, or the pending file for one not yet up.
    nonisolated static func local(server: String, household: String, photoID: String, thumb: Bool) -> Data? {
        if let d = try? Data(contentsOf: cacheURL(server: server, photoID: photoID, thumb: thumb)) { return d }
        if let d = try? Data(contentsOf: pendingURL(server: server, household: household, photoID: photoID)) { return d }
        if thumb, let d = try? Data(contentsOf: cacheURL(server: server, photoID: photoID, thumb: false)) { return d }
        return nil
    }

    nonisolated static func wipe(server: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(server, isDirectory: true))
    }
}
