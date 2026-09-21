import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class ContinuousIntentTests: XCTestCase {
    func testPartialDispatchReleaseNoReplayAndNewHold() async throws {
        var requests: [String] = []
        let coordinator = ContinuousIntentCoordinator(decide: { words, _, _ in
            SpeechIntent(kind: .command, count: words.count, text: words.joined(separator: " "))
        }, submit: { intent in requests.append(intent.text) })
        coordinator.begin()
        coordinator.update("open Notes", final: false)
        await coordinator.waitForPending()
        XCTAssertEqual(requests, ["open Notes"])
        coordinator.update("open Notes", final: true)
        await coordinator.waitForPending()
        XCTAssertEqual(requests.count, 1)
        coordinator.begin()
        coordinator.update("open Notes", final: true)
        await coordinator.waitForPending()
        XCTAssertEqual(requests.count, 2)
    }
    func testLateCancelledInterpretationCannotDispatch() async throws {
        var requests: [String] = []
        let coordinator = ContinuousIntentCoordinator(decide: { words, _, _ in
            try? await Task.sleep(for: .milliseconds(40))
            return SpeechIntent(kind: .command, count: words.count, text: words.joined(separator: " "))
        }, submit: { requests.append($0.text) })
        coordinator.begin()
        coordinator.update("open Notes", final: false)
        await Task.yield()
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(requests.isEmpty)
    }
    func testLiteralHoldKeepsStopAsTextAndReportsDeferredInsertion() async throws {
        var requests: [String] = []
        let coordinator = ContinuousIntentCoordinator(decide: { words, _, _ in
            SpeechIntent(kind: .dictate, count: words.count, text: words.joined(separator: " "))
        }, submit: { requests.append($0.text) })
        coordinator.begin()
        coordinator.update("dictate blue", final: false)
        await coordinator.waitForPending()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(coordinator.message.contains("inserts on release"))
        coordinator.update("dictate blue stop all", final: true)
        await coordinator.waitForPending()
        XCTAssertEqual(requests, ["dictate blue stop all"])
    }
    func testGrowingSpeechCoalescesAndRechecksIncompleteOldEdge() async throws {
        var release: CheckedContinuation<Void, Never>?
        var observations: [[String]] = []
        var requests: [String] = []
        let coordinator = ContinuousIntentCoordinator(decide: { words, _, _ in
            observations.append(words)
            if observations.count == 1 { await withCheckedContinuation { release = $0 } }
            if words.first == "open" { return SpeechIntent(kind: .command, count: 2, text: "open Notes") }
            return nil
        }, submit: { requests.append($0.text) })
        coordinator.begin(); coordinator.update("open Notes", final: false)
        for _ in 0..<100 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)
        coordinator.update("open Notes and", final: false)
        coordinator.update("open Notes and create", final: false)
        coordinator.update("open Notes and create a note", final: false)
        release?.resume()
        await coordinator.waitForPending()
        XCTAssertEqual(observations.prefix(2).map { $0.joined(separator: " ") }, ["open Notes", "open Notes and create a note"])
        XCTAssertEqual(requests, ["open Notes"])
        XCTAssertEqual(coordinator.remainder, "and create a note")
    }

}
