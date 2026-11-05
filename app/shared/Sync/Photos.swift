// Pictures between the device and its doma: the pending files go up once their photo.added is
// accepted (after every exchange, retried with the next), and the screens get a picture by id
// from the cache on disk, else downloaded once with the device's signature.
import CoreGraphics
import Foundation
import ImageIO
import Observation

extension Syncer {
    /// Uploads what waits for a server: the file goes up by photo id; 404 means the event is
    /// not accepted yet, so it waits for the next exchange; a refusal (not a JPEG, over quota)
    /// drops the file, the row stays pending on every device.
    func uploadPending(_ server: Server) async {
        for p in PhotoFiles.pending(server: server.serverID) {
            guard server.scopes.contains(where: { $0.householdID == p.household }), let data = try? Data(contentsOf: p.url) else {
                PhotoFiles.drop(p)
                continue
            }
            do {
                _ = try await server.client.upload("/photos/v1/" + p.household + "/" + p.photoID, jpeg: data)
                PhotoFiles.landed(p, server: server.serverID)
            } catch ClientError.problem(let problem) where problem.status == 404 {
                continue
            } catch ClientError.problem(let problem) where problem.status == 400 || problem.status == 413 || problem.status == 422 {
                PhotoFiles.drop(p)
                uploadError = problem.message
            } catch {
                return
            }
        }
    }
}

/// The pictures the screens show, by photo id: decoded once, kept in memory for the session,
/// read from the cache on disk, else fetched from the household's doma and cached.
@MainActor @Observable
final class PhotoLoader {
    private(set) var images: [String: CGImage] = [:]
    /// Ids whose fetch failed, with when, so a pending picture is asked for again later, not
    /// in a loop.
    private var failed: [String: Date] = [:]
    private var loading: Set<String> = []
    private unowned let session: Session

    init(session: Session) {
        self.session = session
    }

    private func key(_ id: String, thumb: Bool) -> String { thumb ? id + "/t" : id }

    /// The picture if it is at hand; otherwise nil now and a load, which updates images.
    func image(_ photoID: String, thumb: Bool) -> CGImage? {
        let k = key(photoID, thumb: thumb)
        if let img = images[k] { return img }
        if loading.contains(k) { return nil }
        if let at = failed[k], Date().timeIntervalSince(at) < 30 { return nil }
        guard let scope = session.scope, let client = session.client else { return nil }
        loading.insert(k)
        Task {
            defer { loading.remove(k) }
            if let data = PhotoFiles.local(server: scope.serverID, household: scope.householdID, photoID: photoID, thumb: thumb), let img = Self.decode(data) {
                images[k] = img
                return
            }
            do {
                let data = try await client.download("/photos/v1/" + scope.householdID + "/" + photoID + (thumb ? "/thumb" : ""))
                guard let img = Self.decode(data) else { throw ClientError.badResponse(0) }
                PhotoFiles.cache(data, server: scope.serverID, photoID: photoID, thumb: thumb)
                images[k] = img
            } catch {
                failed[k] = Date()
            }
        }
        return nil
    }

    /// A picture just taken is shown at once, from its bytes.
    func put(_ data: Data, photoID: String) {
        if let img = Self.decode(data) {
            images[key(photoID, thumb: false)] = img
            images[key(photoID, thumb: true)] = img
        }
    }

    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
