import XCTest
@testable import JevVoiceCore

final class JevSpeechIntentTests: XCTestCase {
    func testLiteralPayloadCopiesOneExactQuotedSpanWithoutJevBoundaryChoices() {
        let result = JevSpeechIntent.literalPayload(in: "Type exactly \"Copper lantern!\" into Notes.")
        XCTAssertEqual(result?.text, "Copper lantern!")
        XCTAssertEqual(result?.controlInstruction, "Type exactly [literal text] into Notes.")
    }

    func testLiteralPayloadCopiesTheWholeExplicitDictationSuffixAndMasksIt() {
        let result = JevSpeechIntent.literalPayload(in: "Please dictate open Notes and stop all")
        XCTAssertEqual(result?.text, "open Notes and stop all")
        XCTAssertEqual(result?.controlInstruction, "Please dictate [literal text]")
    }

    func testExplicitDictationKeepsQuotedPhrasesInsideTheWholeLiteralSuffix() {
        let result = JevSpeechIntent.literalPayload(in: #"Dictate she said "hello" yesterday, then "goodbye"."#)
        XCTAssertEqual(result?.text, #"she said "hello" yesterday, then "goodbye"."#)
        XCTAssertEqual(result?.controlInstruction, "Dictate [literal text]")
    }

    func testQuotedDestinationIsNotMistakenForTextToInsert() {
        XCTAssertNil(JevSpeechIntent.literalPayload(in: #"Type hello into "Draft"."#))
    }

    func testQuotedPayloadRemainsBoundWhenDestinationIsAlsoQuoted() {
        let result = JevSpeechIntent.literalPayload(in: #"Type exactly "hello" into "Draft"."#)
        XCTAssertEqual(result?.text, "hello")
        XCTAssertEqual(result?.controlInstruction, #"Type exactly [literal text] into "Draft"."#)
    }

    func testLiteralPayloadRefusesAmbiguousAndUnboundedSource() {
        XCTAssertNil(JevSpeechIntent.literalPayload(in: "Type \"one\" then \"two\" into Notes"))
        XCTAssertNil(JevSpeechIntent.literalPayload(in: "Put these words into Notes"))
        XCTAssertNil(JevSpeechIntent.literalPayload(in: "Dictate   "))
    }

    func testLiteralPayloadRefusesUnquotedTypeOrWriteWithPossibleControlInstructions() {
        XCTAssertNil(JevSpeechIntent.literalPayload(in: "Type Open Messages into Notes"))
        XCTAssertNil(JevSpeechIntent.literalPayload(in: "Write the note and then close the window"))
    }

    func testActionPayloadCanExcludeCommandSeparatorWithoutInventingText() async throws {
        var calls = 0
        let model = JevSpeechIntent(evaluate: { state, questions in
            calls += 1
            if let question = questions["payload"] {
                guard case let .choice(_, choices) = question,
                      let choice = choices.first(where: { $0.value == "copper lantern" })?.key else {
                    throw DriverConnectionError.malformed
                }
                XCTAssertEqual(state["selected_source"], .string("copper lantern,"))
                return ["payload": .choice(choice: choice, confidence: 1, probabilities: [:])]
            }
            return ["start": .choice(choice: "2", confidence: 1, probabilities: [:]),
                    "end": .choice(choice: "4", confidence: 1, probabilities: [:])]
        })
        let text = try await model.textPayload(request: "search for copper lantern, then open the guide", purpose: "Search query")
        XCTAssertEqual(text, "copper lantern")
        XCTAssertEqual(calls, 2)
    }

    func testActionPayloadRetainsPunctuationWhenItIsContent() async throws {
        let model = JevSpeechIntent(evaluate: { _, questions in
            if let question = questions["payload"] {
                guard case let .choice(_, choices) = question,
                      let choice = choices.first(where: { $0.value == "Hello!" })?.key else { throw DriverConnectionError.malformed }
                return ["payload": .choice(choice: choice, confidence: 1, probabilities: [:])]
            }
            return ["start": .choice(choice: "1", confidence: 1, probabilities: [:]),
                    "end": .choice(choice: "2", confidence: 1, probabilities: [:])]
        })
        let text = try await model.textPayload(request: "type Hello!", purpose: "Exact text including the exclamation mark")
        XCTAssertEqual(text, "Hello!")
    }
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
            "end": .choice(choice: "3", confidence: 1, probabilities: [:])
        ] })
        let result = try await model.extractText(request: "type blue\nnotebook into Notes", purpose: "literal content")
        XCTAssertEqual(result.text, "blue\nnotebook")
        XCTAssertEqual(result.controlInstruction, "type [literal text] into Notes")
    }

}
