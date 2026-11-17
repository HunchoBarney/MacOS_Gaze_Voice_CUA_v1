import AVFoundation
import CoreML
import FluidAudio
import Foundation
import JevVoiceCore
import OSLog

enum LocalModelPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JevVoice", isDirectory: true).appendingPathComponent("Models", isDirectory: true)
    }
}

enum LocalSpeechError: Error, LocalizedError {
    case unavailable, busy, stale, captureLoss, tooShort, emptyFinal, deadline
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Local speech models are unavailable. Prepare them before speaking."
        case .busy: return "The previous speech turn is still finishing. Please try again."
        case .stale: return "That speech turn was cancelled."
        case .captureLoss: return "Some speech audio was lost. No command was submitted."
        case .tooShort: return "The recording was too short to recognize safely."
        case .emptyFinal: return "I could not recognize that recording. No command was submitted."
        case .deadline: return "Speech finalization took too long. No command was submitted."
        }
    }
}

/// Copy native buffers before leaving the tap lifetime; no unchecked buffer sharing.
struct VoicePCMFrame: Sendable {
    let bytes: Data
    let sampleRate: Double
    let isFloat: Bool
    let frames: Int

    init(samples: [Float], sampleRate: Double = 16_000) throws {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0 else { throw LocalSpeechError.captureLoss }
        bytes = samples.withUnsafeBytes { Data($0) }
        self.sampleRate = sampleRate
        isFloat = true
        frames = samples.count
    }

    init(copying buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.channelCount == 1, buffer.frameLength > 0,
              buffer.frameLength <= 65_536, buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate > 0 else { throw LocalSpeechError.captureLoss }
        frames = Int(buffer.frameLength); sampleRate = buffer.format.sampleRate
        if buffer.format.commonFormat == .pcmFormatInt16, let source = buffer.int16ChannelData?[0] {
            isFloat = false; bytes = Data(bytes: source, count: frames * MemoryLayout<Int16>.size)
        } else if buffer.format.commonFormat == .pcmFormatFloat32, let source = buffer.floatChannelData?[0] {
            isFloat = true; bytes = Data(bytes: source, count: frames * MemoryLayout<Float>.size)
        } else { throw LocalSpeechError.captureLoss }
    }

    func buffer() throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: isFloat ? .pcmFormatFloat32 : .pcmFormatInt16,
                                        sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw LocalSpeechError.captureLoss
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if isFloat, let target = buffer.floatChannelData?[0] {
            _ = bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: target, count: bytes.count))
        } else if let target = buffer.int16ChannelData?[0] {
            _ = bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: target, count: bytes.count))
        } else { throw LocalSpeechError.captureLoss }
        return buffer
    }
}

struct VoiceSpeechDiagnostic: Sendable {
    let turn: UUID
    let stage: String
    var monotonic = ProcessInfo.processInfo.systemUptime
    var metrics: [String: Double] = [:]
}

protocol LocalTranscriptProvider: Actor {
    nonisolated var evidenceSink: CallbackCell<VoiceSpeechDiagnostic>? { get }
    nonisolated var readyForTurn: Bool { get }
    nonisolated var preparedForCapture: Bool { get }
    func prepare() async throws
    func beginHold(_ turn: VoiceTurnToken, partial: @escaping @Sendable (VoiceTurnToken, String) -> Void) async throws
    func beginRecordedUtterance(_ turn: VoiceTurnToken) async throws
    func appendHold(_ turn: VoiceTurnToken, frame: VoicePCMFrame) async throws
    func finishHold(_ turn: VoiceTurnToken) async throws -> String
    func cancelHold(_ turn: VoiceTurnToken) async
}

extension LocalTranscriptProvider {
    nonisolated var evidenceSink: CallbackCell<VoiceSpeechDiagnostic>? { nil }
    func beginRecordedUtterance(_ turn: VoiceTurnToken) async throws {
        try await beginHold(turn) { _, _ in }
    }
}

/// One persistent incumbent provider. Internal EOU is never a command final.
actor LocalTranscriber: LocalTranscriptProvider {
    private nonisolated let evidenceCell = CallbackCell<VoiceSpeechDiagnostic>()
    nonisolated var evidenceSink: CallbackCell<VoiceSpeechDiagnostic>? { evidenceCell }
    private static let finalLog = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "local-final")
    static let shared = LocalTranscriber()
    enum State: Sendable, Equatable { case unloaded, downloading, ready, failed(String) }
    private let stateBox = LockedBox<State>(.unloaded)
    private let available = LockedBox(false)
    private let debounceBox: LockedBox<Int>
    private let partialCell = CallbackCell<String>()
    private let finalCell = CallbackCell<String>()
    private let progressCell = CallbackCell<Double>()
    private let modelsDirectory: URL
    private let beforePartialProcess: (@Sendable () async -> Void)?
    private let beforeFinalDecode: (@Sendable () async -> Void)?
    private let partialComputeUnits: MLComputeUnits?
    private let finalDecoderComputeUnits: MLComputeUnits?
    private var partialResets = 0
    private var partialCallbackInstalls = 0
    private var partialModelEntries = 0
    private var partialNativeActive = 0
    private var processActivity: NSObjectProtocol?
    private var partialSetupPending = false
    struct PartialDiagnostics: Sendable {
        let resets: Int
        let callbackInstalls: Int
        let modelEntries: Int
        let nativeActive: Int
        let hasProcessActivity: Bool
        let idle: Bool
    }
    var partialDiagnostics: PartialDiagnostics {
        .init(resets: partialResets, callbackInstalls: partialCallbackInstalls,
              modelEntries: partialModelEntries, nativeActive: partialNativeActive,
              hasProcessActivity: processActivity != nil,
              idle: !partialSetupPending && eouTail?.completed.value != false)
    }
    private var eou: StreamingEouAsrManager?
    private var asr: AsrManager?
    private var loadTask: Task<Void, Error>?
    private var activeHold: VoiceTurnToken?
    private var invalidated = false
    private var inFlightTurn: VoiceTurnToken?
    private var finishing = false
    private var partialsEnabled = false
    private var samples: [Float] = []
    private var eouTail: (id: Int, task: Task<Void, Never>, completed: LockedBox<Bool>)?
    private var eouTailSeq = 0
    private var largestPartialInput = 0
    private let converter = AudioConverter()
    private var legacyTurn: VoiceTurnToken?
    static let maximumCaptureSamples = 60 * 16_000
    // ms160 EOU advances by 80ms. Smaller calls bound the queued work
    // between finishing checks, even when AVAudioEngine gives large taps.
    static let partialInputLimit = 1280

    static func partialRanges(sampleCount: Int) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        return stride(from: 0, to: sampleCount, by: partialInputLimit).map {
            $0..<min(sampleCount, $0 + partialInputLimit)
        }
    }

    init(modelsDirectory: URL = LocalModelPaths.root, eouDebounceMs: Int = 1280,
         partialComputeUnits: MLComputeUnits? = nil, finalDecoderComputeUnits: MLComputeUnits? = .cpuOnly,
         beforePartialProcess: (@Sendable () async -> Void)? = nil,
         beforeFinalDecode: (@Sendable () async -> Void)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.beforePartialProcess = beforePartialProcess
        self.beforeFinalDecode = beforeFinalDecode
        self.partialComputeUnits = partialComputeUnits
        self.finalDecoderComputeUnits = finalDecoderComputeUnits
        debounceBox = LockedBox(eouDebounceMs)
    }

    nonisolated var readyForTurn: Bool { stateBox.value == .ready && available.value }
    nonisolated var preparedForCapture: Bool { stateBox.value == .ready }
    nonisolated var state: State { stateBox.value }
    nonisolated var eouDebounceMs: Int {
        get { debounceBox.value }
        set { debounceBox.set(newValue) }
    }
    nonisolated var onPartial: (@Sendable (String) -> Void)? {
        get { partialCell.get() }
        set { partialCell.set(newValue) }
    }
    nonisolated var onFinal: (@Sendable (String) -> Void)? {
        get { finalCell.get() }
        set { finalCell.set(newValue) }
    }
    nonisolated var onProgress: (@Sendable (Double) -> Void)? {
        get { progressCell.get() }
        set { progressCell.set(newValue) }
    }

    func prepare() async throws {
        if asr != nil, eou != nil { return }
        if let loadTask { try await loadTask.value; return }
        stateBox.set(.downloading) // Historical state name; only local loading occurs.
        let task = Task {
            let ultra = self.modelsDirectory.appendingPathComponent(Repo.parakeetUltra.folderName)
            guard FileManager.default.fileExists(atPath: ultra.path) else { throw LocalSpeechError.unavailable }
            let finalConfiguration: MLModelConfiguration? = self.finalDecoderComputeUnits.map {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = $0
                return configuration
            }
            let finalLoadStarted = ProcessInfo.processInfo.systemUptime
            Self.finalLog.notice("prepare stage=final_models begin")
            let loaded = try AsrModels.loadLocal(from: ultra, version: .ultra,
                configuration: finalConfiguration, encoderComputeUnits: .cpuAndNeuralEngine)
            Self.finalLog.notice("prepare stage=final_models elapsed_ms=\((ProcessInfo.processInfo.systemUptime - finalLoadStarted) * 1000)")
            let partialConfiguration = MLModelConfiguration()
            if let units = self.partialComputeUnits { partialConfiguration.computeUnits = units }
            let stream = StreamingEouAsrManager(configuration: partialConfiguration,
                chunkSize: .ms160, eouDebounceMs: self.debounceBox.value)
            let partialLoadStarted = ProcessInfo.processInfo.systemUptime
            Self.finalLog.notice("prepare stage=partial_models begin")
            try await stream.loadModels(from: self.modelsDirectory.appendingPathComponent("parakeet-eou-streaming/160ms"))
            Self.finalLog.notice("prepare stage=partial_models elapsed_ms=\((ProcessInfo.processInfo.systemUptime - partialLoadStarted) * 1000)")
            self.asr = AsrManager(models: loaded); self.eou = stream
            self.stateBox.set(.ready); self.available.set(true)
        }
        loadTask = task
        do { try await task.value; loadTask = nil }
        catch {
            loadTask = nil; available.set(false); stateBox.set(.failed(error.localizedDescription))
            throw error
        }
    }

    func beginHold(_ turn: VoiceTurnToken, partial: @escaping @Sendable (VoiceTurnToken, String) -> Void) async throws {
        try await beginHold(turn, partial: partial, previews: true)
    }

    func beginRecordedUtterance(_ turn: VoiceTurnToken) async throws {
        try await beginHold(turn, partial: { _, _ in }, previews: false)
    }

    private func beginHold(_ turn: VoiceTurnToken,
                           partial: @escaping @Sendable (VoiceTurnToken, String) -> Void,
                           previews: Bool) async throws {
        guard state == .ready, let eou, asr != nil else { throw LocalSpeechError.unavailable }
        guard activeHold == nil, inFlightTurn == nil else { throw LocalSpeechError.busy }
        activeHold = turn; invalidated = false; finishing = false; samples = []
        processActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Recognizing a voice command")
        largestPartialInput = 0
        partialsEnabled = false
        available.set(false)
        inFlightTurn = turn
        defer {
            if inFlightTurn == turn { inFlightTurn = nil }
            if invalidated { releaseHold(turn) }
        }
        guard previews else { return }
        // A slow old EOU inference may finish in the background, retaining its
        // old callback identity. Never reset/reassign it until the whole chain
        // has returned; this hold can still bank audio and produce a real final.
        guard !partialSetupPending, eouTail?.completed.value != false else {
            Self.finalLog.notice("capture generation=\(turn.generation) partials_deferred=true")
            return
        }
        partialSetupPending = true
        defer { partialSetupPending = false }
        eouTail = nil
        await eou.reset()
        partialResets += 1
        await eou.setPartialCallback { text in partial(turn, text) }
        partialCallbackInstalls += 1
        guard activeHold == turn, !invalidated else { throw LocalSpeechError.stale }
        partialsEnabled = true
    }

    func appendHold(_ turn: VoiceTurnToken, frame: VoicePCMFrame) async throws {
        guard activeHold == turn, !invalidated else { throw LocalSpeechError.stale }
        guard inFlightTurn == nil, !finishing, eou != nil else { throw LocalSpeechError.captureLoss }
        inFlightTurn = turn
        defer {
            if inFlightTurn == turn { inFlightTurn = nil }
            if invalidated { releaseHold(turn) }
        }
        do {
            let buffer = try frame.buffer()
            let converted = try converter.resampleBuffer(buffer)
            guard !converted.isEmpty, samples.count + converted.count <= Self.maximumCaptureSamples else {
                throw LocalSpeechError.captureLoss
            }
            samples.append(contentsOf: converted)
            guard partialsEnabled else { return }
            // EOU output is provisional display only: it must never pace the
            // capture bank or the release-to-final deadline. Banking completes
            // synchronously; the per-chunk decode drains on an ordered tail
            // that stops as soon as the hold finishes.
            largestPartialInput = max(largestPartialInput, converted.count)
            for range in Self.partialRanges(sampleCount: converted.count) {
                let modelBuffer = try Self.floatBuffer(Array(converted[range]))
                let previous = eouTail
                let completed = LockedBox(false)
                eouTailSeq += 1
                eouTail = (eouTailSeq, Task { [weak self] in
                    defer { completed.set(true) }
                    _ = await previous?.task.value
                    await self?.processPartial(turn, buffer: modelBuffer)
                }, completed)
            }
            guard activeHold == turn, !invalidated else { throw LocalSpeechError.stale }
        } catch {
            invalidated = true
            throw error
        }
    }

    func finishHold(_ turn: VoiceTurnToken) async throws -> String {
        guard activeHold == turn, !invalidated else { throw LocalSpeechError.stale }
        guard inFlightTurn == nil, !finishing, eou != nil, let asr else { throw LocalSpeechError.captureLoss }
        finishing = true; inFlightTurn = turn
        let wholeHold = samples
        let largestInput = largestPartialInput
        let generation = turn.generation
        let observe = evidenceCell.get()
        observe?(.init(turn: turn.id, stage: "provider.finish_enter", metrics: [
            "generation": Double(generation), "samples": Double(wholeHold.count),
            "largest_partial_input": Double(largestInput), "native_partials": Double(partialNativeActive),
            "partial_tail_pending": eouTail?.completed.value == false ? 1 : 0,
            "process_activity": processActivity != nil ? 1 : 0]))
        Self.finalLog.notice("finalize generation=\(generation) start samples=\(wholeHold.count) largest_input=\(largestInput) partial_limit=\(Self.partialInputLimit)")
        defer {
            if inFlightTurn == turn { inFlightTurn = nil }
            releaseHold(turn)
        }
        guard wholeHold.count >= 4800 else { throw LocalSpeechError.tooShort }
        // Partial display is not an authoritative dependency. Retain its tail
        // for next-hold isolation, but start the whole-hold final immediately.
        Self.finalLog.notice("finalize generation=\(generation) provisional_pending=\(self.eouTail?.completed.value == false)")
        try Task.checkCancellation()
        let layersStarted = ProcessInfo.processInfo.systemUptime
        observe?(.init(turn: turn.id, stage: "provider.decoder_layers_begin"))
        Self.finalLog.notice("finalize generation=\(generation) decoder_layers_begin native_partials=\(self.partialNativeActive)")
        let layers = await asr.decoderLayerCount
        observe?(.init(turn: turn.id, stage: "provider.decoder_layers_end",
                       metrics: ["elapsed_ms": (ProcessInfo.processInfo.systemUptime - layersStarted) * 1000]))
        Self.finalLog.notice("finalize generation=\(generation) decoder_layers_ms=\((ProcessInfo.processInfo.systemUptime - layersStarted) * 1000)")
        try Task.checkCancellation()
        guard activeHold == turn, !invalidated else { throw LocalSpeechError.stale }
        await beforeFinalDecode?()
        try Task.checkCancellation()
        guard activeHold == turn, !invalidated else { throw LocalSpeechError.stale }
        var decoder = TdtDecoderState.make(decoderLayers: layers)
        // FluidAudio transcribe handles long input by chunking; no 30s truncation.
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        observe?(.init(turn: turn.id, stage: "provider.decode_begin"))
        defer {
            observe?(.init(turn: turn.id, stage: "provider.decode_settled", metrics: [
                "elapsed_ms": (ProcessInfo.processInfo.systemUptime - decodeStarted) * 1000,
                "cancelled": Task.isCancelled ? 1 : 0]))
            Self.finalLog.notice("finalize generation=\(generation) ultra_settled_ms=\((ProcessInfo.processInfo.systemUptime - decodeStarted) * 1000) cancelled=\(Task.isCancelled)")
        }
        let decoded = try await asr.transcribe(wholeHold, decoderState: &decoder)
        observe?(.init(turn: turn.id, stage: "provider.decode_returned"))
        Self.finalLog.notice("finalize generation=\(generation) ultra_ms=\((ProcessInfo.processInfo.systemUptime - decodeStarted) * 1000)")
        guard activeHold == turn, !invalidated else { throw LocalSpeechError.stale }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalSpeechError.emptyFinal }
        return text
    }

    func cancelHold(_ turn: VoiceTurnToken) {
        guard activeHold == turn else { return }
        evidenceCell.call(.init(turn: turn.id, stage: "provider.cancel_requested"))
        invalidated = true
        // A deadline/cancellation orphans the in-flight finalize: it keeps
        // its copied audio, but must not hold this turn's flags or the next
        // capture sees busy/unavailable until the orphaned decode drains.
        // The orphan's post-decode `activeHold == turn` check discards it,
        // and its owner-scoped defer cannot clear a later turn's flag.
        if inFlightTurn == turn { inFlightTurn = nil }
        releaseHold(turn)
    }

    /// Ordered provisional streaming for partials. Never awaited by capture;
    /// skips stale or finished holds, so a lagging decode cannot block release.
    private func processPartial(_ turn: VoiceTurnToken, buffer: AVAudioPCMBuffer) async {
        guard activeHold == turn, !invalidated, !finishing, let eou else { return }
        await beforePartialProcess?()
        guard activeHold == turn, !invalidated, !finishing else { return }
        partialModelEntries += 1
        partialNativeActive += 1
        defer { partialNativeActive -= 1 }
        _ = try? await eou.process(audioBuffer: buffer)
    }

    private func releaseHold(_ turn: VoiceTurnToken) {
        guard activeHold == turn else { return }
        if let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
        activeHold = nil; samples = []; finishing = false; partialsEnabled = false
        available.set(state == .ready)
    }

    private static func floatBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                        channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw LocalSpeechError.captureLoss }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }
        return buffer
    }

    // Lifecycle compatibility while the old composition is retired in M3.
    // These wrappers never emit internal-EOU finals or decode a lost audio tail.
    nonisolated func warmUp() {
        Task { try? await self.prepare() }
    }

    func start() async {
        do {
            try await prepare()
            let turn = VoiceTurnToken(id: UUID(), generation: 0, mode: .command)
            try await beginHold(turn) { [partialCell] _, text in partialCell.call(text) }
            legacyTurn = turn
        } catch { stateBox.set(.failed(error.localizedDescription)) }
    }

    nonisolated func ingest(_ buffer: AVAudioPCMBuffer) {
        guard state == .ready else { return }
        do {
            let frame = try VoicePCMFrame(copying: buffer)
            Task { await self.appendLegacy(frame) }
        } catch {
            available.set(false); stateBox.set(.failed(LocalSpeechError.captureLoss.localizedDescription))
        }
    }

    private func appendLegacy(_ frame: VoicePCMFrame) async {
        guard let turn = legacyTurn else { return }
        do { try await appendHold(turn, frame: frame) }
        catch {
            cancelHold(turn); legacyTurn = nil
            stateBox.set(.failed(error.localizedDescription))
        }
    }

    func stop() async {
        guard let turn = legacyTurn else { return }
        legacyTurn = nil
        do { finalCell.call(try await finishHold(turn)) }
        catch { cancelHold(turn) }
    }
}
