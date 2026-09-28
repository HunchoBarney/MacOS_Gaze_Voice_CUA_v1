import AVFoundation
import Combine
import Speech
import OSLog
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
    private let inputFormat: AVAudioFormat
    private let lock = NSLock()
    private let conversionLock = NSLock()
    private var ended = false
    private var meter: Float = 0
    private var firstBufferAt: Double?
    private var inputSeconds = 0.0
    private var audibleSeconds = 0.0
    private var outputSeconds = 0.0
    private var bufferCount = 0
    private var peakRMS: Float = 0
    private var hasFloatSamples = false

    init(input: AVAudioFormat, output: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw VoiceError("The microphone format cannot be converted for SpeechAnalyzer.")
        }
        self.converter = converter; self.inputFormat = input; self.outputFormat = output
        let pair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        stream = pair.stream; continuation = pair.continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        conversionLock.lock(); defer { conversionLock.unlock() }
        guard !ended else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        inputSeconds += duration
        bufferCount += 1
        lock.lock()
        if firstBufferAt == nil { firstBufferAt = ProcessInfo.processInfo.systemUptime }
        lock.unlock()
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            hasFloatSamples = true
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            peakRMS = max(peakRMS, rms)
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
    func audioSummary() -> (input: Double, audible: Double, converted: Double, peakRMS: Float,
                            hasFloatSamples: Bool, bufferCount: Int, sampleRate: Double,
                            channels: AVAudioChannelCount, commonFormat: AVAudioCommonFormat) {
        conversionLock.lock(); defer { conversionLock.unlock() }
        return (inputSeconds, audibleSeconds, outputSeconds, peakRMS, hasFloatSamples, bufferCount,
                inputFormat.sampleRate, inputFormat.channelCount, inputFormat.commonFormat)
    }
    func audioDurations() -> (input: Double, audible: Double, converted: Double) {
        let summary = audioSummary()
        return (summary.input, summary.audible, summary.converted)
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
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "capture")
    var onEvent: ((UUID, SpeechEvent) -> Void)?
    var onReadiness: ((SpeechReadiness) -> Void)?
    private let input = MicrophoneInput()
    private var prepared: Session?
    private var active: (id: UUID, session: Session)?
    private var preparation: Task<String, Error>?
    private var preparationID = UUID()
    private var selectedUID: String?
    private var enabled = false
    private var finishTask: Task<Void, Never>?
    private var meterTimer: Timer?

    @MainActor
    private final class Session {
        let name: String
        let module: SpeechTranscriber?
        let analyzer: SpeechAnalyzer?
        let feed: AnalyzerAudioFeed
        var transcript = RangedTranscript()
        var results: Task<Void, Error>?
        var audioSummaryLogged = false
        init(name: String, module: SpeechTranscriber?, analyzer: SpeechAnalyzer?, feed: AnalyzerAudioFeed) {
            self.name = name; self.module = module; self.analyzer = analyzer; self.feed = feed
        }
    }

    static func requestAuthorization() async -> Bool {
        if !Permission.microphone.isGranted { await Permission.microphone.request() }
        return Permission.microphone.isGranted
    }

    func prepare(inputUID: String?) async throws -> String {
        try Task.checkCancellation()
        let uid = inputUID ?? ""
        if selectedUID == uid {
            if let prepared { return prepared.name }
            if let preparation { return try await preparation.value }
        } else {
            await suspend()
        }
        try Task.checkCancellation()
        enabled = true; selectedUID = uid
        let token = UUID(); preparationID = token
        onReadiness?(.preparing)
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            defer { if self.preparationID == token { self.preparation = nil } }
            do {
                try Task.checkCancellation()
                guard Permission.microphone.isGranted else { throw VoiceError("Microphone access is needed. Open Voice settings.") }
                let device = try MicrophoneCatalog.resolve(uid: uid)
                let hardware = try await self.input.prepare(device: device) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.enabled, self.preparationID == token else { return }
                        let reason = "Microphone configuration changed. Preparing a fresh input is required."
                        if let active = self.active { self.onEvent?(active.id, .failure(reason)) }
                        await self.suspend()
                        self.onReadiness?(.interrupted(reason))
                    }
                }
                try Task.checkCancellation()
                let module = try await SpeechAssets.transcriber()
                guard await AssetInventory.status(forModules: [module]) == .installed else {
                    throw VoiceError("Prepare on-device speech assets in Voice settings before recording.")
                }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: hardware.format) else {
                    throw VoiceError("No supported speech audio format is available.")
                }
                let analyzer = SpeechAssets.analyzer(for: module)
                do {
                    let feed = try AnalyzerAudioFeed(input: hardware.format, output: format)
                    try await analyzer.prepareToAnalyze(in: format)
                    try Task.checkCancellation()
                    guard self.enabled, self.preparationID == token else { throw CancellationError() }
                    try await analyzer.start(inputSequence: feed.stream)
                    try Task.checkCancellation()
                    guard self.enabled, self.preparationID == token else { throw CancellationError() }
                    self.prepared = Session(name: hardware.name, module: module, analyzer: analyzer, feed: feed)
                    self.onReadiness?(.ready(hardware.name))
                    return hardware.name
                } catch { await analyzer.cancelAndFinishNow(); throw error }
            } catch {
                if self.preparationID == token {
                    await self.input.stop()
                    self.onReadiness?(.unavailable(error.localizedDescription))
                }
                throw error
            }
        }
        preparation = task
        return try await task.value
    }

    func start(session id: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
        cancel()
        let started = ProcessInfo.processInfo.systemUptime
        let session: Session
        if transcribe {
            _ = try await prepare(inputUID: inputUID)
            try Task.checkCancellation()
            guard let next = prepared else { throw VoiceError("Speech input is not ready yet.") }
            session = next
            prepared = nil
        } else {
            // Metering does not require speech assets or a recognizer.
            await suspend()
            try Task.checkCancellation()
            selectedUID = inputUID ?? ""; enabled = true
            let device = try MicrophoneCatalog.resolve(uid: inputUID)
            let hardware = try await input.prepare(device: device, interrupted: microphoneTestInterruptionHandler(session: id))
            try Task.checkCancellation()
            session = Session(name: hardware.name, module: nil, analyzer: nil,
                              feed: try AnalyzerAudioFeed(input: hardware.format, output: hardware.format))
        }
        active = (id, session)
        if let module = session.module {
            session.results = Task { [weak self] in
                do {
                    for try await result in module.results {
                        guard let self, self.active?.id == id, !Task.isCancelled else { return }
                        let revision = SpeechRevision(start: result.range.start.seconds,
                            end: CMTimeRangeGetEnd(result.range).seconds,
                            text: String(result.text.characters), isFinal: result.isFinal)
                        if try session.transcript.apply(revision) { self.onEvent?(id, .transcript(session.transcript)) }
                    }
                    if let self, self.active?.id == id, self.finishTask == nil, !Task.isCancelled {
                        self.onEvent?(id, .failure("Speech recognition ended unexpectedly. Release Fn to review."))
                    }
                } catch {
                    guard let self, self.active?.id == id, !Task.isCancelled else { return }
                    self.onEvent?(id, .failure(error.localizedDescription))
                    throw error
                }
            }
        }
        // Meter-only input uses the same hardware/feed but never reaches recognition.
        if !transcribe {
            session.results = Task { for try await _ in session.feed.stream {} }
        }
        input.gate.open(session.feed)
        onEvent?(id, .timing("Input admission", milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000))
        var reportedFirst = false
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active?.id == id else { return }
                if !reportedFirst, let first = session.feed.firstBufferTime() {
                    reportedFirst = true
                    self.onEvent?(id, .timing("Capture call to first audio", milliseconds: (first - started) * 1000))
                }
                self.onEvent?(id, .level(session.feed.level()))
            }
        }
        if let meterTimer { RunLoop.main.add(meterTimer, forMode: .common) }
        return session.name
    }

    func microphoneTestInterruptionHandler(session id: UUID) -> @Sendable () -> Void {
        let token = preparationID
        return { [weak self] in
            Task { @MainActor in
                // Recheck ownership after the queue-to-main-actor hop, before
                // either publishing failure or tearing down a replacement input.
                guard let self, self.preparationID == token else { return }
                if self.active?.id == id { self.onEvent?(id, .failure("Microphone configuration changed.")) }
                await self.suspend()
            }
        }
    }

    func finish() {
        guard finishTask == nil, let active else { return }
        let started = ProcessInfo.processInfo.systemUptime
        input.gate.close()?.finish()
        meterTimer?.invalidate(); meterTimer = nil
        logAudioSummary(id: active.id, session: active.session)
        let durations = active.session.feed.audioSummary()
        onEvent?(active.id, .timing("Captured audio duration", milliseconds: durations.input * 1000))
        onEvent?(active.id, .timing("Converted audio duration", milliseconds: durations.converted * 1000))
        finishTask = Task { [weak self] in
            do {
                try await active.session.analyzer?.finalizeAndFinishThroughEndOfInput()
                try await active.session.results?.value
                guard let self, self.active?.id == active.id, !Task.isCancelled else { return }
                self.onEvent?(active.id, .timing("Release to analyzer finalized", milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000))
                self.onEvent?(active.id, .final(active.session.transcript.text))
            } catch {
                guard let self, self.active?.id == active.id, !Task.isCancelled else { return }
                self.onEvent?(active.id, .failure(error.localizedDescription))
            }
        }
        prepareNext()
    }

    func cancel() {
        let prior = active
        if let prior { logAudioSummary(id: prior.id, session: prior.session) }
        active = nil
        input.gate.close()?.finish()
        meterTimer?.invalidate(); meterTimer = nil
        finishTask?.cancel(); finishTask = nil
        prior?.session.results?.cancel()
        if let prior { Task { await prior.session.analyzer?.cancelAndFinishNow() } }
        prepareNext()
    }

    private func logAudioSummary(id: UUID, session: Session) {
        guard !session.audioSummaryLogged else { return }
        session.audioSummaryLogged = true
        let summary = session.feed.audioSummary()
        Self.log.notice("capture=\(id.uuidString, privacy: .public) audio_input_ms=\(summary.input * 1000) audio_converted_ms=\(summary.converted * 1000) audio_above_noise_floor_ms=\(summary.audible * 1000) peak_rms=\(summary.peakRMS) float_samples=\(summary.hasFloatSamples) buffers=\(summary.bufferCount) sample_rate=\(summary.sampleRate) channels=\(summary.channels) common_format=\(summary.commonFormat.rawValue)")
    }

    private func prepareNext() {
        guard enabled, prepared == nil, preparation == nil else { return }
        Task { [weak self] in
            guard let self, self.enabled else { return }
            _ = try? await self.prepare(inputUID: self.selectedUID)
        }
    }

    func suspend() async {
        enabled = false
        preparationID = UUID()
        let pending = preparation
        preparation = nil
        pending?.cancel()
        cancel()
        let idle = prepared
        prepared = nil
        // Stop hardware before awaiting model cleanup, which can be slow.
        await input.stop()
        await idle?.analyzer?.cancelAndFinishNow()
        _ = try? await pending?.value
        onReadiness?(.unavailable("Microphone is paused."))
    }
}
