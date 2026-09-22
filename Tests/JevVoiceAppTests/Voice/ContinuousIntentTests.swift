import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class ContinuousIntentTests: XCTestCase {
    func testDictatedCorrectionWaitsForReleaseAndRetainsLiteralContinuation() async throws {
        var requests: [SpeechIntent] = []
        var calls = 0
        let model = JevSpeechIntent(evaluate: { state, _ in
            calls += 1
            return Dictionary(uniqueKeysWithValues: [
                "kind": "correction", "mode": "dictate", "purpose": "request",
                "extent": "whole", "polarity": "notProhibited",
                "boundary": String(state["pending_speech"]!.string!.split(separator: " ").count)
            ].map { ($0.key, Answer.choice(choice: $0.value, confidence: 1, probabilities: [:])) })
        })
        let coordinator = ContinuousIntentCoordinator(interpret: { try await model.understand(words: $0, final: $1, context: $2) }, submit: { requests.append($0) })
        coordinator.begin()
        let prefix = "Actually, dictate blue notebook"
        coordinator.record(.init(start: 0, end: 1, text: prefix, isFinal: true))
        coordinator.update(prefix, final: false)
        await coordinator.waitForPending()
        XCTAssertTrue(requests.isEmpty, "Literal replacements must not hand off while held")
        let initialCalls = calls
        let complete = prefix + " stop all"
        coordinator.record(.init(start: 1, end: 2, text: " stop all", isFinal: true))
        coordinator.update(complete, final: false)
        await coordinator.waitForPending()
        XCTAssertTrue(requests.isEmpty)
        coordinator.update(complete, final: true)
        await coordinator.waitForPending()
        XCTAssertEqual(requests.map(\.kind), [.correction])
        XCTAssertEqual(requests.map(\.text), [complete])
        XCTAssertEqual(calls, initialCalls, "Dictation continuation must remain literal without reclassification")
    }

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

extension ContinuousIntentTests {
    func testVolatileCandidateWaitsForStabilityAndSameTextFinalizationDispatches() async throws {
        var requests: [SpeechIntent] = []
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in
            SpeechIntent(kind: .command, count: words.count, text: words.joined(separator: " "))
        }, submit: { requests.append($0) })
        c.begin()
        c.record(.init(start: 0, end: 1, text: "open Notes", isFinal: false))
        c.update("open Notes", final: false)
        for _ in 0..<100 where c.outcome != "candidate" { await Task.yield() }
        XCTAssertTrue(requests.isEmpty, "A fresh volatile candidate is not a handoff")
        c.record(.init(start: 0, end: 1, text: "open Notes", isFinal: true))
        c.update("open Notes", final: false)
        await c.waitForPending()
        XCTAssertEqual(requests.map(\.text), ["open Notes"])
        XCTAssertEqual(requests.first?.provenance?.revision, 2)
    }

    func testVolatileApplicationRepairDoesNotSubmitOldApplication() async throws {
        var requests: [String] = []
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in
            SpeechIntent(kind: .command, count: words.count, text: words.joined(separator: " "))
        }, submit: { requests.append($0.text) })
        c.begin()
        c.record(.init(start: 0, end: 1, text: "open Notes", isFinal: false))
        c.update("open Notes", final: false)
        for _ in 0..<100 where c.outcome != "candidate" { await Task.yield() }
        c.record(.init(start: 0, end: 1, text: "open Maps", isFinal: true))
        c.update("open Maps", final: false); await c.waitForPending()
        XCTAssertEqual(requests, ["open Maps"])
    }
}

extension ContinuousIntentTests {
    func testDuplicateRevisionsAndIntentionalRepeatHaveDifferentSpans() async throws {
        var submitted: [SpeechIntent] = []
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in .init(kind: .command, count: words.count, text: "") }, submit: { submitted.append($0) })
        c.begin()
        let first = SpeechRevision(start: 0, end: 1, text: "open Notes", isFinal: true)
        c.record(first); c.update("open Notes", final: false); await c.waitForPending()
        c.record(first); c.update("open Notes", final: false); await c.waitForPending()
        c.record(.init(start: 1, end: 2, text: " open Notes", isFinal: true))
        c.update("open Notes open Notes", final: false); await c.waitForPending()
        c.update("open Notes open Notes", final: true); await c.waitForPending()
        XCTAssertEqual(submitted.map(\.text), ["open Notes", "open Notes"])
        XCTAssertEqual(submitted.compactMap { $0.provenance?.wordStart }, [0, 2])
    }
    func testReleaseDuringPendingJudgmentRechecksAndPreservesParagraphs() async throws {
        var release: CheckedContinuation<Void, Never>?, calls = 0
        var submitted: [String] = []
        let c = ContinuousIntentCoordinator(decide: { words, final, _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            return final ? .init(kind: .textEntry, count: words.count, text: "") : nil
        }, submit: { submitted.append($0.text) })
        c.begin(); c.update("type café\n\n👩🏽‍💻", final: false)
        for _ in 0..<100 where release == nil { await Task.yield() }
        c.update("type café\n\n👩🏽‍💻", final: true); release?.resume()
        await c.waitForPending()
        XCTAssertEqual(submitted, ["type café\n\n👩🏽‍💻"])
        XCTAssertEqual(calls, 2)
    }
    func testUncertainSubmissionCannotReplayAfterServiceFailure() async throws {
        var submissions = 0
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in .init(kind: .command, count: words.count, text: "") }, submit: { _ in
            submissions += 1; throw URLError(.networkConnectionLost)
        })
        c.begin(); c.update("open Notes", final: true); await c.waitForPending()
        c.update("open Notes", final: true); await c.waitForPending()
        XCTAssertEqual(submissions, 1)
        XCTAssertTrue(c.remainder.isEmpty)
        XCTAssertNotNil(c.error)
    }
    func testIncompleteAndServiceFailureRetainPendingSpeech() async throws {
        for service in [false, true] {
            let c = ContinuousIntentCoordinator(interpret: { _, _, _ in
                if service { throw URLError(.notConnectedToInternet) }
                return .incomplete("What would you like to search for?")
            }, submit: { _ in XCTFail("No handoff allowed") })
            c.begin(); c.update("search for", final: true); await c.waitForPending()
            XCTAssertEqual(c.remainder, "search for")
            XCTAssertEqual(c.outcome, service ? "failure" : "incomplete")
            XCTAssertTrue(c.error?.contains(service ? "Voice interpretation failed" : "search for") == true)
        }
    }
    func testOldCaptureResponseDoesNotReviveAfterNewHold() async throws {
        var release: CheckedContinuation<Void, Never>?, calls = 0
        var submitted: [String] = []
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            return .init(kind: .command, count: words.count, text: "")
        }, submit: { submitted.append($0.text) })
        c.begin(); c.update("open Notes", final: true)
        for _ in 0..<100 where release == nil { await Task.yield() }
        c.begin(); c.update("open Maps", final: true)
        release?.resume(); await c.waitForPending()
        XCTAssertEqual(submitted, ["open Maps"])
    }
}

extension ContinuousIntentTests {
    func testStableVolatileCompleteRequestCanHandoffBeforeRelease() async throws {
        var requests: [String] = []
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in .init(kind: .command, count: words.count, text: "") }, submit: { requests.append($0.text) })
        c.begin(); c.record(.init(start: 0, end: 1, text: "open Calculator", isFinal: false))
        c.update("open Calculator", final: false); await c.waitForPending()
        XCTAssertEqual(requests, ["open Calculator"], "Recognition finality must not become a release-only handoff gate")
    }
}

extension ContinuousIntentTests {
    func testNegatedPrefixRemainsInGrowingSpeechUntilRelease() async throws {
        for recognitionFinal in [false, true] {
            var submissions: [String] = []
            let model = JevSpeechIntent(evaluate: { state, questions in
                let text = try XCTUnwrap(state["pending_speech"]?.string)
                let values = ["polarity": text.hasPrefix("Don't") ? "prohibited" : "notProhibited",
                              "purpose": "request", "kind": "command", "mode": "control", "extent": "whole"]
                return try questions.reduce(into: [:]) { answers, question in
                    let value = try XCTUnwrap(values[question.key])
                    answers[question.key] = .choice(choice: value, confidence: 1, probabilities: [:])
                }
            })
            let c = ContinuousIntentCoordinator(interpret: {
                try await model.understand(words: $0, final: $1, context: $2)
            }, submit: { submissions.append($0.text) })
            c.begin()
            c.record(.init(start: 0, end: 1, text: "Don't", isFinal: recognitionFinal))
            c.update("Don't", final: false); await c.waitForPending()
            XCTAssertEqual(c.remainder, "Don't", "Recognition stability must not consume the governing negation")
            c.record(.init(start: 1, end: 2, text: " open Safari", isFinal: recognitionFinal))
            c.update("Don't open Safari", final: false); await c.waitForPending()
            XCTAssertTrue(submissions.isEmpty)
            XCTAssertEqual(c.remainder, "Don't open Safari")
            c.update("Don't open Safari", final: true); await c.waitForPending()
            XCTAssertTrue(submissions.isEmpty)
            XCTAssertTrue(c.remainder.isEmpty)
            XCTAssertEqual(c.outcome, "noRequest")
            XCTAssertFalse(c.busy)
            XCTAssertNil(c.error)
        }
    }

    func testIgnoredTailCanBeRevisedIntoARequestWithoutCommittedRevisionFailure() async {
        var submissions: [String] = []
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in
            .init(kind: words == ["uh"] ? .ignore : .command, count: words.count, text: "")
        }, submit: { submissions.append($0.text) })
        c.begin(); c.update("uh", final: false); await c.waitForPending()
        c.update("open Notes", final: true); await c.waitForPending()
        XCTAssertEqual(submissions, ["open Notes"])
        XCTAssertNil(c.error)
    }

    func testBoundedIgnoredPrefixStillAllowsFollowingCommandBeforeRelease() async {
        var submissions: [String] = []
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in
            if words.first == "thanks" { return .init(kind: .ignore, count: 1, text: "") }
            return .init(kind: .command, count: words.count, text: "")
        }, submit: { submissions.append($0.text) })
        c.begin(); c.update("thanks open Notes", final: false); await c.waitForPending()
        XCTAssertEqual(submissions, ["open Notes"])
        c.update("thanks open Notes", final: true); await c.waitForPending()
        XCTAssertEqual(submissions, ["open Notes"])
    }

    func testStableFirstRequestDoesNotStarveBehindGrowingIndependentSpeech() async throws {
        var release: CheckedContinuation<Void, Never>?, calls = 0
        var submissions: [String] = []
        let c = ContinuousIntentCoordinator(decide: { words, _, _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 }; return .init(kind: .command, count: 2, text: "open Notes") }
            return nil
        }, submit: { submissions.append($0.text) })
        c.begin()
        c.record(.init(start: 0, end: 1, text: "open Notes", isFinal: true))
        c.record(.init(start: 1, end: 2, text: " then search", isFinal: false))
        c.update("open Notes then search", final: false)
        for _ in 0..<100 where release == nil { await Task.yield() }
        c.record(.init(start: 1, end: 3, text: " then search for hiking", isFinal: false))
        c.update("open Notes then search for hiking", final: false)
        release?.resume(); await c.waitForPending()
        XCTAssertEqual(submissions, ["open Notes"])
        XCTAssertEqual(c.remainder, "then search for hiking")
    }
}
