import Foundation

/// Lane leases for shared-state resources across concurrent works. The app
/// lane serializes dispatch per RESOLVED app identity — "Safari" and
/// "com.apple.Safari" share one lease once the resolver maps both spellings
/// to the bundle id — while the global focus and pasteboard lanes serialize
/// activations and clipboard chords between parallel tasks.
///
/// The canonical lease contract: bounded concurrent app leases, FIFO
/// waiters, re-entrancy by work id, and cancellation that never consumes
/// a slot.
actor CuaLaneRegistry {
    static let shared = CuaLaneRegistry()

    enum Lane: Hashable {
        /// Canonical app identity — never the caller's spelling.
        case app(String)
        case focus
        case pasteboard
    }

    private struct Waiter {
        let token: UUID
        let workID: String
        let lane: Lane
        let continuation: CheckedContinuation<Void, Error>
    }

    private let appLimit: Int
    private var holders: [Lane: String] = [:]
    private var heldLanes: [String: Set<Lane>] = [:]
    private var waiters: [Waiter] = []
    /// Maps a caller's app spelling to its canonical identity (bundle id).
    /// Installed by the runtime, which owns app resolution; without it the
    /// lease falls back to lowercase-trim normalization.
    private var appIdentityResolver: (@Sendable (String) async -> String)?

    init(appLimit: Int = 3) { self.appLimit = max(1, appLimit) }

    func setAppIdentityResolver(_ r: @escaping @Sendable (String) async -> String) {
        appIdentityResolver = r
    }

    /// App lease — serialized on the canonical identity. A pid is the
    /// strongest identity and wins outright: any spelling naming the same
    /// pid shares the lease.
    func acquire(app: String, pid: Int?, workID: String) async throws {
        // One app lease per work: re-acquiring while held is a no-op, so the
        // re-entrant path skips the resolver hop too.
        if heldLanes[workID]?.contains(where: isAppLane) == true { return }
        guard let lane = await appLane(app: app, pid: pid) else { return }
        try await acquire(lane, workID: workID)
    }

    /// The work id is authoritative on release — re-resolving the spelling
    /// could drift (the app quit, the roster changed) and never find the
    /// lease it was asked to free.
    func release(app: String, pid: Int?, workID: String) async {
        guard let lane = heldLanes[workID]?.first(where: isAppLane) else { return }
        drop(lane, workID: workID)
    }

    /// Focus lane — capacity 1. Covers bring_to_front, foreground-delivery
    /// sequences, invoke_menu, activations and dictation paste.
    func acquireFocus(workID: String) async throws { try await acquire(.focus, workID: workID) }
    func releaseFocus(workID: String) async { drop(.focus, workID: workID) }

    /// Pasteboard lane — capacity 1. Covers copy/cut/paste chords,
    /// clipboard_* tools and the dictation snapshot→paste→restore sequence.
    func acquirePasteboard(workID: String) async throws { try await acquire(.pasteboard, workID: workID) }
    func releasePasteboard(workID: String) async { drop(.pasteboard, workID: workID) }

    /// A work dying mid-wait or mid-hold drops everything it owns: held
    /// lanes release and queued acquires resolve cancelled, so a dead owner
    /// can neither hold nor later claim a slot. Call on every work teardown.
    func releaseAll(workID: String) async {
        for lane in heldLanes[workID] ?? [] { drop(lane, workID: workID) }
        let stale = waiters.filter { $0.workID == workID }
        waiters.removeAll { $0.workID == workID }
        for waiter in stale { waiter.continuation.resume(throwing: CancellationError()) }
    }

    /// Held lanes and queued waiters, compact, for logs and diagnostics.
    func snapshot() -> String {
        let held = holders.map { "\(name($0.key))→\($0.value)" }.sorted()
        let queued = waiters.map { "queued \(name($0.lane))→\($0.workID)" }
        let parts = held + queued
        return parts.isEmpty ? "no lanes held" : parts.joined(separator: "; ")
    }

    private func name(_ lane: Lane) -> String {
        switch lane {
        case .app(let key): return "app(\(key))"
        case .focus: return "focus"
        case .pasteboard: return "pasteboard"
        }
    }

    private func isAppLane(_ lane: Lane) -> Bool {
        if case .app = lane { return true }
        return false
    }

    private func appLane(app: String, pid: Int?) async -> Lane? {
        if let pid { return .app("pid:\(pid)") }
        let resolved: String
        if let resolver = appIdentityResolver { resolved = await resolver(app) }
        else { resolved = app }
        let key = resolved.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // An empty identity leases nothing — a caller with no app is never
        // app-bound and must not serialize on a blank key.
        return key.isEmpty ? nil : .app(key)
    }

    /// Re-entrancy: a lane the work already holds satisfies immediately; for
    /// the app lane ANY held app lease does — one app lease per work.
    private func satisfied(_ lane: Lane, by workID: String) -> Bool {
        guard let held = heldLanes[workID] else { return false }
        if case .app = lane { return held.contains(where: isAppLane) }
        return held.contains(lane)
    }

    private func acquire(_ lane: Lane, workID: String) async throws {
        if satisfied(lane, by: workID) { return }
        try Task.checkCancellation()
        let token = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiters.append(Waiter(token: token, workID: workID, lane: lane, continuation: continuation))
                    admit()
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.cancelWaiter(token) }
            }
        } catch {
            // Admitted-then-cancelled still owes the lane back; a waiter
            // cancelled while queued holds nothing and drops cleanly.
            drop(lane, workID: workID)
            throw error
        }
    }

    private func cancelWaiter(_ token: UUID) {
        // Only a queued acquire cancels out — an admitted owner releases
        // through its own unwind so the slot stays accounted for.
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func drop(_ lane: Lane, workID: String) {
        guard holders[lane] == workID else { return }
        holders.removeValue(forKey: lane)
        heldLanes[workID]?.remove(lane)
        if heldLanes[workID]?.isEmpty == true { heldLanes.removeValue(forKey: workID) }
        admit()
    }

    private func admit() {
        // FIFO scan: a waiter admits only when its lane is free — and, for
        // app lanes, the concurrency cap leaves room.
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            if satisfied(waiter.lane, by: waiter.workID) {
                // A duplicate acquire that queued before the first won
                // admission is satisfied by the lease it already holds.
                waiters.remove(at: index)
                waiter.continuation.resume()
                continue
            }
            guard holders[waiter.lane] == nil else { index += 1; continue }
            if case .app = waiter.lane, appLeaseCount >= appLimit { index += 1; continue }
            waiters.remove(at: index)
            holders[waiter.lane] = waiter.workID
            heldLanes[waiter.workID, default: []].insert(waiter.lane)
            waiter.continuation.resume()
        }
    }

    private var appLeaseCount: Int {
        holders.keys.filter(isAppLane).count
    }
}

/// The drive loop's shared-state lease surface — the registry satisfies it
/// directly.
extension CuaLaneRegistry: CuaLaneLeasing {}
