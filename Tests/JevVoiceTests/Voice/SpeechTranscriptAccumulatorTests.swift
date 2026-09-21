import XCTest
@testable import JevVoiceCore

final class SpeechTranscriptAccumulatorTests: XCTestCase {
    func testObservedOnDevicePhraseResetsRetainEarlierSpeech() {
        var stream = SpeechTranscriptAccumulator()
        XCTAssertEqual(stream.update("Open text edit"), "Open text edit")
        XCTAssertEqual(stream.update("Open TextEdit", start: 0, end: 1.14), "Open TextEdit")
        XCTAssertEqual(stream.update("Create"), "Open TextEdit\nCreate")
        XCTAssertEqual(stream.update("Create a new document", start: 4.14, end: 5.61), "Open TextEdit\nCreate a new document")
        XCTAssertEqual(stream.update("Type the blue notebook"), "Open TextEdit\nCreate a new document\nType the blue notebook")
        XCTAssertEqual(stream.update("Type the blue notebook is on my desk", start: 8.64, end: 10.92, final: true), "Open TextEdit\nCreate a new document\nType the blue notebook is on my desk")
    }

    func testRevisionsCumulativeResultsAndRepeatedCommandsDoNotDuplicate() {
        var stream = SpeechTranscriptAccumulator()
        _ = stream.update("open Calendar")
        XCTAssertEqual(stream.update("open Calculator", start: 0, end: 1), "open Calculator")
        XCTAssertEqual(stream.update("open Calculator", start: 0, end: 1), "open Calculator")
        _ = stream.update("open")
        XCTAssertEqual(stream.update("open Calculator", start: 3, end: 4), "open Calculator\nopen Calculator")
        XCTAssertEqual(stream.update("open Calculator open Calculator", start: 0, end: 4, final: true), "open Calculator open Calculator")
    }

    func testLiteralDictationSurvivesPhraseResetAndEmptyFinal() {
        var stream = SpeechTranscriptAccumulator()
        _ = stream.update("Open TextEdit", start: 0, end: 1)
        _ = stream.update("Type hello", start: 2, end: 3)
        XCTAssertEqual(stream.update("and quit Spotify", start: 5, end: 6), "Open TextEdit\nType hello and quit Spotify")
        XCTAssertEqual(stream.update("", final: true), "Open TextEdit\nType hello and quit Spotify")
    }
}
