import XCTest
import AVFoundation
@testable import JevVoice

final class MicrophoneAudioGateTests: XCTestCase {
    private func buffer(_ value: Float, frames: AVAudioFrameCount = 160) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: value, count: Int(frames))
        return buffer
    }
    func testIdleAndReleasedAudioNeverEntersHoldAndConsecutiveHoldsAreIndependent() async throws {
        let gate = MicrophoneAudioGate()
        let samples = try buffer(0.25)
        let time = AVAudioTime(hostTime: 100)
        gate.append(samples, at: time)
        let first = try ConvertedAudioFeed(input: samples.format, output: samples.format)
        gate.open(first, at: 100)
        gate.append(samples, at: time)
        gate.close()?.finish()
        gate.append(samples, at: time)
        var frames = 0
        for try await input in first.stream { frames += Int(input.frameLength) }
        XCTAssertEqual(frames, 160)
        let second = try ConvertedAudioFeed(input: samples.format, output: samples.format)
        gate.open(second, at: 100)
        gate.append(samples, at: time)
        gate.close()?.finish()
        var secondFrames = 0
        for try await input in second.stream { secondFrames += Int(input.frameLength) }
        XCTAssertEqual(secondFrames, 160)
    }
    func testBufferStraddlingFnPressExcludesAudioBeforePress() async throws {
        let gate = MicrophoneAudioGate(), samples = try buffer(0.5, frames: 1600)
        let feed = try ConvertedAudioFeed(input: samples.format, output: samples.format)
        let origin = AVAudioTime.hostTime(forSeconds: 10)
        gate.open(feed, at: origin + AVAudioTime.hostTime(forSeconds: 0.05))
        gate.append(samples, at: AVAudioTime(hostTime: origin))
        gate.close()?.finish()
        var frames = 0
        for try await input in feed.stream { frames += Int(input.frameLength) }
        XCTAssertEqual(frames, 800, accuracy: 1)
    }
}
