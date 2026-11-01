// Syncer moves the outbox up and the log down (docs/design.md, Client side): on foreground,
// 300 ms after an outbox write, every 10 s while a list screen is visible and every 5 s in shop
// mode, on a silent push, and on the background refresh. A failure is one small offline badge;
// the next sync catches up. A 401 means this device is revoked, and the store for that server
// is wiped.
import Foundation
import Observation

@MainActor @Observable
final class Syncer {
    /// The last sync did not reach the server.
    private(set) var offline = false
    private(set) var syncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    /// Events the server refused, kept for Settings and the log.
    private(set) var rejected: [(id: String, reason: String)] = []

    private let store: DomaStore
    private let client: @MainActor () -> SyncClient?
    private let scopes: @MainActor () -> [Scope]
    private let clock: @MainActor () -> HLCClock?
    private let revoked: @MainActor () -> Void
    private let removed: @MainActor (Scope) -> Void
    private var debounce: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var again = false

    static let eventsPerRequest = 2000
    static let debounceMilliseconds = 300

    init(store: DomaStore,
         client: @escaping @MainActor () -> SyncClient?,
         scopes: @escaping @MainActor () -> [Scope],
         clock: @escaping @MainActor () -> HLCClock?,
         revoked: @escaping @MainActor () -> Void,
         removed: @escaping @MainActor (Scope) -> Void) {
        self.store = store
        self.client = client
        self.scopes = scopes
        self.clock = clock
        self.revoked = revoked
        self.removed = removed
    }

    /// After an outbox write: one sync, 300 ms after the last kick.
    func kick() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Every `seconds` while a screen wants it; nil stops.
    func setPolling(seconds: Double?) {
        poller?.cancel()
        poller = nil
        guard let seconds else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.sync()
            }
        }
    }

    /// One full exchange: loops while the server has more or the outbox is not empty. A second
    /// call while one runs waits for it and runs once more.
    func sync() async {
        if let running {
            again = true
            await running.value
            return
        }
        let task = Task { await self.exchange() }
        running = task
        await task.value
        running = nil
        if again {
            again = false
            await sync()
        }
    }

    private func exchange() async {
        guard let client = client(), client.credentialID != nil else { return }
        let scopes = scopes()
        guard !scopes.isEmpty else { return }
        syncing = true
        defer { syncing = false }
        do {
            for _ in 0..<50 {
                var request = SyncRequest(households: [])
                var sent: [String: [String]] = [:]
                let per = max(1, Self.eventsPerRequest / scopes.count)
                for scope in scopes {
                    let items = try store.outbox(scope, limit: per)
                    sent[scope.householdID] = items.map(\.eventID)
                    request.households.append(.init(id: scope.householdID, since: try store.cursor(scope), events: items.map(\.body)))
                }
                let response = try await client.sync(request)
                var progressed = false
                for hh in response.households {
                    guard let scope = scopes.first(where: { $0.householdID == hh.id }) else { continue }
                    try store.dequeue(scope, ids: hh.accepted + hh.rejected.map(\.id))
                    for r in hh.rejected {
                        rejected.append((r.id, r.reason))
                    }
                    if !hh.accepted.isEmpty || !hh.rejected.isEmpty { progressed = true }
                    if let snap = hh.snapshot, let url = URL(string: snap) {
                        let doc = try await client.snapshot(url)
                        let seq = doc.seq ?? Int64(url.lastPathComponent) ?? 0
                        try store.importSnapshot(doc.tables, seq: seq, scope: scope)
                        progressed = true
                        continue
                    }
                    let since = try store.cursor(scope)
                    try store.applyRemote(hh.events, scope: scope, clock: clock())
                    for e in hh.events {
                        if e.kind == Kind.memberRemoved, (try? JSONDecoder().decode(MemberRemoved.self, from: e.payload.data))?.personID == scope.personID {
                            try store.removeHousehold(scope)
                            removed(scope)
                        }
                    }
                    if hh.next > since {
                        try store.setCursor(scope, hh.next)
                        progressed = true
                    }
                }
                if !progressed { break }
            }
            offline = false
            lastError = nil
            lastSyncedAt = Date()
        } catch ClientError.unauthorized {
            // this device is revoked: the store for the server goes, the app returns to Scan
            offline = false
            lastError = nil
            revoked()
        } catch ClientError.rateLimited(let wait) {
            lastError = "Too many requests; waiting \(Int(wait)) s"
        } catch let e as ClientError {
            offline = e.isOffline
            if case .problem(let p) = e { lastError = p.message }
            if case .badResponse(let code) = e { lastError = "Unexpected answer (\(code))" }
            for scope in scopes {
                try? store.noteAttempt(scope, ids: (try? store.outbox(scope, limit: Self.eventsPerRequest))?.map(\.eventID) ?? [])
            }
        } catch {
            offline = true
            lastError = error.localizedDescription
        }
    }

    private struct MemberRemoved: Decodable {
        var personID: String
        enum CodingKeys: String, CodingKey {
            case personID = "person_id"
        }
    }
}
