@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import BakeoffCore

@Suite(.serialized)
@MainActor
struct RecorderTests {
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func speech() throws -> [Float] {
        // Real speech already used by this spike. Never generate synthetic test audio.
        let url = package.appendingPathComponent("corpus/library/lib03.wav")
        return Array(try Audio.samples(from: url).prefix(96_000))
    }

    @Test func durationGuardRejectsTheObservedPointOneSecondFiles() throws {
        #expect(throws: BakeoffError.self) {
            try MicCapture.validateDuration(actual: 0.1, expected: 6)
        }
        #expect(throws: BakeoffError.self) {
            try MicCapture.validateDuration(actual: .nan, expected: 6)
        }
        try MicCapture.validateDuration(actual: 5.99, expected: 6)
    }

    @Test func converterEndOfStreamBugReproducesWithRealSpeech() throws {
        let samples = try speech()
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let outputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: outputFormat))
        // Resample actual speech to the microphone's 48 kHz rate first.
        let upsampler = try #require(AVAudioConverter(from: outputFormat, to: inputFormat))
        let native = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 300_000))
        let supplied = Mutex(false)
        var error: NSError?
        _ = upsampler.convert(to: native, error: &error) { _, status in
            let first = supplied.withLock { fed in defer { fed = true }; return !fed }
            status.pointee = first ? .haveData : .endOfStream
            return first ? try? Audio.buffer(samples) : nil
        }
        #expect(error == nil)
        let data = try #require(native.floatChannelData)
        let nativeSamples = Array(UnsafeBufferPointer(start: data[0], count: Int(native.frameLength)))
        var convertedFrames = 0
        for start in stride(from: 0, to: nativeSamples.count, by: 4096) {
            let chunk = Array(nativeSamples[start..<min(start + 4096, nativeSamples.count)])
            let fed = Mutex(false)
            let output = try #require(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2400))
            _ = converter.convert(to: output, error: &error) { _, status in
                let first = fed.withLock { value in defer { value = true }; return !value }
                // This is the old tap's bug: EOS is permanent, not "try the next buffer".
                status.pointee = first ? .haveData : .endOfStream
                guard first, let buffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk.count)),
                    let channel = buffer.floatChannelData else { return nil }
                buffer.frameLength = AVAudioFrameCount(chunk.count)
                chunk.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: chunk.count) }
                return buffer
            }
            convertedFrames += Int(output.frameLength)
        }
        let actual = Double(convertedFrames) / Audio.sampleRate
        print("Negative control: old tap converted 6s of real speech into \(actual)s")
        #expect(actual < 0.2)
        #expect(throws: BakeoffError.self) {
            try MicCapture.validateDuration(actual: actual, expected: 6)
        }
    }

    @Test func completedFileRoundTripPreservesRealSpeechDuration() throws {
        let samples = try speech()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("speech.wav")
        try Audio.writeWav(samples, to: url)
        let decoded = try Audio.samples(from: url)
        #expect(decoded.count == samples.count)
        #expect(MicCapture.levels(decoded).activeSeconds > 0.25)
    }

    @Test func legacyManifestRemainsReadableAndIsNotSilentlyReset() throws {
        let json = """
        {"device_note":"old input","recordings":[{"id":"p01","prompt":"open this",
        "wav":"recordings/p01.wav","status":"too_short","device":"default input",
        "sample_rate":16000,"recorded_at":"2026-10-19","duration_s":0.1}]}
        """
        let manifest = try JSONDecoder().decode(Record.Manifest.self, from: Data(json.utf8))
        #expect(manifest.recordings.count == 1)
        #expect(manifest.recordings[0].peak == nil)
        #expect(manifest.recordings[0].confirmed == nil)
    }

    @Test func manifestWriteErrorsPropagateAndCorruptionIsNotIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("manifest.json")
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try Record.loadManifest(corpusDir: dir) }
        let manifest = Record.Manifest(recordings: [], device_note: "test metadata only")
        #expect(throws: (any Error).self) {
            try Record.save(manifest, corpusDir: dir.appendingPathComponent("missing"))
        }
        try Record.save(manifest, corpusDir: dir)
        #expect(try Record.loadManifest(corpusDir: dir).recordings.isEmpty)
    }

    @Test func longerPromptsGetEnoughRecordingTime() {
        #expect(Record.captureSeconds(for: "open this") == 6)
        #expect(Record.captureSeconds(
            for: "send a slack message to the team channel saying standup is moved to eleven") >= 10)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_RECORDER_LIVE"] == "1"))
    func nativeMicCapturesFullFilesAcrossThreeStarts() async throws {
        let dir = package.appendingPathComponent("corpus/recordings/diagnostics")
        for i in 1...3 {
            let clip = try await MicCapture.capture(directory: dir, seconds: 2, progress: false)
            #expect(abs(clip.duration - 2) < 0.25)
            let file = try AVAudioFile(forReading: clip.url)
            #expect(file.processingFormat.sampleRate == 16_000)
            #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2) < 0.25)
            print("LIVE capture \(i): \(clip.duration)s, peak \(clip.peakDB)dB, \(clip.url.lastPathComponent)")
        }
    }
}
