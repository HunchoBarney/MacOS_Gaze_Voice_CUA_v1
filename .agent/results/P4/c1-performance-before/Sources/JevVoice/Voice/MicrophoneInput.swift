import AVFoundation
import Foundation
import Darwin
import OSLog
import os

/// The tap runs whether or not a feed is attached — a hold's `.starting`
/// window (permission hop, prepare await, up to ~10s on a cold socket)
/// used to drop every spoken frame, so the model heard a fragment. The
/// gate keeps a ~1s pre-roll ring of copied tap audio while closed;
/// open() flushes the post-press part ahead of live frames, close()
/// discards it so idle room noise can't bleed into the next hold.
final class MicrophoneAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var feed: ConvertedAudioFeed?
    private var openedAt: UInt64 = 0
    /// Buffered tap audio captured while the gate was closed, oldest first.
    private var preRoll: [(buffer: AVAudioPCMBuffer, hostTime: UInt64)] = []
    private var preRollSeconds = 0.0
    struct InputSnapshot: Sendable {
        var frames: UInt64 = 0
        var buffers: UInt64 = 0
        var lastHostTime: UInt64 = 0
    }
    private var inputSnapshot = InputSnapshot()
    func snapshot() -> InputSnapshot {
        lock.lock(); defer { lock.unlock() }
        return inputSnapshot
    }
    func resetInputSnapshot() {
        lock.lock(); defer { lock.unlock() }
        inputSnapshot = InputSnapshot()
    }
    /// ~1s at tap format — enough for a warm-path `.starting` gap; a cold
    /// socket clips only what precedes the last second.
    static let preRollLimit: TimeInterval = 1.0

    /// `hostTime` is the press marker (default: now). Frames wholly before
    /// it are dropped; a buffer straddling it keeps only its pressed half.
    func open(_ feed: ConvertedAudioFeed, at hostTime: UInt64 = mach_absolute_time()) {
        lock.lock(); defer { lock.unlock() }
        self.feed = feed
        openedAt = hostTime
        // Flush first — buffered frames land ahead of every live append so
        // the socket hears the hold's head in order.
        let buffered = preRoll
        preRoll = []; preRollSeconds = 0
        for entry in buffered {
            let offset = entry.hostTime < hostTime
                ? Int(ceil(AVAudioTime.seconds(forHostTime: hostTime - entry.hostTime)
                           * entry.buffer.format.sampleRate)) : 0
            guard offset < Int(entry.buffer.frameLength) else { continue }
            if offset == 0 { feed.append(entry.buffer); continue }
            if let trimmed = Self.copy(entry.buffer, droppingFirst: offset) { feed.append(trimmed) }
        }
    }
    @discardableResult
    func close() -> ConvertedAudioFeed? {
        lock.lock(); defer { lock.unlock() }
        let previous = feed
        feed = nil
        // Detach discards the ring — audio between holds is not the next
        // hold's head, it's whatever the room happened to sound like.
        preRoll = []; preRollSeconds = 0
        return previous
    }
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard time.isHostTimeValid else { return }
        inputSnapshot.frames += UInt64(buffer.frameLength)
        inputSnapshot.buffers += 1
        inputSnapshot.lastHostTime = time.hostTime
        guard let feed else {
            // Closed gate — this is the head-clip window. Ring the last
            // ~1s instead of dropping it; open() recovers the post-press
            // part verbatim.
            guard let copy = Self.copy(buffer) else { return }
            preRoll.append((copy, time.hostTime))
            preRollSeconds += Double(copy.frameLength) / copy.format.sampleRate
            while preRollSeconds > Self.preRollLimit, let oldest = preRoll.first {
                preRollSeconds -= Double(oldest.buffer.frameLength) / oldest.buffer.format.sampleRate
                preRoll.removeFirst()
            }
            return
        }
        // A tap buffer can straddle Fn down. Exclude its pre-press prefix.
        let offset = time.hostTime < openedAt
            ? Int(ceil(AVAudioTime.seconds(forHostTime: openedAt - time.hostTime) * buffer.format.sampleRate)) : 0
        guard offset < Int(buffer.frameLength) else { return }
        if offset == 0 { feed.append(buffer); return }
        guard let trimmed = Self.copy(buffer, droppingFirst: offset) else { return }
        feed.append(trimmed)
    }
    /// Tap buffers are engine-owned and die with the callback — anything
    /// held past it (pre-roll) or reshaped (pre-press trim) is a copy.
    private static func copy(_ buffer: AVAudioPCMBuffer,
                             droppingFirst offset: Int = 0) -> AVAudioPCMBuffer? {
        let count = buffer.frameLength - AVAudioFrameCount(offset)
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { return nil }
        trimmed.frameLength = count
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(trimmed.mutableAudioBufferList)
        for index in source.indices {
            guard let src = source[index].mData, let dst = target[index].mData else { return nil }
            memcpy(dst, src.advanced(by: offset * bytesPerFrame), Int(count) * bytesPerFrame)
        }
        return trimmed
    }
}

/// Device setup and teardown share a serial owner away from the main actor.
/// Only the gate crosses into the real-time tap; it never creates a Task per buffer.
final class MicrophoneInput: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "microphone")
    enum ConfigurationResponse: Equatable { case restoreTap, interrupt }
    struct PreparationState {
        enum Decision: Equatable { case wait, ready, recover, fail }
        let generation: UUID
        private(set) var tapID = UUID()
        private(set) var recoveries = 0
        private var resolved = false
        init(generation: UUID) {
            self.generation = generation
        }

        mutating func input(generation: UUID, tap: UUID, frames: UInt32,
                            validTime: Bool, running: Bool) -> Decision {
            guard !resolved, generation == self.generation, tap == tapID,
                  frames > 0, validTime, running else { return .wait }
            resolved = true
            return .ready
        }
        mutating func configuration(sameDevice: Bool, sameFormat: Bool, running: Bool) -> Decision {
            guard !resolved, sameDevice, sameFormat else {
                resolved = true
                return .fail
            }
            if recoveries > 0, running { return .wait }
            guard recoveries == 0 else {
                resolved = true
                return .fail
            }
            recoveries += 1
            tapID = UUID()
            return .recover
        }
        mutating func invalidate() -> Bool {
            guard !resolved else { return false }
            resolved = true
            return true
        }
    }
    static func configurationResponse(engineRunning: Bool, sameDevice: Bool, sameFormat: Bool) -> ConfigurationResponse {
        guard engineRunning, sameDevice, sameFormat else { return .interrupt }
        return .restoreTap
    }
    struct Ready {
        let name: String
        let format: AVAudioFormat
        let firstFrames: UInt32
        let startupRecoveries: Int
    }
    private struct Preparation {
        var state: PreparationState
        let name: String
        let continuation: CheckedContinuation<Ready, Error>
        let timeout: DispatchWorkItem
        let cancelled: OSAllocatedUnfairLock<Bool>
    }
    let gate = MicrophoneAudioGate()
    private let queue = DispatchQueue(label: "voice.microphone", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var deviceID: AudioDeviceID?
    private var preparedFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?
    private var interrupted: (@Sendable () -> Void)?
    private var pending: Preparation?
    private var ready: Ready?
    private var engineID: UUID?
    func prepare(device: MicrophoneDevice, interrupted: @escaping @Sendable () -> Void) async throws -> Ready {
        try Task.checkCancellation()
        let generation = UUID()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let result: Ready = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancelled.withLock({ $0 }) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let snapshot = self.gate.snapshot()
                    let now = mach_absolute_time()
                    let age = AVAudioTime.seconds(forHostTime: max(now, snapshot.lastHostTime) - min(now, snapshot.lastHostTime))
                    if self.deviceID == device.hardwareID, let engine = self.engine, engine.isRunning,
                       let ready = self.ready, engine.inputNode.auAudioUnit.deviceID == device.hardwareID,
                       ready.format == engine.inputNode.outputFormat(forBus: 0),
                       snapshot.frames > 0, age <= 1 {
                        self.interrupted = interrupted
                        continuation.resume(returning: ready)
                        return
                    }
                    self.stopOnQueue()
                    self.interrupted = interrupted
                    let timeout = DispatchWorkItem { [weak self] in
                        guard self?.pending?.state.generation == generation else { return }
                        self?.failPreparation(VoiceError("The microphone did not deliver audio frames within 5 seconds."))
                    }
                    let state = PreparationState(generation: generation)
                    self.pending = Preparation(state: state, name: device.name,
                        continuation: continuation, timeout: timeout, cancelled: cancelled)
                    self.queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                    do {
                        let engine = AVAudioEngine()
                        let input = engine.inputNode
                        self.engine = engine; self.engineID = generation; self.deviceID = device.hardwareID
                        self.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                            object: engine, queue: nil) { [weak self] _ in
                                self?.queue.async { [weak self] in self?.configurationChanged(generation: generation) }
                            }
                        if input.auAudioUnit.deviceID != device.hardwareID { try input.auAudioUnit.setDeviceID(device.hardwareID) }
                        let format = input.outputFormat(forBus: 0)
                        guard format.sampleRate > 0, format.channelCount > 0 else {
                            throw VoiceError("The microphone has no usable input.")
                        }
                        self.preparedFormat = format
                        self.installTap(on: input, format: format, generation: generation,
                                        tap: state.tapID)
                        engine.prepare()
                        try engine.start()
                    } catch {
                        self.failPreparation(error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            self.queue.async {
                if self.engineID == generation { self.stopOnQueue() }
            }
        }
        try Task.checkCancellation()
        return result
    }
    private func configurationChanged(generation: UUID) {
        guard engineID == generation, let engine, let preparedFormat else { return }
        let input = engine.inputNode
        let currentFormat = input.outputFormat(forBus: 0)
        let sameDevice = input.auAudioUnit.deviceID == deviceID
        let sameFormat = currentFormat == preparedFormat
        let running = engine.isRunning
        Self.log.notice("configuration running=\(running) selected_device=\(sameDevice) same_format=\(sameFormat)")
        if var pending {
            let decision = pending.state.configuration(sameDevice: sameDevice, sameFormat: sameFormat, running: running)
            self.pending = pending
            switch decision {
            case .recover:
                Self.log.notice("recovering initial input configuration before readiness")
                engine.stop()
                input.removeTap(onBus: 0)
                gate.resetInputSnapshot()
                self.preparedFormat = currentFormat
                installTap(on: input, format: currentFormat, generation: generation, tap: pending.state.tapID)
                do { try engine.start() } catch { failPreparation(error) }
            case .fail:
                failPreparation(VoiceError("The microphone configuration changed before audio was ready."))
            case .wait, .ready:
                break
            }
            return
        }
        switch Self.configurationResponse(engineRunning: running, sameDevice: sameDevice, sameFormat: sameFormat) {
        case .restoreTap:
            engine.stop()
            input.removeTap(onBus: 0)
            installTap(on: input, format: currentFormat, generation: generation, tap: UUID())
            do { try engine.start() } catch { interrupted?() }
        case .interrupt:
            ready = nil
            interrupted?()
        }
    }
    private func receivedInput(generation: UUID, tap: UUID, frames: UInt32) {
        guard var pending, pending.state.generation == generation else { return }
        guard !pending.cancelled.withLock({ $0 }) else {
            failPreparation(CancellationError())
            return
        }
        let decision = pending.state.input(generation: generation, tap: tap, frames: frames,
                                           validTime: true, running: engine?.isRunning == true)
        self.pending = pending
        guard decision == .ready, let preparedFormat else { return }
        pending.timeout.cancel()
        self.pending = nil
        let value = Ready(name: pending.name, format: preparedFormat, firstFrames: frames,
                          startupRecoveries: pending.state.recoveries)
        ready = value
        Self.log.notice("input_ready first_frames=\(frames) startup_recoveries=\(value.startupRecoveries)")
        pending.continuation.resume(returning: value)
    }
    private func failPreparation(_ error: Error) {
        guard let pending else { return }
        self.pending = nil
        pending.timeout.cancel()
        stopOnQueue()
        pending.continuation.resume(throwing: error)
    }
    func stop() async {
        gate.close()?.finish()
        await withCheckedContinuation { continuation in
            queue.async { self.stopOnQueue(); continuation.resume() }
        }
    }
    private func stopOnQueue() {
        var pending = self.pending
        self.pending = nil
        _ = pending?.state.invalidate()
        pending?.timeout.cancel()
        gate.close()?.finish()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil; engineID = nil; deviceID = nil; preparedFormat = nil; ready = nil
        gate.resetInputSnapshot()
        pending?.continuation.resume(throwing: CancellationError())
    }
    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat, generation: UUID, tap: UUID) {
        let gate = self.gate
        let notified = OSAllocatedUnfairLock(initialState: false)
        let sampleRate = format.sampleRate
        let channels = format.channelCount
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            gate.append(buffer, at: time)
            guard buffer.frameLength > 0, time.isHostTimeValid, time.hostTime > 0,
                  buffer.format.sampleRate == sampleRate, buffer.format.channelCount == channels,
                  notified.withLock({ sent in
                      guard !sent else { return false }
                      sent = true
                      return true
                  }) else { return }
            let frames = buffer.frameLength
            self?.queue.async { [weak self] in self?.receivedInput(generation: generation, tap: tap, frames: frames) }
        }
    }
}
