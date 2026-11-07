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
    /// anything else creates one.
    @discardableResult
    static func addStaple(_ text: String, home homeID: String, in session: Session) throws -> String? {
        guard let scope = session.scope else { return nil }
        let name = EntryText.parse(text).name
        let norm = Norm.name(name)
        guard !norm.isEmpty else { return nil }
        let (existing, sort) = try session.store.read(scope) { db, s in
            (try Queries.itemID(db, s, norm: norm), try Queries.nextStapleSort(db, s, homeID: homeID))
        }
        let itemID = existing ?? ULID.make()
        try session.record { events, clock, person in
            if existing == nil {
                events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.itemNamed, payload: ItemPayload(itemID: itemID, name: name).jsonValue))
            }
            events.append(Event(id: ULID.make(), personID: person, hlc: clock.next(), kind: Kind.stapleAdded, payload: StaplePayload(homeID: homeID, itemID: itemID, sort: sort).jsonValue))
        }
        return itemID
    }

    /// Adds a known item as a staple, at the end.
    static func addStaple(itemID: String, home homeID: String, in session: Session) throws {
        guard let scope = session.scope else { return }
        let sort = try session.store.read(scope) { db, s in try Queries.nextStapleSort(db, s, homeID: homeID) }
        try session.record(Kind.stapleAdded, StaplePayload(homeID: homeID, itemID: itemID, sort: sort))
    }

    /// The room left between two staples' sorts; a drag takes the middle, and renumbers the
    /// home's staples when there is none.
    nonisolated static let sortGap: Int64 = 1000

    /// Moves staples as the list's rows move: each moved staple is added again with a sort
    /// between its new neighbours, which is the newest add and so wins the fold.
    static func moveStaples(_ rows: [FlagRow], from source: IndexSet, to destination: Int, home homeID: String, in session: Session) throws {
        let before = rows.filter(\.isStaple)
        var staples = before
        staples.move(fromOffsets: source, toOffset: destination)
        let moved = Set(source.map { before[$0].itemID })
        var sorts = Dictionary(uniqueKeysWithValues: staples.map { ($0.itemID, $0.sort) })
        func renumber() throws {
            for (j, r) in staples.enumerated() {
                let s = Int64(j + 1) * sortGap
                if sorts[r.itemID] != s {
                    sorts[r.itemID] = s
                    try session.record(Kind.stapleAdded, StaplePayload(homeID: homeID, itemID: r.itemID, sort: s))
                }
            }
        }
        for (i, row) in staples.enumerated() where moved.contains(row.itemID) {
            let prev = staples[..<i].last { !moved.contains($0.itemID) || sorts[$0.itemID] != $0.sort }.map { sorts[$0.itemID]! }
            let next = staples[(i + 1)...].first { !moved.contains($0.itemID) }.map { sorts[$0.itemID]! }
            let sort: Int64
            switch (prev, next) {
            case (nil, nil): continue
            case (let p?, nil): sort = p + sortGap
            case (nil, let n?): sort = n - sortGap
            case (let p?, let n?) where n - p > 1: sort = p + (n - p) / 2
            default:
                return try renumber()
            }
            sorts[row.itemID] = sort
            try session.record(Kind.stapleAdded, StaplePayload(homeID: homeID, itemID: row.itemID, sort: sort))
        }
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
