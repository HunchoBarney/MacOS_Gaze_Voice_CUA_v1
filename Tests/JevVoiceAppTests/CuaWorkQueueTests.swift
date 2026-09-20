import XCTest
@testable import JevVoice

@MainActor
final class CuaWorkQueueTests: XCTestCase {
    func testConflictingAppsWaitAndCancelledWaiterNeverAcquires() async throws {
        let queue = CuaWorkQueue(limit: 3)
        let first = UUID(), second = UUID()
        try await queue.acquire(first, app: "same.app")
        var acquired = false
        let waiting = Task { try await queue.acquire(second, app: "same.app"); acquired = true }
        await Task.yield()
        XCTAssertFalse(acquired)
        waiting.cancel()
        queue.release(first)
        do { try await waiting.value; XCTFail("Cancelled waiter acquired") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(acquired)
    }
    func testIndependentAppsRespectLimitAndRelease() async throws {
        let queue = CuaWorkQueue(limit: 1)
        let first = UUID(), second = UUID()
        try await queue.acquire(first, app: "one")
        var acquired = false
        let waiting = Task { try await queue.acquire(second, app: "two"); acquired = true }
        await Task.yield()
        XCTAssertFalse(acquired)
        queue.release(first)
        try await waiting.value
        XCTAssertTrue(acquired)
        queue.release(second)
    }
}
