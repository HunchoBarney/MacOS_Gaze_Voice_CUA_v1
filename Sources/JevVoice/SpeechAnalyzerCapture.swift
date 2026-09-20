import AVFoundation
import Combine
import Speech
import JevVoiceCore

@MainActor
final class SpeechAssets: ObservableObject {
    static let shared = SpeechAssets()
    @Published private(set) var message = "Checking on-device speech…"
    @Published private(set) var ready = false
    @Published private(set) var preparing = false

    static func transcriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw VoiceError("SpeechAnalyzer does not support this Mac or language (\(Locale.current.identifier)).")
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                 reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }

    static func analyzer(for module: SpeechTranscriber) -> SpeechAnalyzer {
        SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
    }

    func refresh(install: Bool = false) async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        do {
            let module = try await Self.transcriber()
            if install, let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                message = "Downloading on-device speech assets…"
                try await request.downloadAndInstall()
            }
            ready = false
            if await AssetInventory.status(forModules: [module]) == .installed {
                message = "Preparing on-device speech…"
                let warmup = Self.analyzer(for: module)
                do { try await warmup.prepareToAnalyze(in: nil) }
                catch { await warmup.cancelAndFinishNow(); throw error }
                await warmup.cancelAndFinishNow()
                ready = true
            }
            message = ready ? "Apple SpeechAnalyzer ready — \(Locale.current.identifier)" : "On-device speech assets are missing. Prepare speech to download them."
        } catch { ready = false; message = error.localizedDescription }
    }
}

/// Owns one converter and bounded stream per recording. No Task is allocated per
/// audio callback. Buffers are copied/converted before leaving the tap's lifetime.
final class AnalyzerAudioFeed: @unchecked Sendable {
    let stream: AsyncThrowingStream<AnalyzerInput, Error>
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private let conversionLock = NSLock()
    private var ended = false
    private var meter: Float = 0
    private var firstBufferAt: Double?
    private var inputSeconds = 0.0
    private var audibleSeconds = 0.0
    private var outputSeconds = 0.0

    init(input: AVAudioFormat, output: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw VoiceError("The microphone format cannot be converted for SpeechAnalyzer.")
        }
        self.converter = converter; self.outputFormat = output
        let pair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        stream = pair.stream; continuation = pair.continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        conversionLock.lock(); defer { conversionLock.unlock() }
        guard !ended else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        inputSeconds += duration
        lock.lock()
        if firstBufferAt == nil { firstBufferAt = ProcessInfo.processInfo.systemUptime }
        lock.unlock()
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            if rms > 0.0031623 { audibleSeconds += duration }
            lock.lock(); meter = max(0, min(1, (20 * log10(max(rms, 0.00001)) + 55) / 50)); lock.unlock()
        }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            continuation.finish(throwing: VoiceError("Could not allocate speech audio.")); return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        if status == .error {
            continuation.finish(throwing: error ?? VoiceError("Speech audio conversion failed.") as NSError); return
        }
        if output.frameLength > 0 {
            outputSeconds += Double(output.frameLength) / outputFormat.sampleRate
            if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                continuation.finish(throwing: VoiceError("Speech processing could not keep up. Recording stopped without submitting incomplete speech."))
            }
        }
    }
    func level() -> Float { lock.lock(); defer { lock.unlock() }; return meter }
    func firstBufferTime() -> Double? { lock.lock(); defer { lock.unlock() }; return firstBufferAt }
    func audioDurations() -> (input: Double, audible: Double, converted: Double) {
        conversionLock.lock(); defer { conversionLock.unlock() }
        return (inputSeconds, audibleSeconds, outputSeconds)
    }
    func finish() {
        conversionLock.lock(); defer { conversionLock.unlock() }
        guard !ended else { return }
        ended = true
        // Resampling retains a small tail. Signal EOS and drain it before closing
        // the analyzer input, or the final audio frames never reach recognition.
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream; return nil
            }
            if status == .error {
                continuation.finish(throwing: error ?? VoiceError("Speech audio finalization failed.") as NSError); return
            }
            outputSeconds += Double(output.frameLength) / outputFormat.sampleRate
            if output.frameLength > 0,
               case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                continuation.finish(throwing: VoiceError("Speech processing could not finish the audio.")); return
            }
            if status == .endOfStream { continuation.finish(); return }
        }
        continuation.finish(throwing: VoiceError("Speech audio finalization did not complete."))
    }
}

@MainActor
final class SpeechAnalyzerCapture: SpeechCapturing {
    var onEvent: ((UUID, SpeechEvent) -> Void)?
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var feed: AnalyzerAudioFeed?
    private var resultsTask: Task<Void, Error>?
    private var analysisTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var meterTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var sessionID: UUID?
    private var transcript = RangedTranscript()
    private var tapInstalled = false

    static func requestAuthorization() async -> Bool {
        if !Permission.microphone.isGranted { await Permission.microphone.request() }
        return Permission.microphone.isGranted
    }

    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
        cancel()
        sessionID = session; transcript = RangedTranscript()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var checkpoint = startedAt
        func record(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            onEvent?(session, .timing(name, milliseconds: (now - checkpoint) * 1000))
            checkpoint = now
        }
        do {
            let device = try MicrophoneCatalog.resolve(uid: inputUID)
            record("Microphone device lookup")
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            if input.auAudioUnit.deviceID != device.hardwareID { try input.auAudioUnit.setDeviceID(device.hardwareID) }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("The microphone has no usable audio input.") }
            record("Audio input setup")
            let output: AVAudioFormat
            if transcribe {
                let module = try await SpeechAssets.transcriber()
                guard await AssetInventory.status(forModules: [module]) == .installed else {
                    throw VoiceError("Prepare on-device speech assets in Voice settings before recording.")
                }
                guard let compatible = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: format) else {
                    throw VoiceError("No supported SpeechAnalyzer audio format is available.")
                }
                try Task.checkCancellation()
                guard sessionID == session else { throw CancellationError() }
                output = compatible
                record("Speech assets and format")
                let analyzer = SpeechAssets.analyzer(for: module)
                self.analyzer = analyzer
                try await analyzer.prepareToAnalyze(in: output)
                record("Speech model preparation")
                try Task.checkCancellation()
                guard sessionID == session else { throw CancellationError() }
                resultsTask = Task { [weak self] in
                    do {
                        for try await result in module.results {
                            guard let self, self.sessionID == session, !Task.isCancelled else { return }
                            let revision = SpeechRevision(start: result.range.start.seconds,
                                end: CMTimeRangeGetEnd(result.range).seconds,
                                text: String(result.text.characters), isFinal: result.isFinal)
                            if try self.transcript.apply(revision) {
                                self.onEvent?(session, .revision(revision, transcript: self.transcript.text))
                            }
                        }
                    } catch {
                        guard let self, self.sessionID == session, !Task.isCancelled else { return }
                        self.onEvent?(session, .failure(error.localizedDescription))
                        throw error
                    }
                }
            } else { output = format }
            try Task.checkCancellation()
            guard sessionID == session else { throw CancellationError() }
            let feed = try AnalyzerAudioFeed(input: format, output: output)
            self.feed = feed
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
            tapInstalled = true
            let analyzer = self.analyzer
            analysisTask = Task { [weak self] in
                do {
                    if let analyzer { try await analyzer.start(inputSequence: feed.stream) }
                    else { for try await _ in feed.stream { } }
                    if let self, self.sessionID == session, !Task.isCancelled {
                        self.onEvent?(session, .timing("Capture call to analyzer start", milliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
                    }
                } catch {
                    guard let self, self.sessionID == session, !Task.isCancelled else { return }
                    self.onEvent?(session, .failure(error.localizedDescription))
                }
            }
            record("Audio pipeline setup")
            engine.prepare(); try engine.start()
            record("Audio engine start")
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sessionID == session, let engine = self.engine else { return }
                    let current = engine.inputNode.outputFormat(forBus: 0)
                    if !engine.isRunning || engine.inputNode.auAudioUnit.deviceID != device.hardwareID || current != format {
                        self.onEvent?(session, .failure("Microphone configuration changed. Hold Fn to record again."))
                    }
                }
            }
            var reportedFirstBuffer = false
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sessionID == session else { return }
                    if !reportedFirstBuffer, let first = feed.firstBufferTime() {
                        reportedFirstBuffer = true
                        self.onEvent?(session, .timing("Capture call to first audio", milliseconds: (first - startedAt) * 1000))
                    }
                    self.onEvent?(session, .level(feed.level()))
                }
            }
            if let meterTimer { RunLoop.main.add(meterTimer, forMode: .common) }
            return device.name
        } catch {
            if sessionID == session { cancel() }
            throw error
        }
    }

    func finish() {
        guard finishTask == nil, let id = sessionID else { return }
        let finishStarted = ProcessInfo.processInfo.systemUptime
        stopCapture(); feed?.finish()
        onEvent?(id, .timing("Audio capture stopped and drained", milliseconds: (ProcessInfo.processInfo.systemUptime - finishStarted) * 1000))
        if let durations = feed?.audioDurations() {
            onEvent?(id, .timing("Captured audio duration", milliseconds: durations.input * 1000))
            onEvent?(id, .timing("Audio above minus 50 dBFS", milliseconds: durations.audible * 1000))
            onEvent?(id, .timing("Converted audio duration", milliseconds: durations.converted * 1000))
        }
        let analyzer = self.analyzer, results = resultsTask, analysis = analysisTask
        finishTask = Task { [weak self] in
            do {
                await analysis?.value
                guard let self, self.sessionID == id, !Task.isCancelled else { return }
                self.onEvent?(id, .timing("Release to analyzer start joined", milliseconds: (ProcessInfo.processInfo.systemUptime - finishStarted) * 1000))
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                self.onEvent?(id, .timing("Release to analyzer finalized", milliseconds: (ProcessInfo.processInfo.systemUptime - finishStarted) * 1000))
                try await results?.value
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.onEvent?(id, .final(self.transcript.text))
            } catch {
                guard let self, self.sessionID == id, !Task.isCancelled else { return }
                self.onEvent?(id, .failure(error.localizedDescription))
            }
        }
    }

    func cancel() {
        sessionID = nil
        stopCapture(); feed?.finish(); feed = nil
        analysisTask?.cancel(); analysisTask = nil
        resultsTask?.cancel(); resultsTask = nil
        finishTask?.cancel(); finishTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil; engine = nil
    }
    private func stopCapture() {
        meterTimer?.invalidate(); meterTimer = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
}
