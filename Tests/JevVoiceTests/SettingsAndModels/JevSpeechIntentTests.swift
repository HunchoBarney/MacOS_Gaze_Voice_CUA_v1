import XCTest
@testable import JevVoiceCore

final class JevSpeechIntentTests: XCTestCase {
    func testExactSpanSelectionIncludesMiddleWordsAndUnicode() throws {
        let words = ["please", "type", "café", "👩🏽‍💻", "now"]
        XCTAssertEqual(try SpeechSpan.copy(words: words, start: 2, end: 4), "café 👩🏽‍💻")
        XCTAssertThrowsError(try SpeechSpan.copy(words: words, start: 4, end: 2))
        XCTAssertThrowsError(try SpeechSpan.copy(words: words, start: -1, end: 2))
    }
    func testInvalidModelChoiceRejected() throws {
        let malformed = Answer.choice(choice: "invented", confidence: 1, probabilities: [:])
        XCTAssertThrowsError(try JevSelection.read(malformed, allowed: ["wait", "command"]))
        let nan = Answer.choice(choice: "command", confidence: .nan, probabilities: [:])
        XCTAssertThrowsError(try JevSelection.read(nan, allowed: ["command"]))
    }
    func testExtractedLiteralPreservesExplicitDestinationAndWhitespace() async throws {
        let model = JevSpeechIntent(evaluate: { _, _ in [
            "start": .choice(choice: "1", confidence: 1, probabilities: [:]),
            "end": .choice(choice: "2", confidence: 1, probabilities: [:])
        ] })
        let result = try await model.extractText(request: "type blue\nnotebook into Notes", purpose: "literal content")
        XCTAssertEqual(result.text, "blue\nnotebook")
        XCTAssertEqual(result.controlInstruction, "type [literal text] into Notes")
    }

}

extension JevSpeechIntentTests {
    func testLongRequestDoesNotFailAt128Words() async throws {
        for count in [127, 128, 129, 300] {
            let words = ["type"] + Array(repeating: "café", count: count - 1)
            let model = JevSpeechIntent(evaluate: { _, _ in [
                "boundaryGroup": .choice(choice: String((count - 1) / 200), confidence: 1, probabilities: [:]),
                "startGroup": .choice(choice: "0", confidence: 1, probabilities: [:]),
                "endGroup": .choice(choice: String((count - 1) / 200), confidence: 1, probabilities: [:]),
                "boundary": .choice(choice: String(count), confidence: 1, probabilities: [:]),
                "extent": .choice(choice: "refine", confidence: 1, probabilities: [:]),
                "completeness": .choice(choice: "complete", confidence: 1, probabilities: [:]),
                "polarity": .choice(choice: "notProhibited", confidence: 1, probabilities: [:]),
                "purpose": .choice(choice: "request", confidence: 1, probabilities: [:]),
                "mode": .choice(choice: "control", confidence: 1, probabilities: [:]),
                "kind": .choice(choice: "textEntry", confidence: 1, probabilities: [:]),
                "start": .choice(choice: "1", confidence: 1, probabilities: [:]),
                "end": .choice(choice: String(count - 1), confidence: 1, probabilities: [:])
            ] })
            let intent = try await model.next(words: words, final: true, context: .object([:]))
            XCTAssertEqual(intent?.count, count)
            let extracted = try await model.extractText(request: words.joined(separator: "\n"), purpose: "literal")
            XCTAssertEqual(extracted.text, words.dropFirst().joined(separator: "\n"))
        }
    }
    func testTypeJudgmentUsesSelectedSpanWhenBoundaryIsShorter() async throws {
        var states: [JSONValue] = []
        let model = JevSpeechIntent(evaluate: { state, _ in
            states.append(state)
            return ["boundary": .choice(choice: "2", confidence: 1, probabilities: [:]),
                    "extent": .choice(choice: "refine", confidence: 1, probabilities: [:]),
                "completeness": .choice(choice: "complete", confidence: 1, probabilities: [:]),
                "polarity": .choice(choice: "notProhibited", confidence: 1, probabilities: [:]),
                "purpose": .choice(choice: "request", confidence: 1, probabilities: [:]),
                "mode": .choice(choice: "control", confidence: 1, probabilities: [:]),
                "kind": .choice(choice: "command", confidence: 1, probabilities: [:])]
        })
        _ = try await model.next(words: ["open", "Notes", "then", "stop"], final: true, context: .object([:]))
        XCTAssertEqual(states.count, 3, "A kind inferred from the whole input cannot classify a shorter selected span")
        XCTAssertEqual(states.last?["pending_speech"]?.string, "open Notes")
    }
}

extension JevSpeechIntentTests {
    func testCompleteWholeCommandUsesOneBatchedJudgment() async throws {
        var calls = 0
        let model = JevSpeechIntent(evaluate: { _, questions in
            calls += 1
            XCTAssertNil(questions["boundary"], "A verified whole candidate needs no separate span selection")
            return ["kind": .choice(choice: "command", confidence: 1, probabilities: [:]),
                    "mode": .choice(choice: "control", confidence: 1, probabilities: [:]),
                    "completeness": .choice(choice: "complete", confidence: 1, probabilities: [:]),
                "polarity": .choice(choice: "notProhibited", confidence: 1, probabilities: [:]),
                "purpose": .choice(choice: "request", confidence: 1, probabilities: [:]),
                    "extent": .choice(choice: "whole", confidence: 1, probabilities: [:])]
        })
        let intent = try await model.next(words: ["Please", "open", "Calendar"], final: false, context: .object([:]))
        XCTAssertEqual(intent?.text, "Please open Calendar")
        XCTAssertEqual(calls, 1)
    }
}

extension JevSpeechIntentTests {
    @MainActor
    func testCancelledJudgmentDoesNotStartDependentModelCalls() async throws {
        var calls = 0, release: CheckedContinuation<Void, Never>?
        let model = JevSpeechIntent(evaluate: { _, _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            return ["kind": .choice(choice: "command", confidence: 1, probabilities: [:]),
                    "mode": .choice(choice: "control", confidence: 1, probabilities: [:]),
                    "completeness": .choice(choice: "complete", confidence: 1, probabilities: [:]),
                "polarity": .choice(choice: "notProhibited", confidence: 1, probabilities: [:]),
                "purpose": .choice(choice: "request", confidence: 1, probabilities: [:]),
                    "extent": .choice(choice: "refine", confidence: 1, probabilities: [:]),
                    "boundary": .choice(choice: "2", confidence: 1, probabilities: [:])]
        })
        let task = Task { try await model.next(words: ["open", "Notes"], final: true, context: .object([:])) }
        for _ in 0..<100 where release == nil { await Task.yield() }
        task.cancel(); release?.resume()
        do { _ = try await task.value; XCTFail("Cancelled interpretation returned a candidate") }
        catch is CancellationError { }
        XCTAssertEqual(calls, 1)
    }
    func testBeyondBoundRetainsAnExplicitLimitationWithoutModelCalls() async throws {
        let model = JevSpeechIntent(evaluate: { _, _ in XCTFail("Over-limit input must not be silently truncated for inference"); return [:] })
        let result = try await model.understand(words: Array(repeating: "word", count: JevSpeechIntent.maximumWords + 1), final: true, context: .object([:]))
        guard case .limitation(let reason) = result else { return XCTFail("Expected retained-input limitation") }
        XCTAssertTrue(reason.contains("retained"))
    }
}

extension JevSpeechIntentTests {
    func testQuotedModeAndCancellationOperatorsAreContent() async throws {
        let model = JevSpeechIntent(evaluate: { _, _ in XCTFail("An entirely quoted utterance is not an explicit operator"); return [:] })
        for text in ["\"stop all\"", "“stop all.”", "‘dictate stop all’", "'stop all'", "'dictate stop all'"] {
            let outcome = try await model.understand(words: text.split(whereSeparator: \.isWhitespace).map(String.init), final: true, context: .object([:]))
            guard case .noRequest = outcome else { XCTFail("Quoted operator became control: \(text)"); continue }
        }
    }

    func testUnclosedSingleQuotedOperatorsDoNotBypassSemanticJudgment() async throws {
        enum JudgmentRequired: Error { case reached }
        let model = JevSpeechIntent(evaluate: { _, _ in throw JudgmentRequired.reached })
        for text in ["'stop all", "'dictate hello"] {
            do {
                _ = try await model.understand(words: text.split(whereSeparator: \.isWhitespace).map(String.init), final: false, context: .object([:]))
                XCTFail("An unfinished quotation took an unconditional operator shortcut: \(text)")
            } catch JudgmentRequired.reached { }
        }
    }
}

extension JevSpeechIntentTests {
    func testUnresolvedConditionCannotHandoffOnHoldOrRelease() async throws {
        let model = JevSpeechIntent(evaluate: { _, _ in
            Dictionary(uniqueKeysWithValues: [
                "kind": "command", "mode": "control", "purpose": "request",
                "polarity": "notProhibited", "extent": "conditional"
            ].map { ($0.key, Answer.choice(choice: $0.value, confidence: 1, probabilities: [:])) })
        })
        for final in [false, true] {
            let outcome = try await model.understand(words: "Open Safari if I say go".split(separator: " ").map(String.init), final: final, context: .object([:]))
            guard case .incomplete = outcome else { return XCTFail("An unresolved condition must remain pending, including after release") }
        }
    }

    func testPurposeExtractionDoesNotApplyDictationShortcut() async throws {
        let model = JevSpeechIntent(evaluate: { _, _ in [
            "start": .choice(choice: "0", confidence: 1, probabilities: [:]),
            "end": .choice(choice: "4", confidence: 1, probabilities: [:])
        ] })
        let request = "Dictate blue notebook into Notes"
        let result = try await model.textPayload(request: request, purpose: "The complete replacement computer request")
        XCTAssertEqual(result, request, "A replacement command must retain its governing verb and destination")
        let literal = try await model.extractText(request: request, purpose: "literal content")
        XCTAssertEqual(literal.text, "blue notebook into Notes", "Explicit dictate still makes the remaining hold literal")
    }

    func testReplacementExtractionPreservesOperationDestinationAndWhitespace() async throws {
        let model = JevSpeechIntent(evaluate: { _, _ in [
            "start": .choice(choice: "1", confidence: 1, probabilities: [:]),
            "end": .choice(choice: "5", confidence: 1, probabilities: [:])
        ] })
        let result = try await model.textPayload(request: "Actually, write café\nhello into Notes instead", purpose: "The complete replacement computer request, excluding the retraction of the previous request")
        XCTAssertEqual(result, "write café\nhello into Notes")
    }
}
