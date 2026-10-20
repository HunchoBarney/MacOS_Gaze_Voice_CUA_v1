import AVFoundation
import Foundation

/// Record at the device's pace, then resample the completed file off the audio thread.
@MainActor
enum MicCapture {
    struct Clip {
        let url: URL
        let duration: Double
        let peakDB: Double
        let activeSeconds: Double
        let device: String

        var quality: String {
            guard activeSeconds >= 0.25 else { return "quiet" }
            return "ok"
        }
    }

    static func requirePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw BakeoffError.audio("microphone permission denied; enable it for your terminal in System Settings > Privacy & Security > Microphone")
            }
        default:
            throw BakeoffError.audio("microphone access is blocked; enable it for your terminal in System Settings > Privacy & Security > Microphone")
        }
    }

    static func capture(directory: URL, seconds: Double, progress: Bool = true) async throws -> Clip {
        guard seconds.isFinite, (1...30).contains(seconds) else {
            throw BakeoffError.usage("capture duration must be between 1 and 30 seconds")
        }
        try await requirePermission()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let rawURL = directory.appendingPathComponent("\(id)-native.wav")
        let url = directory.appendingPathComponent("\(id).wav")
        let recorder = try AVAudioRecorder(url: rawURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record(forDuration: seconds) else {
            throw BakeoffError.audio("microphone could not start; check the input device in System Settings > Sound > Input")
        }
        defer { recorder.stop() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds + 5))
        var displayedSecond = -1
        while recorder.isRecording {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw BakeoffError.audio("microphone stalled; no clip was accepted")
            }
            let elapsed = recorder.currentTime
            let second = Int(elapsed)
            if progress, second != displayedSecond {
                displayedSecond = second
                recorder.updateMeters()
                let level = recorder.averagePower(forChannel: 0)
                let bars = String(repeating: "#", count: max(0, min(20, Int((level + 60) / 3))))
                Record.say("  REC \(second)/\(Int(ceil(seconds)))s  [\(bars)]")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        recorder.stop()

        // Assert on the actual file, not a timer or the recorder's return code.
        let native = try AVAudioFile(forReading: rawURL)
        let nativeDuration = Double(native.length) / native.processingFormat.sampleRate
        try validateDuration(actual: nativeDuration, expected: seconds)
        let samples = try Audio.samples(from: rawURL)
        let duration = Double(samples.count) / Audio.sampleRate
        try validateDuration(actual: duration, expected: seconds)
        guard samples.allSatisfy(\.isFinite) else {
            throw BakeoffError.audio("capture contains invalid sample values")
        }
        try Audio.writeWav(samples, to: url)
        let saved = try AVAudioFile(forReading: url)
        try validateDuration(
            actual: Double(saved.length) / saved.processingFormat.sampleRate, expected: seconds)
        let stats = levels(samples)
        return Clip(
            url: url, duration: duration, peakDB: stats.peakDB, activeSeconds: stats.activeSeconds,
            device: AVCaptureDevice.default(for: .audio)?.localizedName ?? "default microphone")
    }

    static func validateDuration(actual: Double, expected: Double) throws {
        guard actual.isFinite, abs(actual - expected) <= max(0.35, expected * 0.1) else {
            throw BakeoffError.audio(
                "expected \(String(format: "%.1f", expected))s but file contains \(String(format: "%.2f", actual))s; capture failed, nothing accepted")
        }
    }

    static func levels(_ samples: [Float]) -> (peakDB: Double, activeSeconds: Double) {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        let window = 1600 // 100 ms at 16 kHz
        var activeFrames = 0
        for start in stride(from: 0, to: samples.count, by: window) {
            let chunk = samples[start..<min(start + window, samples.count)]
            let squareSum = chunk.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = sqrt(squareSum / Double(chunk.count))
            if rms > pow(10, -50.0 / 20) { activeFrames += chunk.count }
        }
        return (20 * log10(max(Double(peak), 1e-6)), Double(activeFrames) / Audio.sampleRate)
    }
}
