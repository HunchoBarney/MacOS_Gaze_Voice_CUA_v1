import Foundation

/// App-level leases protect multi-step sequences across separate Driver sessions.
@MainActor
final class CuaWorkQueue {
    private struct Waiter {
        let id: UUID
        let app: String
        let continuation: CheckedContinuation<Void, Error>
    }
    private let limit: Int
    private var active: [UUID: String] = [:]
    private var waiting: [Waiter] = []
    init(limit: Int = 3) { self.limit = max(1, limit) }

    func acquire(_ id: UUID, app: String) async throws {
        // Re-entrant per work: a nested execution stage (a consent follow-up
        // re-entering the loop) must not wait on the lease it already holds.
        guard active[id] == nil else { return }
        try Task.checkCancellation()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiting.append(Waiter(id: id, app: app, continuation: continuation))
                    admit()
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        } catch { release(id); throw error }
    }
    func release(_ id: UUID) { active.removeValue(forKey: id); admit() }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        // An admitted owner releases only after its in-flight operation unwinds.
    }
    private func admit() {
        while active.count < limit,
              let index = waiting.firstIndex(where: { !active.values.contains($0.app) }) {
            let next = waiting.remove(at: index)
            active[next.id] = next.app
            next.continuation.resume()
        }
    }
}
