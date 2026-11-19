import FluidAudio
import Foundation
import OSLog
@testable import JevVoice

// MARK: - Engine seam

/// The TTS backend seam. `SpeechSynthesizing` is synchronous and
/// fire-and-forget; a `LocalVoiceEngine` is the async part behind it —
/// prepare/download, stream frames, silence. Any non-GPL backend (PocketTTS
/// today, another CoreML TTS tomorrow) slots in without touching the
/// speech surface. ESpeakNG and other GPL-linked backends are deliberately
/// never wrapped behind this protocol — nothing in this lane links them.
protocol LocalVoiceEngine: Sendable {
    /// Download/load models. Throws → the voice reports unavailable and
    /// callers keep their existing speech path.
    func prepare() async throws
    /// Speak one utterance, first audio as early as the backend allows.
    /// Honours `Task` cancellation — a cancelled `say` must stop generating.
    func say(_ text: String) async throws
    /// Silence whatever is sounding right now. Idempotent.
    func cancel() async
}

enum LocalVoiceError: Error {
    /// The engine is compiled in but deliberately off — the license-review
    /// and feature-flag path.
    case disabled
}

private protocol ImmediateVoiceCancellation: Sendable {
    func cancelImmediately()
}

// MARK: - Stub engine (flag-off / license-review fallback)

/// Speaks nothing and says why. Composition installs this when the local
/// voice lane is disabled; a caller listening for silence hears the honest
/// reason in the log.
struct SilentVoiceEngine: LocalVoiceEngine, VoicePlaybackRouting, ImmediateVoiceCancellation {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.intelligence",
                                    category: "voice")
    func prepare() async throws {}
    func say(_ text: String) async throws {
        Self.log.notice("local voice unavailable — \(text.count) chars unspoken")
    }
    func cancel() async {}
    var playbackChannel: VoicePlaybackChannel { .local }
    func setPlaybackRoute(_ route: VoicePlaybackRoute?) {}
    func cancelImmediately() {}
}

// MARK: - PocketTTS engine

/// FluidAudio's PocketTTS (Apache-2.0 code in the single `FluidAudio`
/// product; upstream kyutai-labs/pocket-tts weights, MIT). No ESpeakNG is
/// linked — PocketTTS tokenizes with SentencePiece and needs no phonemizer.
///
/// First-audio latency: `synthesizeStreaming` yields 80 ms frames (1920
/// Float32 @24 kHz) as they generate; each is converted to Int16 PCM and
/// handed to a private `RealtimePlayer`, whose ~120 ms jitter prebuffer
/// starts playback while later frames still synthesize.
final class PocketVoiceEngine: LocalVoiceEngine, VoicePlaybackRouting, ImmediateVoiceCancellation, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.intelligence",
                                    category: "voice")

    private let manager: PocketTtsManager
    private let player = RealtimePlayer()
    var playbackActive: Bool { !player.playbackIdle }
    private let lock = NSLock()
    private var prepareTask: Task<Void, Error>?
    private var prepared = false
    var playbackChannel: VoicePlaybackChannel { .local }

    func setPlaybackRoute(_ route: VoicePlaybackRoute?) {
        player.setPlaybackRoute(route)
    }

    func cancelImmediately() {
        _ = player.interrupt()
    }

    /// - Parameter directory: model cache root. `PocketTtsModelStore`/
    ///   `PocketTtsResourceDownloader` treat it as the base cache directory
    ///   and lay the `pocket-tts-coreml` repo out under it.
    init(directory: URL? = LocalModelPaths.root) {
        manager = PocketTtsManager(directory: directory)
    }

    /// First call downloads the English pack (~550–770 MB per FluidAudio's
    /// manifest); later calls join the in-flight prepare. Failure leaves
    /// `prepared == false` so a later `say` retries.
    func prepare() async throws {
        lock.lock()
        if prepared { lock.unlock(); return }
        if let task = prepareTask {
            lock.unlock()
            return try await task.value
        }
        let task = Task { [manager] in try await manager.initialize() }
        prepareTask = task
        lock.unlock()
        do {
            try await task.value
            lock.lock(); prepared = true; prepareTask = nil; lock.unlock()
        } catch {
            lock.lock(); prepareTask = nil; lock.unlock()
            throw error
        }
    }

    /// Stream one utterance to the speaker. Runs until the stream ends or
    /// the caller's Task cancels — frames stop enqueuing immediately.
    func say(_ text: String) async throws {
        let owner = player.generationToken
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        let itemID = "local-tts-\(UUID().uuidString)"
        player.ensureRunning()
        let stream = try await manager.synthesizeStreaming(text: text)
        for try await frame in stream {
            try Task.checkCancellation()
            if let pcm = Self.int16PCM(frame.samples) {
                player.enqueue(pcm, itemID: itemID, owner: owner)
            }
        }
    }

    func cancel() async {
        cancelImmediately()
    }

    /// Float32 [-1, 1] @24 kHz → little-endian Int16 PCM `Data`, the exact
    /// wire format `RealtimePlayer.enqueue` expects.
    static func int16PCM(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty else { return nil }
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            guard let out = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for (index, sample) in samples.enumerated() {
                let clamped = max(-1, min(1, sample))
                out[index] = Int16((clamped * 32767).rounded())
            }
        }
        return data
    }
}

// MARK: - SpeechSynthesizing surface

/// The local `SpeechSynthesizing` — synchronous protocol over an async
/// engine, matching how `SpeechOutput` wraps AVSpeechSynthesizer: `speak`
/// launches work, `stop` silences. This historical adapter is retained
/// only for the local speech compatibility tests.
final class LocalVoice: SpeechSynthesizing, VoicePlaybackRouting, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.intelligence",
                                    category: "voice")

    /// Process-wide kill switch for the PocketTTS lane (pending full
    /// license review of upstream weights). `shared` consults it at init.
    nonisolated(unsafe) static var pocketEngineEnabled = true

    static let shared = LocalVoice()

    private let engine: any LocalVoiceEngine
    private let lock = NSLock()
    private var speakTask: Task<Void, Never>?
    var playbackChannel: VoicePlaybackChannel { .local }
    var playbackRoutingAvailable: Bool {
        (engine as? any VoicePlaybackRouting)?.playbackRoutingAvailable == true
    }
    var playbackActive: Bool { (engine as? any VoicePlaybackRouting)?.playbackActive == true }

    func setPlaybackRoute(_ route: VoicePlaybackRoute?) {
        stop()
        (engine as? any VoicePlaybackRouting)?.setPlaybackRoute(route)
    }

    /// - Parameters:
    ///   - engine: nil = PocketTTS when `pocketEngineEnabled`, else the
    ///     silent stub. Inject a fake in tests.
    ///   - enabled: per-instance override of `pocketEngineEnabled`.
    init(engine: (any LocalVoiceEngine)? = nil, enabled: Bool? = nil) {
        let on = enabled ?? Self.pocketEngineEnabled
        self.engine = engine ?? (on ? PocketVoiceEngine() : SilentVoiceEngine())
    }

    /// Pre-flight for composition — true when the engine's models are
    /// (or became) ready. Safe to call at launch or Fn-down.
    @discardableResult
    func prepare() async -> Bool {
        do {
            try await engine.prepare()
            return true
        } catch {
            Self.log.notice("local voice unavailable — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        speakTask?.cancel()
        let engine = self.engine
        let immediate = engine as? any ImmediateVoiceCancellation
        immediate?.cancelImmediately()
        speakTask = Task {
            // Silence whatever the previous speak left sounding, then say
            // this one — two overlapping utterances is the two-voices bug.
            guard !Task.isCancelled else { return }
            if immediate == nil { await engine.cancel() }
            guard !Task.isCancelled else { return }
            do {
                try await engine.say(trimmed)
            } catch is CancellationError {
                // Replaced by a newer speak or a stop() — silent by design.
            } catch {
                Self.log.notice("local voice unavailable — \(error.localizedDescription, privacy: .public)")
            }
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let task = speakTask
        speakTask = nil
        task?.cancel()
        if let immediate = engine as? any ImmediateVoiceCancellation {
            immediate.cancelImmediately()
        } else {
            Task { [engine] in await engine.cancel() }
        }
        lock.unlock()
    }
}
