import XCTest
@testable import JevVoice

final class ProcessResponsivenessTests: XCTestCase {
    @MainActor
    func testSystemActionRunsOffMainThreadAndAllowsUIWork() async throws {
        let started = expectation(description: "process began")
        let uiWorked = expectation(description: "main actor remained responsive")
        let action = Task { @MainActor in
            try await Executor.runSystemAsync(.lockScreen, percent: nil) { _, _ in
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                Thread.sleep(forTimeInterval: 0.1)
                return ""
            }
        }
        await fulfillment(of: [started], timeout: 2)
        Task { @MainActor in uiWorked.fulfill() }
        await fulfillment(of: [uiWorked], timeout: 0.05)
        _ = try await action.value
    }
}
