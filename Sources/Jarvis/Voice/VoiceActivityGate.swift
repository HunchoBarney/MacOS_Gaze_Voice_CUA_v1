import AVFoundation
import CoreML
import Foundation

/// Silero VAD v6.2.1 (MIT), converted to Core ML by FluidInference. It
/// scores 256 ms of 16 kHz audio at a time and keeps its LSTM state between
/// calls, so one instance follows one microphone stream.
final class SileroVoiceActivity {
    static let sampleRate = 16_000.0
    static let chunkSamples = 4096
    private static let contextSamples = 64
    private static let stateSize = 128
    private static let modelName = "silero-vad-unified-256ms-v6.2.1"

    private let model: MLModel
    private let audio: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray

    init() throws {
        model = try Self.sharedModel()
        audio = try MLMultiArray(shape: [1, NSNumber(value: Self.contextSamples + Self.chunkSamples)], dataType: .float32)
        hidden = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
        cell = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
        for array in [audio, hidden, cell] { Self.clear(array) }
    }

    /// Speech probability for the next `chunkSamples` samples of 16 kHz mono audio.
    func probability(_ chunk: ArraySlice<Float>) throws -> Float {
        precondition(chunk.count == Self.chunkSamples)
        let pointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
        pointer.update(from: pointer + Self.chunkSamples, count: Self.contextSamples)
        chunk.withUnsafeBufferPointer { (pointer + Self.contextSamples).update(from: $0.baseAddress!, count: $0.count) }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_input": audio, "hidden_state": hidden, "cell_state": cell,
        ]))
        guard let speech = output.featureValue(for: "vad_output")?.multiArrayValue,
              let nextHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
              let nextCell = output.featureValue(for: "new_cell_state")?.multiArrayValue else {
            throw VoiceError("The speech detector returned an unexpected result.")
        }
        hidden = nextHidden
        cell = nextCell
        return speech[0].floatValue
    }

    private static func clear(_ array: MLMultiArray) {
        array.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: array.count)
    }

    private static let loaded = NSLock()
    nonisolated(unsafe) private static var cached: MLModel?

    private static func sharedModel() throws -> MLModel {
        loaded.lock(); defer { loaded.unlock() }
        if let cached { return cached }
        guard let url = modelURL() else { throw VoiceError("The speech detector is missing from this build.") }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: configuration)
        cached = model
        return model
    }

    /// The release app carries the model in Resources; `swift test` and
    /// debug runs read it from the checkout.
    static func modelURL() -> URL? {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("SileroVAD/\(modelName).mlmodelc", isDirectory: true)
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ThirdParty/SileroVAD/\(modelName).mlmodelc", isDirectory: true)
        return [bundled, checkout].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.mil").path)
        }
    }
}

/// Decides which hands-free microphone audio leaves the Mac, and where
/// each turn ends. Room audio is scored locally and uploaded only while
/// someone is speaking, plus the second before the speech started so its
/// first syllable isn't clipped.
///
/// Once the speaker has been quiet for `endOfTurn` the gate ends the turn
/// itself; the lane then commits the buffer, so no server voice detection
/// and no trailing silence are involved. Silero scores 256 ms chunks, so the
/// turn ends after the smallest whole number of consecutive quiet chunks
/// covering `endOfTurn` (three, 0.77 s, at the default 0.6 s). A pause
/// shorter than `endOfTurn` can't hold that many chunks, so it never ends a
/// turn unless the detector scores speech itself as quiet.
actor VoiceActivityGate {
    struct Tuning: Sendable {
        var onset: Float = 0.5
        var offset: Float = 0.35
        var preRoll: TimeInterval = 1.0
        var endOfTurn: TimeInterval = 0.6
    }

    /// What one microphone buffer produced, in wire order: audio to upload,
    /// and the turn's start (before its first audio) and end (after its last).
    enum Event: Sendable, Equatable {
        case turnStarted
        case audio(Data)
        case turnEnded
    }

    /// Seconds of microphone audio heard, and how much of it was uploaded.
    struct Usage: Sendable, Equatable {
        var heard: TimeInterval = 0
        var sentSpeech: TimeInterval = 0
    }

    private enum Phase { case closed, speaking, pausing(chunks: Int) }

    private(set) var usage = Usage()
    private let tuning: Tuning
    private let bytesPerSecond: Double
    private let chunkSeconds = Double(SileroVoiceActivity.chunkSamples) / SileroVoiceActivity.sampleRate
    private let score: (ArraySlice<Float>) throws -> Float
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let scoringFormat: AVAudioFormat
    private var phase = Phase.closed
    private var preRoll: [Data] = []
    private var preRollBytes = 0
    private var pending: [Float] = []

    /// `pcm` arrives as 16-bit mono at `sampleRate`, the Realtime input format.
    init(sampleRate: Double = 24_000, tuning: Tuning = Tuning(),
         score: @escaping (ArraySlice<Float>) throws -> Float) throws {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let scoring = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SileroVoiceActivity.sampleRate,
                                          channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: scoring) else {
            throw VoiceError("The speech detector can't read this microphone format.")
        }
        self.tuning = tuning
        self.score = score
        self.converter = converter
        inputFormat = input
        scoringFormat = scoring
        bytesPerSecond = sampleRate * 2
    }

    /// The gate the hands-free lane uses: Silero scoring on the Mac.
    static func silero(sampleRate: Double = 24_000, tuning: Tuning = Tuning()) throws -> VoiceActivityGate {
        let detector = try SileroVoiceActivity()
        return try VoiceActivityGate(sampleRate: sampleRate, tuning: tuning) { try detector.probability($0) }
    }

    /// Takes the next microphone buffer and returns what to upload and where
    /// turns start and end, in order.
    func admit(_ pcm: Data) throws -> [Event] {
        guard !pcm.isEmpty else { return [] }
        let seconds = Double(pcm.count) / bytesPerSecond
        usage.heard += seconds
        var events: [Event] = []
        if case .closed = phase {
            remember(pcm)
        } else {
            events.append(.audio(pcm))
            usage.sentSpeech += seconds
        }
        pending += try resampled(pcm)
        while pending.count >= SileroVoiceActivity.chunkSamples {
            let speech = try score(pending[..<SileroVoiceActivity.chunkSamples])
            pending.removeFirst(SileroVoiceActivity.chunkSamples)
            events += decide(speech)
        }
        return events
    }

    private func decide(_ speech: Float) -> [Event] {
        let quiet: Int
        switch phase {
        case .closed:
            guard speech >= tuning.onset else { return [] }
            phase = .speaking
            let flushed = preRoll
            usage.sentSpeech += Double(preRollBytes) / bytesPerSecond
            preRoll = []; preRollBytes = 0
            return [.turnStarted] + flushed.map(Event.audio)
        case .speaking: quiet = 0
        case .pausing(let chunks): quiet = chunks
        }
        guard speech < tuning.offset else { phase = .speaking; return [] }
        guard Double(quiet + 1) * chunkSeconds < tuning.endOfTurn - 1e-9 else {
            phase = .closed
            return [.turnEnded]
        }
        phase = .pausing(chunks: quiet + 1)
        return []
    }

    /// Speech is scored up to two chunks after it starts, so the ring holds
    /// that much on top of the pre-roll.
    private func remember(_ pcm: Data) {
        preRoll.append(pcm)
        preRollBytes += pcm.count
        let limit = Int((tuning.preRoll + 2 * chunkSeconds) * bytesPerSecond)
        while let oldest = preRoll.first, preRollBytes - oldest.count >= limit {
            preRollBytes -= oldest.count
            preRoll.removeFirst()
        }
    }

    private func resampled(_ pcm: Data) throws -> [Float] {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let output = AVAudioPCMBuffer(pcmFormat: scoringFormat, frameCapacity: frames) else {
            throw VoiceError("The speech detector ran out of memory.")
        }
        input.frameLength = frames
        pcm.withUnsafeBytes { bytes in
            input.int16ChannelData![0].update(from: bytes.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw failure ?? VoiceError("The speech detector couldn't resample the microphone.") }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
