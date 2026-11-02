// Live is a value a screen shows, kept current by GRDB's observation of the tables it reads:
// the row appears or strikes on the tap, because the tap wrote the store, and again when the
// same change comes back from the server, which is a no-op.
import Foundation
import GRDB
import Observation

@MainActor @Observable
final class Live<Value: Sendable> {
    private(set) var value: Value
    nonisolated(unsafe) private var task: Task<Void, Never>?

    init(_ store: DomaStore, initial: Value, _ fetch: @escaping @Sendable (Database) throws -> Value) {
        value = (try? store.db.read(fetch)) ?? initial
        let observation = ValueObservation.tracking(fetch)
        task = Task { [weak self] in
            do {
                // fetched on a reader after each commit, delivered on the main actor in one hop
                for try await v in observation.values(in: store.db, scheduling: .mainActor) {
                    guard let self else { return }
                    self.value = v
                }
            } catch {
                // the store is gone or the query failed: the last value stands
            }
        }
    }

    deinit {
        task?.cancel()
    }
}
