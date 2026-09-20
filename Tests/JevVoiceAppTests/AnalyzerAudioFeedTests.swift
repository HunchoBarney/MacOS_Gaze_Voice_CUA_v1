import XCTest
import AVFoundation
@testable import JevVoice

final class AnalyzerAudioFeedTests: XCTestCase {
    func testResamplingDrainsTailAndFinishesExactlyOnce() async throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let feed = try AnalyzerAudioFeed(input: input, output: output)
        for _ in 0..<48 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1000))
            buffer.frameLength = 1000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 1000)
            feed.append(buffer)
        }
        feed.finish(); feed.finish()
        var count = 0
        for try await sample in feed.stream { count += Int(sample.buffer.frameLength) }
        XCTAssertEqual(count, 16000, "The final resampler frames must reach the analyzer")
        let durations = feed.audioDurations()
        XCTAssertEqual(durations.input, 1, accuracy: 0.0001)
        XCTAssertEqual(durations.converted, 1, accuracy: 0.0001)
        XCTAssertEqual(durations.audible, 0, "Silent buffers must not be reported as audible input")
    }
    func testOverflowFailsInsteadOfSilentlyDroppingAudio() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let feed = try AnalyzerAudioFeed(input: format, output: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        for _ in 0..<140 { feed.append(buffer) }
        feed.finish()
        do {
            for try await _ in feed.stream { }
            XCTFail("Backpressure must fail, not lose speech silently")
        } catch { XCTAssertTrue(error.localizedDescription.contains("keep up")) }
    }
}
