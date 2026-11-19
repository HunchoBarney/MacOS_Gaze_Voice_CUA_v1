import AVFoundation
import XCTest
@testable import JevVoice

final class ConversationSegmenterBoundaryTests: XCTestCase {
    @MainActor
    func testUnconfiguredLocalCaptureRefusesBeforeOpeningSession() async throws {
        let conversation = ConversationSession()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let feed = try ConvertedAudioFeed(input: format, output: format)
        defer { feed.finish() }
        do {
            try await conversation.prepare()
            XCTFail("Preparation without a diagnostic segmenter must refuse")
        } catch let error as VoiceError {
            XCTAssertEqual(error.message, "No diagnostic conversation segmenter was supplied.")
        }
        do {
            try await conversation.start(feed: feed, session: UUID())
            XCTFail("Local capture without a diagnostic segmenter must refuse")
        } catch let error as VoiceError {
            XCTAssertEqual(error.message, "No diagnostic conversation segmenter was supplied.")
        }
        XCTAssertNil(conversation.id)
    }

    @MainActor
    func testInjectedSegmenterStillRejectsAnUnpinnedResource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("resource.json"))
        let capture = ConversationCapture(modelDirectory: directory)
        let conversation = ConversationSession(capture: capture)
        do {
            try await conversation.prepare()
            XCTFail("An invalid resource must not enter model preparation")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The bundled voice model is missing or damaged. Please reinstall Jev Voice.")
        }
        XCTAssertFalse(capture.prepared)
        XCTAssertNil(conversation.id)
    }
}
