import XCTest
@testable import JevVoice

final class CuaLaneRegistryTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return raw }
            set { lock.lock(); raw = newValue; lock.unlock() }
        }
    }
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var order: [String] = []
        func mark(_ work: String) { lock.lock(); order.append(work); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return order }
    }

    /// Spawned waiter tasks need a few turns to reach the actor and enqueue.
    private func settle() async {
        for _ in 0 ..< 8 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    // MARK: - Canonical app keying

    /// The resolver maps both spellings to the bundle id — "Safari" and
    /// "com.apple.Safari" can never split into two leases on the same app.
    func testResolverUnifiesSpellingAndBundleIDIntoOneLease() async throws {
        let registry = CuaLaneRegistry()
        await registry.setAppIdentityResolver { spelling in
            spelling.localizedCaseInsensitiveContains("safari") ? "com.apple.safari" : spelling
        }
        try await registry.acquire(app: "Safari", pid: nil, workID: "first")
        let acquired = Flag()
        let waiting = Task {
            try await registry.acquire(app: "com.apple.Safari", pid: nil, workID: "second")
            acquired.value = true
        }
        await settle()
        XCTAssertFalse(acquired.value, "com.apple.Safari must wait on Safari's resolved lease")
        await registry.release(app: "Safari", pid: nil, workID: "first")
        try await waiting.value
        XCTAssertTrue(acquired.value)
    }

    /// With no resolver installed, lowercase-trim normalization still merges
    /// spellings; release keys on the work id, not the release-time spelling.
    func testFallbackNormalizationMergesCaseAndWhitespace() async throws {
        let registry = CuaLaneRegistry()
        try await registry.acquire(app: "  SAFARI ", pid: nil, workID: "first")
        let acquired = Flag()
        let waiting = Task {
            try await registry.acquire(app: "safari", pid: nil, workID: "second")
            acquired.value = true
        }
        await settle()
        XCTAssertFalse(acquired.value)
        await registry.release(app: "com.apple.Safari", pid: nil, workID: "first")
        try await waiting.value
        XCTAssertTrue(acquired.value)
    }

    /// A pid outranks every spelling — two names for one process share the
    /// lease — while a different pid is a different app lease entirely.
    func testPIDIsTheStrongestIdentity() async throws {
        let registry = CuaLaneRegistry()
        try await registry.acquire(app: "Safari", pid: 4242, workID: "first")
        let samePID = Flag()
        let blocked = Task {
            try await registry.acquire(app: "completely.different.spelling", pid: 4242, workID: "second")
            samePID.value = true
        }
        await settle()
        XCTAssertFalse(samePID.value, "the same pid is one lease regardless of spelling")
        // Another process of the same app is its own lease — admits at once.
        try await registry.acquire(app: "Safari", pid: 777, workID: "third")
        await registry.release(app: "Safari", pid: 4242, workID: "first")
        try await blocked.value
        XCTAssertTrue(samePID.value)
    }

    // MARK: - Focus / pasteboard lanes

    /// Each singleton lane excludes a second holder; the two lanes are
    /// independent of each other and of app leases.
    func testFocusAndPasteboardAreExclusiveButIndependent() async throws {
        let registry = CuaLaneRegistry()
        try await registry.acquireFocus(workID: "a")
        try await registry.acquirePasteboard(workID: "b")
        let focusB = Flag()
        let pasteA = Flag()
        let focusWait = Task { try await registry.acquireFocus(workID: "b"); focusB.value = true }
        let pasteWait = Task { try await registry.acquirePasteboard(workID: "a"); pasteA.value = true }
        await settle()
        XCTAssertFalse(focusB.value)
        XCTAssertFalse(pasteA.value)
        await registry.releaseFocus(workID: "a")
        await registry.releasePasteboard(workID: "b")
        try await focusWait.value
        try await pasteWait.value
        XCTAssertTrue(focusB.value)
        XCTAssertTrue(pasteA.value)
    }

    // MARK: - Re-entrancy

    /// Re-acquiring while held is a no-op — it neither waits nor takes a
    /// second slot, and one work never holds two app leases.
    func testReentrantAcquireIsANoOp() async throws {
        let registry = CuaLaneRegistry(appLimit: 1)
        try await registry.acquire(app: "safari", pid: nil, workID: "w")
        // These return immediately — the same lane, a different app, and the
        // focus lane twice all satisfy re-entrantly.
        try await registry.acquire(app: "safari", pid: nil, workID: "w")
        try await registry.acquire(app: "other-app", pid: nil, workID: "w")
        try await registry.acquireFocus(workID: "w")
        try await registry.acquireFocus(workID: "w")
        // The single app slot still belongs to w — a new work waits.
        let acquired = Flag()
        let waiting = Task {
            try await registry.acquire(app: "notes", pid: nil, workID: "x")
            acquired.value = true
        }
        await settle()
        XCTAssertFalse(acquired.value, "the cap slot stays with the re-entrant holder")
        await registry.releaseAll(workID: "w")
        try await waiting.value
        XCTAssertTrue(acquired.value)
    }

    // MARK: - Capacity and ordering

    /// The cap is on concurrent app leases, not app identity — a third
    /// distinct app waits while two hold.
    func testAppLeaseCapAdmitsDistinctAppsUpToTheLimit() async throws {
        let registry = CuaLaneRegistry(appLimit: 2)
        try await registry.acquire(app: "a", pid: nil, workID: "w1")
        try await registry.acquire(app: "b", pid: nil, workID: "w2")
        let acquired = Flag()
        let waiting = Task {
            try await registry.acquire(app: "c", pid: nil, workID: "w3")
            acquired.value = true
        }
        await settle()
        XCTAssertFalse(acquired.value)
        await registry.release(app: "a", pid: nil, workID: "w1")
        try await waiting.value
        XCTAssertTrue(acquired.value)
    }

    /// Waiters on a full lane admit oldest-first.
    func testWaitersAreFIFO() async throws {
        let registry = CuaLaneRegistry()
        try await registry.acquireFocus(workID: "first")
        let order = Recorder()
        let second = Task {
            try await registry.acquireFocus(workID: "second")
            order.mark("second")
        }
        await settle()
        let third = Task {
            try await registry.acquireFocus(workID: "third")
            order.mark("third")
        }
        await settle()
        await registry.releaseFocus(workID: "first")
        try await second.value
        await settle()
        XCTAssertEqual(order.values, ["second"])
        await registry.releaseFocus(workID: "second")
        try await third.value
        XCTAssertEqual(order.values, ["second", "third"])
    }

    // MARK: - releaseAll and cancellation

    /// Dying mid-wait must not let the dead work's queued acquire claim a
    /// slot later; dying mid-hold frees everything at once.
    func testReleaseAllDropsHeldLanesAndStaleWaiters() async throws {
        let registry = CuaLaneRegistry()
        try await registry.acquireFocus(workID: "holder")
        let stale = Task { try await registry.acquireFocus(workID: "dying") }
        await settle()
        try await registry.acquire(app: "safari", pid: nil, workID: "dying")
        try await registry.acquirePasteboard(workID: "dying")
        await registry.releaseAll(workID: "dying")
        do {
            try await stale.value
            XCTFail("a dead work's queued acquire must never claim a slot")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // Focus still belongs to its living holder — releaseAll only dropped
        // the dying work's app and pasteboard leases.
        let probe = Flag()
        let probeTask = Task { try await registry.acquireFocus(workID: "probe"); probe.value = true }
        await settle()
        XCTAssertFalse(probe.value)
        try await registry.acquire(app: "safari", pid: nil, workID: "next")
        try await registry.acquirePasteboard(workID: "next")
        await registry.releaseFocus(workID: "holder")
        try await probeTask.value
        XCTAssertTrue(probe.value)
    }

    /// A cancelled queued acquire throws CancellationError and leaves the
    /// lane free for the next waiter — the slot is never consumed.
    func testCancelledWaiterNeverConsumesASlot() async throws {
        let registry = CuaLaneRegistry()
        try await registry.acquire(app: "safari", pid: nil, workID: "holder")
        let acquired = Flag()
        let waiting = Task {
            try await registry.acquire(app: "safari", pid: nil, workID: "waiter")
            acquired.value = true
        }
        await settle()
        XCTAssertFalse(acquired.value)
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("cancelled waiter acquired")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(acquired.value)
        await registry.release(app: "safari", pid: nil, workID: "holder")
        try await registry.acquire(app: "safari", pid: nil, workID: "next")
    }

    /// However cancel-vs-admit lands, the lane ends free: admitted-then-
    /// cancelled still owes the lane back through its unwind.
    func testCancelRacingAdmissionStillLeavesTheLaneFree() async throws {
        let registry = CuaLaneRegistry()
        try await registry.acquireFocus(workID: "holder")
        let waiting = Task { try await registry.acquireFocus(workID: "waiter") }
        await settle()
        waiting.cancel()
        await registry.releaseFocus(workID: "holder")
        try? await waiting.value
        await settle()
        // If the waiter won admission before the cancel landed, its release
        // path already dropped the lane — "next" must acquire without waiting.
        try await registry.acquireFocus(workID: "next")
    }

    // MARK: - Diagnostics

    func testSnapshotDescribesHeldLanesAndWaiters() async throws {
        let registry = CuaLaneRegistry()
        try await registry.acquire(app: "Safari", pid: nil, workID: "w1")
        try await registry.acquireFocus(workID: "w2")
        let waiting = Task { try await registry.acquireFocus(workID: "w3") }
        await settle()
        let snapshot = await registry.snapshot()
        XCTAssertTrue(snapshot.contains("app(safari)→w1"), snapshot)
        XCTAssertTrue(snapshot.contains("focus→w2"), snapshot)
        XCTAssertTrue(snapshot.contains("focus→w3"), snapshot)
        waiting.cancel()
        try? await waiting.value
    }
}
