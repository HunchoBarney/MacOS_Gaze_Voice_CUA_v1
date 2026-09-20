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
            "end": .choice(choice: "3", confidence: 1, probabilities: [:])
        ] })
        let result = try await model.extractText(request: "type blue\nnotebook into Notes", purpose: "literal content")
        XCTAssertEqual(result.text, "blue\nnotebook")
        XCTAssertEqual(result.controlInstruction, "type [literal text] into Notes")
    }

}
