import AVFoundation
import Foundation
import OSLog

enum VoicePlaybackChannel: Sendable, CaseIterable, Hashable {
    case realtime, system, local
}

struct VoicePlaybackRoute: Sendable {
    let id: UUID
    let isReady: @Sendable () -> Bool
    let schedule: @Sendable (Data, @escaping @Sendable () -> Void) -> Void
    let play: @Sendable () -> Void
    let stop: @Sendable () -> Void
}

struct VoicePlaybackOutputs: Sendable {
    let realtime: VoicePlaybackRoute
    let system: VoicePlaybackRoute
    let local: VoicePlaybackRoute

    func route(for channel: VoicePlaybackChannel) -> VoicePlaybackRoute {
        switch channel {
        case .realtime: realtime
        case .system: system
        case .local: local
        }
    }
}

protocol VoicePlaybackRouting: Sendable {
    var playbackChannel: VoicePlaybackChannel { get }
    var playbackRoutingAvailable: Bool { get }
    var playbackActive: Bool { get }
    func setPlaybackRoute(_ route: VoicePlaybackRoute?)
}

extension VoicePlaybackRouting {
    var playbackRoutingAvailable: Bool { true }
    var playbackActive: Bool { false }
}

/// Owns one converter and bounded stream per recording. The Speech framework's
/// AnalyzerInput wrapper is gone with the on-device backend — this feed yields
/// converted PCM buffers directly. No Task is allocated per audio callback;
/// buffers are copied/converted before leaving the tap's lifetime.
final class ConvertedAudioFeed: @unchecked Sendable {
    let stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>
    private let continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
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
    private var emittedFrames = 0
    private var peakRMS: Float = 0
    private var hasFloatSamples = false

    init(input: AVAudioFormat, output: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw VoiceError("The microphone format cannot be converted for the realtime lane.")
        }
        self.converter = converter; self.inputFormat = input; self.outputFormat = output
        let pair = AsyncThrowingStream<AVAudioPCMBuffer, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
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
            if case .dropped = continuation.yield(output) {
                continuation.finish(throwing: VoiceError("Speech processing could not keep up. Recording stopped without submitting incomplete speech."))
            } else {
                emittedFrames += 1
            }
        }
    }
    func level() -> Float { lock.lock(); defer { lock.unlock() }; return meter }
    func emittedFrameCount() -> Int {
        conversionLock.lock(); defer { conversionLock.unlock() }; return emittedFrames
    }
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
        // the stream, or the final audio frames never reach the socket.
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
            if output.frameLength > 0 {
                if case .dropped = continuation.yield(output) {
                    continuation.finish(throwing: VoiceError("Speech processing could not finish the audio.")); return
                }
                emittedFrames += 1
            }
            if status == .endOfStream { continuation.finish(); return }
        }
        continuation.finish(throwing: VoiceError("Speech audio finalization did not complete."))
    }
}

/// Streams model speech to the speaker. Buffers schedule as deltas arrive;
/// the played counter backs `conversation.item.truncate` so a barge-in tells
/// the server exactly how much audio actually reached the user's ears.
final class RealtimePlayer: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis.voice", category: "player")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "voice.realtime.player", qos: .userInitiated)
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var scheduledMs = 0.0
    private var playedMs = 0.0
    private var currentItemID: String?
    /// Played total when the current item started — playedMs is cumulative
    /// across items, so per-item progress is the delta from this. The
    /// scheduled ledger can't be the baseline: the previous item's unplayed
    /// remainder (ring-dropped or still buffered) would count against this
    /// item and clamp the truncation point below what the user heard.
    private var itemStartPlayedMs = 0.0
    /// Completion handlers of discarded buffers fire AFTER interrupt()
    /// resets the counters — this epoch makes them inert instead of
    /// re-inflating playedMs into an instant-false "drained" state.
    private var generation: UInt64 = 0
    /// Deltas still arriving for a cancelled response keep their item ids
    /// — dropping them stops dead speech reviving over a barge-in. One
    /// response can span several items, so ids accumulate until its
    /// response.done lands (responseDidFinish).
    private var interruptedItemIDs: Set<String> = []
    /// A cancelled response can still emit deltas for items we never saw —
    /// drop everything until the server confirms it finished.
    private var droppingUntilDone = false
    private var running = false
    /// Jitter prebuffer — ~120ms of scheduled audio must sit ahead of the
    /// speaker before play(): a network stall or CPU contention then eats
    /// buffered ms instead of crackling mid-word. The deadline starts
    /// replies that never reach the threshold (short utterances).
    private static let jitterBufferMs = 120.0
    private var playing = false
    private var primeWork: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?
    private var playbackRoute: VoicePlaybackRoute?
    /// Raised whenever the queue fully drains — used to settle a turn.
    var onPlaybackIdle: (@Sendable () -> Void)?
    var onPlaybackUnavailable: (@Sendable () -> Void)?
    var generationToken: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }
    /// True when nothing is scheduled or everything scheduled already played —
    /// response.done arrives before the speaker finishes, so turn-end must
    /// wait on this or the UI closes mid-sentence.
    var playbackIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduledMs == 0 || playedMs >= scheduledMs - 0.5
    }

    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                               channels: 1, interleaved: true)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        // An output device that vanishes (DAC pulled, AirPods dropped) kills
        // the render — without this, running stays true, every later enqueue
        // lands on a dead node, and the drain counter never moves.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.running = false }
        }
    }

    /// Warms the output engine only — priming owns play(), or a prewarm
    /// would defeat the jitter buffer.
    func ensureRunning() {
        queue.async { [weak self] in self?.ensureRunningLocked() }
    }

    func setPlaybackRoute(_ route: VoicePlaybackRoute?) {
        _ = interrupt()
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.stop()
            self.running = false
            self.playbackRoute = route
        }
    }

    func enqueue(_ pcm: Data, itemID: String, owner: UInt64? = nil) {
        // An odd-length delta would copy one byte past the int16 buffer —
        // untrusted wire input gets a hard bound, not a heap write.
        guard pcm.count.isMultiple(of: 2), !pcm.isEmpty else { return }
        let expected = owner ?? generationToken
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.generation != expected || self.droppingUntilDone || self.interruptedItemIDs.contains(itemID) {
                self.lock.unlock(); return
            }
            if self.currentItemID != itemID {
                self.currentItemID = itemID
                self.itemStartPlayedMs = self.playedMs
            }
            let gen = self.generation
            self.lock.unlock()
            guard self.ensureRunningLocked() else { self.onPlaybackUnavailable?(); return }
            let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
            let ms = Double(frames) / 24.0
            if let route = self.playbackRoute {
                self.lock.lock(); self.scheduledMs += ms; self.lock.unlock()
                route.schedule(pcm) { [weak self] in self?.completedBuffer(generation: gen, milliseconds: ms) }
                self.maybeStartPlayback()
                return
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: frames),
                  let dst = buffer.int16ChannelData?[0] else { return }
            buffer.frameLength = frames
            dst.withMemoryRebound(to: UInt8.self, capacity: Int(frames) * MemoryLayout<Int16>.size) {
                pcm.copyBytes(to: $0, count: Int(frames) * MemoryLayout<Int16>.size)
            }
            self.lock.lock(); self.scheduledMs += ms; self.lock.unlock()
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.completedBuffer(generation: gen, milliseconds: ms)
            }
            self.maybeStartPlayback()
        }
    }

    private func completedBuffer(generation expected: UInt64, milliseconds: Double) {
        lock.lock()
        guard generation == expected else { lock.unlock(); return }
        playedMs += milliseconds
        let drained = playedMs >= scheduledMs - 0.5
        if drained { playing = false }
        lock.unlock()
        if drained { onPlaybackIdle?() }
    }

    @discardableResult
    private func ensureRunningLocked() -> Bool {
        if let route = playbackRoute {
            guard route.isReady() else { running = false; return false }
            running = true
            lock.lock(); let resume = playing; lock.unlock()
            if resume { route.play() }
            return true
        }
        // `running` is our cache — the engine's own state is the truth, so a
        // config change or a device loss still gets a real restart attempt.
        if !running || !engine.isRunning {
            do {
                try engine.start()
                running = true
            } catch {
                Self.log.notice("player_start_failed \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        lock.lock(); let resume = playing; lock.unlock()
        if resume { player.play() }
        return true
    }

    /// Jitter prebuffer: the first play() of a stream waits until ~120ms
    /// of audio sits ahead of the speaker, so a mid-reply stall drains the
    /// buffer instead of crackling. The deadline releases replies shorter
    /// than the threshold rather than holding them forever.
    private func maybeStartPlayback() {
        lock.lock()
        let buffered = scheduledMs - playedMs
        if playing || buffered <= 0 { lock.unlock(); return }
        if buffered >= Self.jitterBufferMs {
            playing = true
            lock.unlock()
            primeWork?.cancel(); primeWork = nil
            ensureRunningLocked()
            return
        }
        if primeWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.startPlayback() }
            primeWork = work
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(Self.jitterBufferMs)), execute: work)
        }
        lock.unlock()
    }

    private func startPlayback() {
        lock.lock()
        primeWork = nil
        guard !playing, scheduledMs - playedMs > 0 else { lock.unlock(); return }
        playing = true
        lock.unlock()
        ensureRunningLocked()
    }

    /// The interrupted response's response.done (or a fresh session) —
    /// its items can emit no more deltas, so the drop rules go stale.
    func responseDidFinish() {
        queue.async { [weak self] in
            self?.droppingUntilDone = false
            self?.interruptedItemIDs.removeAll()
        }
    }

    /// Stop playback and drop everything queued — the local half of barge-in.
    /// Returns (itemID, playedMs) so the caller can truncate server-side.
    /// `untilResponseDone` is set when the interrupted response's done event
    /// is still outstanding: its unseen items keep dripping deltas, so ALL
    /// audio drops until responseDidFinish().
    @discardableResult
    func interrupt(untilResponseDone: Bool = false, owner: UInt64? = nil) -> (itemID: String?, playedMs: Int) {
        lock.lock()
        guard owner == nil || owner == generation else { lock.unlock(); return (nil, 0) }
        let item = currentItemID
        let played = max(0, Int((playedMs - itemStartPlayedMs).rounded(.down)))
        scheduledMs = 0; playedMs = 0; itemStartPlayedMs = 0
        currentItemID = nil
        if let item { interruptedItemIDs.insert(item) }
        droppingUntilDone = droppingUntilDone || untilResponseDone
        generation += 1
        let interruptedGeneration = generation
        playing = false
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation == interruptedGeneration
            self.lock.unlock()
            guard current else { return }
            self.primeWork?.cancel(); self.primeWork = nil
            self.player.stop()
            self.playbackRoute?.stop()
            // interrupt() only halts the node — running stays true, so the
            // next enqueue's ensureRunningLocked must see false or it never
            // calls play() again and every reply goes to a dead node.
            self.running = false
        }
        lock.unlock()
        return (item, played)
    }

    func stop() {
        _ = interrupt()
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.stop()
            self.playbackRoute?.stop()
            self.running = false
            self.primeWork?.cancel(); self.primeWork = nil
            self.droppingUntilDone = false
            self.interruptedItemIDs.removeAll()
        }
    }
}
