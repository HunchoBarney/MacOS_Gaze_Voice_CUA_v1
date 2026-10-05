import XCTest
import AVFoundation
@testable import JevVoice

final class DuplexRingBufferTests: XCTestCase {
    private func write(_ ring: DuplexRingBuffer, _ samples: [Float], channels: Int) -> Int {
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: samples.count / channels) }
    }
    private func read(_ ring: DuplexRingBuffer, frames: Int, channels: Int) -> ([Float], Int) {
        var out = [Float](repeating: -1, count: frames * channels)
        let got = out.withUnsafeMutableBufferPointer { ring.read($0.baseAddress!, frames: frames) }
        return (out, got)
    }

    func testWriteReadWraparoundPreservesFrameOrder() {
        let ring = DuplexRingBuffer(capacity: 8, channels: 1)
        XCTAssertEqual(write(ring, [0, 1, 2, 3, 4, 5], channels: 1), 6)
        let (first, gotFirst) = read(ring, frames: 4, channels: 1)
        XCTAssertEqual(gotFirst, 4)
        XCTAssertEqual(Array(first.prefix(4)), [0, 1, 2, 3])
        // head=4 tail=6 → writing 6 wraps the index arithmetic
        XCTAssertEqual(write(ring, [10, 11, 12, 13, 14, 15], channels: 1), 6)
        let (rest, gotRest) = read(ring, frames: 8, channels: 1)
        XCTAssertEqual(gotRest, 8)
        XCTAssertEqual(Array(rest.prefix(8)), [4, 5, 10, 11, 12, 13, 14, 15])
    }

    func testInterleavedFramesStayIntactAcrossWrap() {
        let ring = DuplexRingBuffer(capacity: 4, channels: 2)
        XCTAssertEqual(write(ring, [1, -1, 2, -2, 3, -3], channels: 2), 3)
        _ = read(ring, frames: 1, channels: 2)
        // free = 4 - (3 - 1) = 2 → this write wraps around index 0
        XCTAssertEqual(write(ring, [4, -4, 5, -5], channels: 2), 2)
        let (out, got) = read(ring, frames: 4, channels: 2)
        XCTAssertEqual(got, 4)
        XCTAssertEqual(Array(out.prefix(8)), [2, -2, 3, -3, 4, -4, 5, -5])
    }

    func testOverflowDropsNewFramesAndCountsThem() {
        let ring = DuplexRingBuffer(capacity: 8, channels: 1)
        XCTAssertEqual(write(ring, [Float](repeating: 1, count: 8), channels: 1), 8)
        XCTAssertEqual(write(ring, [Float](repeating: 2, count: 5), channels: 1), 0)
        XCTAssertEqual(ring.droppedFrames, 5)
        // Partial writes still land — only the tail over capacity drops.
        _ = read(ring, frames: 6, channels: 1)
        XCTAssertEqual(write(ring, [Float](repeating: 3, count: 9), channels: 1), 6)
        XCTAssertEqual(ring.droppedFrames, 8)
        XCTAssertEqual(ring.availableFrames, 8)
    }

    func testFlushEmptiesRingWithoutDisturbingLaterWrites() {
        let ring = DuplexRingBuffer(capacity: 8, channels: 1)
        _ = write(ring, [1, 2, 3, 4], channels: 1)
        ring.flush()
        XCTAssertEqual(ring.availableFrames, 0)
        let (_, got) = read(ring, frames: 4, channels: 1)
        XCTAssertEqual(got, 0)
        XCTAssertEqual(write(ring, [9, 9, 9], channels: 1), 3)
        let (out, gotAfter) = read(ring, frames: 8, channels: 1)
        XCTAssertEqual(gotAfter, 3)
        XCTAssertEqual(Array(out.prefix(3)), [9, 9, 9])
    }

    func testConsumedFramesCountsOnlyRealReads() {
        let ring = DuplexRingBuffer(capacity: 8, channels: 1)
        _ = write(ring, [Float](repeating: 1, count: 5), channels: 1)
        XCTAssertEqual(ring.consumedFrames, 0)
        let (_, got) = read(ring, frames: 8, channels: 1)
        XCTAssertEqual(got, 5, "an empty tail is the caller's zero-fill, not consumption")
        XCTAssertEqual(ring.consumedFrames, 5)
        _ = write(ring, [Float](repeating: 1, count: 2), channels: 1)
        _ = read(ring, frames: 2, channels: 1)
        XCTAssertEqual(ring.consumedFrames, 7)
    }

    private func rampPCM(_ frames: Int) -> Data {
        var pcm = Data(count: frames * 2)
        pcm.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { p[i] = Int16(clamping: i) }
        }
        return pcm
    }

    private func assertConversion(_ converter: RenderConverter, pcm: Data,
                                  expectedFrames: Int, file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let out = try XCTUnwrap(converter.convert(pcm), file: file, line: line)
        // The resampler holds a tail internally — convert + EOS drain
        // together must account for every input frame.
        let flushed = try XCTUnwrap(converter.drain(), file: file, line: line)
        XCTAssertEqual(Int(out.frameLength + flushed.frameLength), expectedFrames,
                       accuracy: 8, file: file, line: line)
        let samples = out.floatChannelData![0]
        let channels = Int(out.format.channelCount)
        let produced = Int(out.frameLength)
        // Stereo duplication — model audio is mono fanned out to the render bus.
        XCTAssertEqual(samples[0], samples[1], accuracy: 1e-6, file: file, line: line)
        // A rising int16 ramp must still be rising at coarse points —
        // resampler ringing is fine near edges, the trend must survive.
        let mid = produced / 2, late = produced - 4
        XCTAssertLessThan(samples[4 * channels], samples[mid * channels], file: file, line: line)
        XCTAssertLessThan(samples[mid * channels], samples[late * channels], file: file, line: line)
        // int16 full-scale → Float ~±1.
        XCTAssertLessThan(abs(samples[late * channels]), 1.1, file: file, line: line)
    }

    func testConverter24kTo48kStereo() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 48000, channels: 2, interleaved: true))
        let converter = try XCTUnwrap(RenderConverter(outputFormat: format))
        // 2400 int16 frames = 100ms → 4800 stereo frames.
        try assertConversion(converter, pcm: rampPCM(2400), expectedFrames: 4800)
    }

    func testConverter24kTo441kStereo() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 44100, channels: 2, interleaved: true))
        let converter = try XCTUnwrap(RenderConverter(outputFormat: format))
        // 2400 int16 frames = 100ms → 4410 stereo frames.
        try assertConversion(converter, pcm: rampPCM(2400), expectedFrames: 4410)
    }
}
