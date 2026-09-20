import AVFoundation
import Speech
import JevVoiceCore

enum SpeechEvent {
    case partial(String), final(String), failure(String), level(Float)
    case revision(SpeechRevision, transcript: String)
    case timing(String, milliseconds: Double)
}

@MainActor
protocol SpeechCapturing: AnyObject {
    var onEvent: ((UUID, SpeechEvent) -> Void)? { get set }
    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String
    func finish()
    func cancel()
}

/// The audio callback captures its own request and meter, never a later session's mutable state.
private final class AudioLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    func sample(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let level = max(0, min(1, (20 * log10(max(rms, 0.00001)) + 55) / 50))
        lock.lock(); value = level; lock.unlock()
    }
    func read() -> Float { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class SpeechRecognizer: SpeechCapturing {
    var onEvent: ((UUID, SpeechEvent) -> Void)?
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var meterTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var transcript = SpeechTranscriptAccumulator()

    static func requestAuthorization() async -> Bool {
        if !Permission.microphone.isGranted { await Permission.microphone.request() }
        guard Permission.microphone.isGranted else { return false }
        if !Permission.speechRecognition.isGranted { await Permission.speechRecognition.request() }
        return Permission.speechRecognition.isGranted
    }

    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
        cancel()
        // Yield a render opportunity before Core Audio initializes the input.
        try await Task.sleep(nanoseconds: 10_000_000)
        try Task.checkCancellation()
        let device = try MicrophoneCatalog.resolve(uid: inputUID)
        let engine = AVAudioEngine()
        self.engine = engine
        sessionID = session
        transcript = SpeechTranscriptAccumulator()
        do {
            let request: SFSpeechAudioBufferRecognitionRequest?
            if transcribe {
                guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
                    throw VoiceError("Speech recognition is unavailable. Check your language and try again.")
                }
                self.recognizer = recognizer
                request = try Self.makeRecognitionRequest(supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition)
            } else { request = nil }
            self.request = request
            let input = engine.inputNode
            if input.auAudioUnit.deviceID != device.hardwareID {
                try input.auAudioUnit.setDeviceID(device.hardwareID)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("The microphone has no usable audio input.") }
            let meter = AudioLevel()
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request?.append(buffer)
                meter.sample(buffer)
            }
            tapInstalled = true
            if let request, let recognizer {
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.sessionID == session else { return }
                        if let result {
                            let text = Self.accumulate(result, into: &self.transcript)
                            self.onEvent?(session, result.isFinal ? .final(text) : .partial(text))
                        } else if let error {
                            self.onEvent?(session, .failure(error.localizedDescription))
                        }
                    }
                }
            }
            engine.prepare()
            try engine.start()
            let expectedRate = format.sampleRate
            let expectedChannels = format.channelCount
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sessionID == session, let engine = self.engine else { return }
                    // Initialization can enqueue this notification after start(). Validate the
                    // live engine instead of treating our own setup as device loss.
                    let current = engine.inputNode.outputFormat(forBus: 0)
                    guard !engine.isRunning || engine.inputNode.auAudioUnit.deviceID != device.hardwareID
                        || current.sampleRate != expectedRate || current.channelCount != expectedChannels else { return }
                    self.onEvent?(session, .failure("Microphone configuration changed. Hold Fn to record again."))
                }
            }
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sessionID == session else { return }
                    self.onEvent?(session, .level(meter.read()))
                }
            }
            RunLoop.main.add(meterTimer!, forMode: .common)
            return device.name
        } catch { cancel(); throw error }
    }

    func finish() {
        stopCapture()
        request?.endAudio()
        task?.finish()
    }

    func cancel() {
        sessionID = nil
        stopCapture()
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil; recognizer = nil; engine = nil
    }

    private func stopCapture() {
        meterTimer?.invalidate(); meterTimer = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }

    static func accumulate(_ result: SFSpeechRecognitionResult, into transcript: inout SpeechTranscriptAccumulator) -> String {
        let parts = result.bestTranscription.segments
        let timed = result.speechRecognitionMetadata != nil
        return transcript.update(result.bestTranscription.formattedString,
            start: timed ? parts.first?.timestamp : nil,
            end: timed ? parts.last.map { $0.timestamp + $0.duration } : nil,
            final: result.isFinal)
    }

    static func makeRecognitionRequest(supportsOnDeviceRecognition: Bool) throws -> SFSpeechAudioBufferRecognitionRequest {
        guard supportsOnDeviceRecognition else {
            throw VoiceError("On-device speech recognition is unavailable for this language on this Mac. Audio will not be sent for online recognition.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        return request
    }
}
