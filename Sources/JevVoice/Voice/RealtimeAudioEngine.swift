import AVFoundation
import Foundation
import OSLog

/// Where decoded model audio can be rendered. When the duplex engine owns
/// playback its render callback is the echo reference for AEC.
protocol RealtimeRenderSink: AnyObject {
    func enqueue(_ pcm: Data)
    func flush()
    var consumedMs: Double { get }
    /// Ms of enqueued audio the sink discarded and will never render —
    /// ring overflow, failed conversion. The player's drain ledger needs
    /// it separate from consumedMs: dropped audio resolves a turn's wait
    /// but must not count toward the truncation position the user heard.
    var droppedMs: Double { get }
    var onDrained: (@Sendable () -> Void)? { get set }
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
            if output.frameLength > 0,
               case .dropped = continuation.yield(output) {
                continuation.finish(throwing: VoiceError("Speech processing could not finish the audio.")); return
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
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "player")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "voice.realtime.player", qos: .userInitiated)
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var scheduledMs = 0.0
    private var playedMs = 0.0
    private var currentItemID: String?
    /// Scheduled total when the current item started — playedMs is
    /// cumulative across items, so per-item progress is the delta from this.
    private var itemStartScheduledMs = 0.0
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
    /// When set (the VPIO duplex backend is live), decoded audio renders
    /// through the sink instead of playerNode — the sink's render callback
    /// is the AEC echo reference. Weak: MicrophoneInput owns the engine.
    private weak var sink: RealtimeRenderSink?
    /// consumedMs is cumulative for the sink's lifetime — playedMs is the
    /// delta from this base, snapped at attach and at every interrupt.
    private var sinkBaseMs = 0.0
    /// Same base for the sink's drop ledger.
    private var sinkBaseDroppedMs = 0.0
    /// playedMs + sink-discarded ms — what the drain check waits on. Kept
    /// separate from playedMs so conversation.item.truncate still reports
    /// the audio the user actually heard while dropped frames can't hold
    /// the turn open forever.
    private var resolvedMs = 0.0
    /// 25ms poll that keeps playedMs tracking sink.consumedMs while audio
    /// is outstanding — the sink has no per-buffer completion to hook.
    private var drainPoll: DispatchSourceTimer?
    /// Raised whenever the queue fully drains — used to settle a turn.
    var onPlaybackIdle: (@Sendable () -> Void)?
    /// True when nothing is scheduled or everything scheduled already played —
    /// response.done arrives before the speaker finishes, so turn-end must
    /// wait on this or the UI closes mid-sentence.
    var playbackIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduledMs == 0 || resolvedMs >= scheduledMs - 0.5
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

    func attachSink(_ sink: RealtimeRenderSink?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sink?.onDrained = nil
            self.sink = sink
            self.lock.lock()
            self.sinkBaseMs = sink?.consumedMs ?? 0
            self.sinkBaseDroppedMs = sink?.droppedMs ?? 0
            self.lock.unlock()
            sink?.onDrained = { [weak self] in
                self?.queue.async { self?.sampleSinkProgress() }
            }
            // Whichever route plays next starts unprimed — the prebuffer
            // rebuilds on the first delta of the next stream.
            self.primeWork?.cancel(); self.primeWork = nil
            self.lock.lock(); self.playing = false; self.lock.unlock()
            if sink != nil {
                // Two live output routes would double the echo reference —
                // the VPIO unit is the only speaker path while attached.
                self.engine.stop()
                self.running = false
            } else {
                self.stopDrainPoll()
            }
        }
    }

    /// The sink's own drain signal is only a hint — the counters are the
    /// truth, so an in-flight write that hasn't landed yet can't fake a
    /// drain; the poll keeps running until the numbers actually settle.
    private func sampleSinkProgress() {
        guard let sink else { stopDrainPoll(); return }
        let consumed = sink.consumedMs
        let dropped = sink.droppedMs
        lock.lock()
        let wasDrained = scheduledMs == 0 || resolvedMs >= scheduledMs - 0.5
        playedMs = max(playedMs, consumed - sinkBaseMs)
        resolvedMs = max(resolvedMs, playedMs + (dropped - sinkBaseDroppedMs))
        let drained = scheduledMs > 0 && resolvedMs >= scheduledMs - 0.5
        if drained { resolvedMs = scheduledMs }
        lock.unlock()
        if drained { stopDrainPoll() }
        if drained, !wasDrained { onPlaybackIdle?() }
    }

    private func startDrainPoll() {
        guard drainPoll == nil else { return }
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        poll.setEventHandler { [weak self] in self?.sampleSinkProgress() }
        drainPoll = poll
        poll.resume()
    }

    private func stopDrainPoll() {
        drainPoll?.cancel()
        drainPoll = nil
    }

    /// Warms the output engine only — priming owns play(), or a prewarm
    /// would defeat the jitter buffer.
    func ensureRunning() {
        queue.async { [weak self] in self?.ensureRunningLocked() }
    }

    func enqueue(_ pcm: Data, itemID: String) {
        // An odd-length delta would copy one byte past the int16 buffer —
        // untrusted wire input gets a hard bound, not a heap write.
        guard pcm.count.isMultiple(of: 2), !pcm.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.droppingUntilDone || self.interruptedItemIDs.contains(itemID) {
                self.lock.unlock(); return
            }
            if self.currentItemID != itemID {
                self.currentItemID = itemID
                self.itemStartScheduledMs = self.scheduledMs
            }
            let gen = self.generation
            self.lock.unlock()
            self.ensureRunningLocked()
            let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
            let ms = Double(frames) / 24.0
            if let sink = self.sink {
                self.lock.lock(); self.scheduledMs += ms; self.lock.unlock()
                sink.enqueue(pcm)
                self.sampleSinkProgress()
                self.startDrainPoll()
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
                guard let self else { return }
                self.lock.lock()
                // A buffer discarded by interrupt() still fires this handler
                // after the counters reset — the epoch keeps it inert.
                guard self.generation == gen else { self.lock.unlock(); return }
                self.playedMs += ms
                self.resolvedMs = max(self.resolvedMs, self.playedMs)
                let drained = self.playedMs >= self.scheduledMs - 0.5
                // Queue empty → next stream re-primes the jitter buffer.
                if drained { self.playing = false }
                self.lock.unlock()
                if drained { self.onPlaybackIdle?() }
            }
            self.maybeStartPlayback()
        }
    }

    private func ensureRunningLocked() {
        // `running` is our cache — the engine's own state is the truth, so a
        // config change or a device loss still gets a real restart attempt.
        // Sink-attached playback owns no local engine at all.
        guard sink == nil else { return }
        if !running || !engine.isRunning {
            do {
                try engine.start()
                running = true
            } catch {
                Self.log.notice("player_start_failed \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        lock.lock(); let resume = playing; lock.unlock()
        if resume { player.play() }
    }

    /// Jitter prebuffer: the first play() of a stream waits until ~120ms
    /// of audio sits ahead of the speaker, so a mid-reply stall drains the
    /// buffer instead of crackling. The deadline releases replies shorter
    /// than the threshold rather than holding them forever.
    private func maybeStartPlayback() {
        guard sink == nil else { return }
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

    /// How much of the current item actually played — the truncation point.
    /// playedMs is cumulative, so per-item progress is the delta since the
    /// item started.
    func playedMilliseconds() -> Int {
        lock.lock(); defer { lock.unlock() }
        return max(0, Int((playedMs - itemStartScheduledMs).rounded(.down)))
    }

    /// Stop playback and drop everything queued — the local half of barge-in.
    /// Returns (itemID, playedMs) so the caller can truncate server-side.
    /// `untilResponseDone` is set when the interrupted response's done event
    /// is still outstanding: its unseen items keep dripping deltas, so ALL
    /// audio drops until responseDidFinish().
    @discardableResult
    func interrupt(untilResponseDone: Bool = false) -> (itemID: String?, playedMs: Int) {
        // The 25ms drain poll can lag the speaker by a whole interval —
        // snap the sink's counters synchronously or the truncate point
        // under-reports what the user actually heard.
        if let sink {
            let consumed = sink.consumedMs, dropped = sink.droppedMs
            lock.lock()
            playedMs = max(playedMs, consumed - sinkBaseMs)
            resolvedMs = max(resolvedMs, playedMs + (dropped - sinkBaseDroppedMs))
            lock.unlock()
        }
        lock.lock()
        let item = currentItemID
        let played = max(0, Int((playedMs - itemStartScheduledMs).rounded(.down)))
        scheduledMs = 0; playedMs = 0; resolvedMs = 0; itemStartScheduledMs = 0
        currentItemID = nil
        if let item { interruptedItemIDs.insert(item) }
        droppingUntilDone = droppingUntilDone || untilResponseDone
        generation += 1
        playing = false
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.primeWork?.cancel(); self.primeWork = nil
            // The sink's ring carries the same unplayed audio interrupt()
            // drops locally — flush it before re-basing the consumed clock.
            self.sink?.flush()
            self.lock.lock()
            self.sinkBaseMs = self.sink?.consumedMs ?? 0
            self.sinkBaseDroppedMs = self.sink?.droppedMs ?? 0
            self.lock.unlock()
            self.stopDrainPoll()
            self.player.stop()
            // interrupt() only halts the node — running stays true, so the
            // next enqueue's ensureRunningLocked must see false or it never
            // calls play() again and every reply goes to a dead node.
            self.running = false
        }
        return (item, played)
    }

    func stop() {
        _ = interrupt()
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.stop()
            self.running = false
            self.sink?.onDrained = nil
            self.sink = nil
            self.stopDrainPoll()
            self.primeWork?.cancel(); self.primeWork = nil
            self.droppingUntilDone = false
            self.interruptedItemIDs.removeAll()
        }
    }
}
