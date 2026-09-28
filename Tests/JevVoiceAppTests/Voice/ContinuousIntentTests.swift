import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class ContinuousIntentTests: XCTestCase {
    func testTranscriptHandoffPreservesOriginalTextRangesAndTaskContext() async throws {
        let captureID = UUID()
        let original = "open Notes\nthen type  café stop"
        let context: JSONValue = .object(["tasks": .array([.object(["id": .string("task-1"), "status": .string("Working")])])])
        var handoffs: [TranscriptHandoff] = []
        let coordinator = ContinuousIntentCoordinator(submit: { handoffs.append($0) })
        coordinator.context = { context }
        coordinator.begin(captureID: captureID)
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 1.8, text: original, isFinal: true))
        coordinator.record(audio)
        coordinator.update(original, final: false)
        await coordinator.waitForPending()

        let handoff = try XCTUnwrap(handoffs.first)
        XCTAssertEqual(handoff.transcript, original)
        XCTAssertEqual(handoff.captureID, captureID)
        XCTAssertEqual(handoff.revision, audio.revision)
        XCTAssertEqual(handoff.audioRanges, audio.segments)
        XCTAssertEqual(handoff.pendingWordStart, 0)
        XCTAssertEqual(handoff.pendingWordEnd, 6)
        XCTAssertFalse(handoff.final)
        XCTAssertEqual(handoff.taskContext, context)
        XCTAssertGreaterThan(handoff.receivedAt, 0)
    }

    func testStableCompleteTranscriptIsHandedOffWhileCaptureRemainsOpen() async throws {
        var handoffs: [TranscriptHandoff] = []
        let coordinator = ContinuousIntentCoordinator(submit: { handoffs.append($0) })
        coordinator.begin()
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 1, text: "open Notes", isFinal: true))
        coordinator.record(audio)
        coordinator.update("open Notes", final: false)
        await coordinator.waitForPending()

        XCTAssertEqual(handoffs.map(\.transcript), ["open Notes"])
        XCTAssertFalse(handoffs[0].final)
    }

    func testAcceptedSpanAdvancesWithinOriginalTranscriptAndFinalizationDoesNotReplayIt() async throws {
        var handoffs: [TranscriptHandoff] = []
        let coordinator = ContinuousIntentCoordinator(submit: { handoffs.append($0) })
        coordinator.begin()
        var audio = RangedTranscript()
        let original = "open Notes then search for hiking"
        try audio.apply(.init(start: 0, end: 2, text: original, isFinal: true))
        coordinator.record(audio)
        coordinator.update(original, final: false)
        await coordinator.waitForPending()
        let first = try XCTUnwrap(handoffs.first)

        XCTAssertTrue(coordinator.consume(first, wordRange: 0..<2))
        await coordinator.waitForPending()
        XCTAssertEqual(handoffs.count, 2)
        XCTAssertEqual(handoffs[1].transcript, original, "The executor receives source text, not a reconstructed remainder")
        XCTAssertEqual(handoffs[1].pendingWordStart, 2)
        XCTAssertEqual(handoffs[1].pendingWordEnd, 6)

        coordinator.update(original, final: true)
        await coordinator.waitForPending()
        XCTAssertEqual(handoffs.count, 3, "Finalization rechecks only the still-pending remainder")
        XCTAssertEqual(handoffs.map(\.pendingWordStart), [0, 2, 2], "The accepted first request never returns to the pending range")
    }

    func testWaitForPendingDrainsHandoffScheduledByConsumedSpan() async throws {
        var releaseFirst: CheckedContinuation<Void, Never>?
        var releaseSecond: CheckedContinuation<Void, Never>?
        var waiterFinished = false
        var coordinator: ContinuousIntentCoordinator!
        coordinator = ContinuousIntentCoordinator(submit: { handoff in
            if handoff.pendingWordStart == 0 {
                await withCheckedContinuation { releaseFirst = $0 }
                XCTAssertTrue(coordinator.consume(handoff, wordRange: 0..<2))
            } else {
                await withCheckedContinuation { releaseSecond = $0 }
                coordinator.report(handoff, outcome: "incomplete", message: "Waiting")
            }
        })
        coordinator.begin()
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 1, text: "open Notes search again", isFinal: true))
        coordinator.record(audio)
        coordinator.update(audio.text, final: false)
        for _ in 0..<100 where releaseFirst == nil { await Task.yield() }
        XCTAssertNotNil(releaseFirst)

        let waiter = Task {
            await coordinator.waitForPending()
            waiterFinished = true
        }
        let first = releaseFirst
        releaseFirst = nil
        first?.resume()
        for _ in 0..<100 where releaseSecond == nil { await Task.yield() }
        XCTAssertNotNil(releaseSecond)
        await Task.yield()
        XCTAssertFalse(waiterFinished, "Waiting for quiescence must include the replacement handoff")

        let release = releaseSecond
        releaseSecond = nil
        release?.resume()
        await waiter.value
        XCTAssertTrue(waiterFinished)
        XCTAssertFalse(coordinator.busy)
    }

    func testRevisionRejectsStaleDecisionAndAcceptsLatestStableSpanOnce() async throws {
        var handoffs: [TranscriptHandoff] = []
        let coordinator = ContinuousIntentCoordinator(submit: { handoffs.append($0) })
        let captureID = UUID()
        coordinator.begin(captureID: captureID)
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 1, text: "open Notes", isFinal: false))
        coordinator.record(audio)
        coordinator.update("open Notes", final: false)
        await coordinator.waitForPending()
        let old = try XCTUnwrap(handoffs.first)

        try audio.apply(.init(start: 0, end: 1, text: "open Maps", isFinal: true))
        coordinator.record(audio)
        coordinator.update("open Maps", final: false)
        await coordinator.waitForPending()
        let latest = try XCTUnwrap(handoffs.last)

        XCTAssertFalse(coordinator.consume(old, wordRange: 0..<2))
        XCTAssertTrue(coordinator.consume(latest, wordRange: 0..<2))
        XCTAssertFalse(coordinator.consume(latest, wordRange: 0..<2))
        XCTAssertEqual(handoffs.map(\.transcript), ["open Notes", "open Maps"])
        XCTAssertEqual(latest.captureID, captureID)
        XCTAssertEqual(latest.revision, audio.revision)
    }

    func testStableFirstRequestDoesNotStarveBehindGrowingIndependentSpeech() async throws {
        var release: CheckedContinuation<Void, Never>?
        var handoffs: [TranscriptHandoff] = []
        var coordinator: ContinuousIntentCoordinator!
        coordinator = ContinuousIntentCoordinator(submit: { handoff in
            handoffs.append(handoff)
            if handoffs.count == 1 {
                await withCheckedContinuation { release = $0 }
                XCTAssertTrue(coordinator.consume(handoff, wordRange: 0..<2), "A boundary inside the judged transcript survives a later suffix")
            }
        })
        coordinator.begin()
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 1, text: "open Notes then search", isFinal: true))
        coordinator.record(audio)
        coordinator.update(audio.text, final: false)
        for _ in 0..<100 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)

        try audio.apply(.init(start: 1, end: 2, text: " for cats", isFinal: false))
        coordinator.record(audio)
        coordinator.update(audio.text, final: false)
        release?.resume()
        try await Task.sleep(for: .milliseconds(10))

        await coordinator.waitForPending()
        XCTAssertEqual(handoffs.map(\.pendingWordStart), [0, 2])
        XCTAssertEqual(handoffs.last?.transcript, "open Notes then search for cats")
    }

    func testAppendedConditionRejectsOldEdgeDecisionAndRejudgesWholeRequest() async throws {
        let started = expectation(description: "First decision pending")
        let rejudged = expectation(description: "Updated request handed off")
        var release: CheckedContinuation<Void, Never>?
        var handoffs: [TranscriptHandoff] = []
        var coordinator: ContinuousIntentCoordinator!
        coordinator = ContinuousIntentCoordinator(submit: { handoff in
            handoffs.append(handoff)
            if handoffs.count == 1 {
                await withCheckedContinuation { release = $0; started.fulfill() }
                XCTAssertFalse(coordinator.consume(handoff, wordRange: 0..<2))
            } else {
                coordinator.report(handoff, outcome: "incomplete", message: "Conditional request")
                rejudged.fulfill()
            }
        })
        coordinator.begin()
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 1, text: "open Notes", isFinal: true))
        coordinator.record(audio)
        coordinator.update(audio.text, final: false)
        await fulfillment(of: [started], timeout: 1)

        try audio.apply(.init(start: 1, end: 2, text: " if I ask later", isFinal: true))
        coordinator.record(audio)
        coordinator.update(audio.text, final: true)
        release?.resume()
        await fulfillment(of: [rejudged], timeout: 1)
        await coordinator.waitForPending()

        XCTAssertEqual(handoffs.map(\.pendingWordStart), [0, 0])
        XCTAssertEqual(handoffs.last?.transcript, "open Notes if I ask later")
        XCTAssertEqual(coordinator.remainder, "open Notes if I ask later")
        XCTAssertFalse(coordinator.busy)
    }

    func testNonConsumingDecisionProcessesCoalescedFinalInputWithoutRetryingUnchangedInput() async throws {
        for outcome in ["incomplete", "clarification", "dictationWaitingForFinal"] {
            let started = expectation(description: "First decision pending: \(outcome)")
            let rejudged = expectation(description: "Final input handed off: \(outcome)")
            var release: CheckedContinuation<Void, Never>?
            var handoffs: [TranscriptHandoff] = []
            var coordinator: ContinuousIntentCoordinator!
            coordinator = ContinuousIntentCoordinator(submit: { handoff in
                handoffs.append(handoff)
                if handoffs.count == 1 {
                    await withCheckedContinuation { release = $0; started.fulfill() }
                } else { rejudged.fulfill() }
                coordinator.report(handoff, outcome: outcome, message: "Waiting")
            })
            coordinator.begin()
            var audio = RangedTranscript()
            try audio.apply(.init(start: 0, end: 1, text: "search for", isFinal: true))
            coordinator.record(audio)
            coordinator.update(audio.text, final: false)
            await fulfillment(of: [started], timeout: 1)

            try audio.apply(.init(start: 1, end: 2, text: " cats", isFinal: true))
            coordinator.record(audio)
            coordinator.update(audio.text, final: false)
            coordinator.update(audio.text, final: true)
            release?.resume()
            await fulfillment(of: [rejudged], timeout: 1)
            await coordinator.waitForPending()
            coordinator.update(audio.text, final: true)
            await coordinator.waitForPending()

            XCTAssertEqual(handoffs.map(\.transcript), ["search for", "search for cats"])
            XCTAssertEqual(handoffs.map(\.final), [false, true])
            XCTAssertEqual(handoffs.map(\.pendingWordStart), [0, 0])
            XCTAssertEqual(coordinator.remainder, "search for cats")
            XCTAssertFalse(coordinator.busy)
        }
    }

    func testProvisionalIgnoredTailRemainsRevisable() async throws {
        var handoffs: [TranscriptHandoff] = []
        var coordinator: ContinuousIntentCoordinator!
        coordinator = ContinuousIntentCoordinator(submit: { handoff in
            handoffs.append(handoff)
            if handoffs.count == 1 {
                _ = coordinator.consume(handoff, wordRange: 0..<1) // Jev selected the provisional filler as ignorable.
            }
        })
        coordinator.begin()
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 1, text: "uh", isFinal: false))
        coordinator.record(audio)
        coordinator.update("uh", final: false)
        await coordinator.waitForPending()
        XCTAssertEqual(coordinator.remainder, "uh", "An unstable ignored tail must not enter the consumed ledger")

        try audio.apply(.init(start: 0, end: 1, text: "open Notes", isFinal: true))
        coordinator.record(audio)
        coordinator.update("open Notes", final: false)
        await coordinator.waitForPending()

        XCTAssertNil(coordinator.error)
        let latest = try XCTUnwrap(handoffs.last)
        XCTAssertEqual(latest.transcript, "open Notes")
        XCTAssertTrue(coordinator.consume(latest, wordRange: 0..<2))
    }

    func testOldCaptureHandoffCannotBeAcceptedAfterNextHoldBegins() async throws {
        var handoffs: [TranscriptHandoff] = []
        let coordinator = ContinuousIntentCoordinator(submit: { handoffs.append($0) })
        coordinator.begin()
        coordinator.update("open Notes", final: true)
        await coordinator.waitForPending()
        let old = try XCTUnwrap(handoffs.first)

        coordinator.begin()
        coordinator.update("open Maps", final: true)
        await coordinator.waitForPending()
        let current = try XCTUnwrap(handoffs.last)

        XCTAssertFalse(coordinator.consume(old, wordRange: 0..<2))
        XCTAssertTrue(coordinator.consume(current, wordRange: 0..<2))
        XCTAssertEqual(current.transcript, "open Maps")
    }

    func testCancellationInvalidatesPendingHandoffCallback() async throws {
        var release: CheckedContinuation<Void, Never>?
        var delivered: [TranscriptHandoff] = []
        let coordinator = ContinuousIntentCoordinator(submit: { handoff in
            await withCheckedContinuation { release = $0 }
            try Task.checkCancellation()
            delivered.append(handoff)
        })
        coordinator.begin()
        coordinator.update("open Notes", final: true)
        for _ in 0..<100 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)

        coordinator.cancel()
        release?.resume()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(delivered.isEmpty)
    }
}
