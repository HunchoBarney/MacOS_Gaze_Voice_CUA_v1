import AVFoundation
import AudioToolbox
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
    func close(ifCurrent expected: ConvertedAudioFeed? = nil) -> ConvertedAudioFeed? {
        lock.lock(); defer { lock.unlock() }
        if let expected, feed !== expected { return nil }
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
    struct DuplexReadiness {
        private var previousOutput: Int64?
        private(set) var advancedAt: TimeInterval?

        mutating func observe(inputFrames: UInt32, outputSample: Int64?, healthy: Bool,
                              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
            guard inputFrames > 0, healthy, let outputSample, now.isFinite else {
                self = Self()
                return false
            }
            if let previousOutput {
                guard outputSample >= previousOutput else { self = Self(); return false }
                if outputSample > previousOutput { advancedAt = now }
            }
            previousOutput = outputSample
            guard let advancedAt else { return false }
            guard now >= advancedAt, now - advancedAt < 0.5 else { self = Self(); return false }
            return true
        }
    }
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis.voice", category: "microphone")
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
        var playback: VoicePlaybackOutputs? = nil
    }

    static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &device)
        guard status == noErr, size == MemoryLayout<AudioDeviceID>.size, device != 0 else {
            throw VoiceError("The speaker device is unavailable.")
        }
        return device
    }

    private func currentDevice(_ node: AVAudioIONode, input: Bool) -> AudioDeviceID? {
        guard voiceProcessing else {
            let device = node.auAudioUnit.deviceID
            return device == 0 ? nil : device
        }
        guard let unit = node.audioUnit else { return nil }
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, input ? 1 : 0, &device, &size)
        guard status == noErr, size == MemoryLayout<AudioDeviceID>.size, device != 0 else { return nil }
        return device
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
    private var hardwareFormat: AVAudioFormat?
    private var voiceProcessing = false
    private var outputDeviceID: AudioDeviceID?
    private var playbackNodes: [VoicePlaybackChannel: AVAudioPlayerNode] = [:]
    private var playbackFormat: AVAudioFormat?
    private var duplexReadiness = DuplexReadiness()
    private let readyGeneration = LockedBox<UUID?>(nil)
    private let outputGeneration = LockedBox<UUID?>(nil)
    private let outputReceipt = LockedBox<(generation: UUID, advancedAt: TimeInterval)?>(nil)

    func prepare(device: MicrophoneDevice, voiceProcessing: Bool = false,
                 interrupted: @escaping @Sendable () -> Void) async throws -> Ready {
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
                    if self.deviceID == device.hardwareID, self.voiceProcessing == voiceProcessing,
                       let engine = self.engine, engine.isRunning,
                       let ready = self.ready, self.currentDevice(engine.inputNode, input: true) == device.hardwareID,
                       self.hardwareFormat == engine.inputNode.outputFormat(forBus: 0),
                       !voiceProcessing || self.duplexHealthy(),
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
                        self.voiceProcessing = voiceProcessing
                        self.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                            object: engine, queue: nil) { [weak self] _ in
                                self?.queue.async { [weak self] in self?.configurationChanged(generation: generation) }
                            }
                        if voiceProcessing {
                            let expectedOutput = try Self.defaultOutputDeviceID()
                            try input.setVoiceProcessingEnabled(true)
                            guard self.currentDevice(engine.outputNode, input: false) == expectedOutput,
                                  self.currentDevice(input, input: true) != nil else {
                                throw VoiceError("The selected microphone and speaker could not be identified.")
                            }
                            if self.currentDevice(input, input: true) != device.hardwareID {
                                guard let unit = input.audioUnit else {
                                    throw VoiceError("This microphone can't listen all the time. Hold fn to talk, or pick another microphone in Settings.")
                                }
                                input.auAudioUnit.deallocateRenderResources()
                                var selected = device.hardwareID
                                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 1, &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
                                guard status == noErr else {
                                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                                }
                            }
                            guard self.currentDevice(input, input: true) == device.hardwareID,
                                  self.currentDevice(engine.outputNode, input: false) == expectedOutput else {
                                throw VoiceError("The selected microphone or speaker changed during setup.")
                            }
                            self.outputDeviceID = expectedOutput
                        } else if input.auAudioUnit.deviceID != device.hardwareID {
                            try input.auAudioUnit.setDeviceID(device.hardwareID)
                        }
                        let deviceFormat = input.outputFormat(forBus: 0)
                        let format: AVAudioFormat
                        if voiceProcessing {
                            guard input.isVoiceProcessingEnabled, engine.outputNode.isVoiceProcessingEnabled,
                                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: deviceFormat.sampleRate, channels: 1, interleaved: false),
                                  let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: 24_000, channels: 1, interleaved: true) else {
                                throw VoiceError("This microphone can't listen all the time. Hold fn to talk, or pick another microphone in Settings.")
                            }
                            format = mono
                            self.playbackFormat = playbackFormat
                            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mono)
                            for channel in VoicePlaybackChannel.allCases {
                                let player = AVAudioPlayerNode()
                                engine.attach(player)
                                engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
                                self.playbackNodes[channel] = player
                            }
                        } else {
                            format = deviceFormat
                        }
                        guard format.sampleRate > 0, format.channelCount > 0 else {
                            throw VoiceError("The microphone has no usable input.")
                        }
                        self.preparedFormat = format
                        self.installTap(on: input, format: format, generation: generation,
                                        tap: state.tapID)
                        engine.prepare()
                        try engine.start()
                        self.hardwareFormat = input.outputFormat(forBus: 0)
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
        let sameDevice = deviceID != nil && currentDevice(input, input: true) == deviceID
            && (!voiceProcessing || (outputDeviceID != nil
                && currentDevice(engine.outputNode, input: false) == outputDeviceID))
        let sameFormat = currentFormat == hardwareFormat
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
                self.preparedFormat = voiceProcessing ? preparedFormat : currentFormat
                duplexReadiness = DuplexReadiness()
                installTap(on: input, format: self.preparedFormat ?? currentFormat,
                           generation: generation, tap: pending.state.tapID)
                do { try engine.start() } catch { failPreparation(error) }
            case .fail:
                failPreparation(VoiceError("The microphone configuration changed before audio was ready."))
            case .wait, .ready:
                break
            }
            return
        }
        if voiceProcessing {
            ready = nil
            readyGeneration.set(nil)
            outputGeneration.set(nil)
            outputReceipt.set(nil)
            interrupted?()
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
        guard engineID == generation else { return }
        if pending == nil, outputGeneration.value == generation {
            let time = engine?.outputNode.lastRenderTime
            let sample = time?.isSampleTimeValid == true ? time?.sampleTime : nil
            guard duplexReadiness.observe(inputFrames: frames, outputSample: sample,
                                           healthy: duplexHealthy()), let advanced = duplexReadiness.advancedAt else {
                outputGeneration.set(nil)
                outputReceipt.set(nil)
                interrupted?()
                return
            }
            outputReceipt.set((generation, advanced))
            return
        }
        guard var pending, pending.state.generation == generation else { return }
        guard !pending.cancelled.withLock({ $0 }) else {
            failPreparation(CancellationError())
            return
        }
        if voiceProcessing {
            let outputTime = engine?.outputNode.lastRenderTime
            let outputSample = outputTime?.isSampleTimeValid == true ? outputTime?.sampleTime : nil
            guard duplexReadiness.observe(inputFrames: frames, outputSample: outputSample,
                                           healthy: duplexHealthy()) else { return }
        }
        let decision = pending.state.input(generation: generation, tap: tap, frames: frames,
                                           validTime: true, running: engine?.isRunning == true)
        self.pending = pending
        guard decision == .ready, let preparedFormat else { return }
        pending.timeout.cancel()
        self.pending = nil
        var value = Ready(name: pending.name, format: preparedFormat, firstFrames: frames,
                          startupRecoveries: pending.state.recoveries)
        if voiceProcessing {
            guard let advanced = duplexReadiness.advancedAt else { return }
            outputReceipt.set((generation, advanced))
            outputGeneration.set(generation)
            value.playback = VoicePlaybackOutputs(
                realtime: playbackRoute(.realtime, generation: generation),
                system: playbackRoute(.system, generation: generation),
                local: playbackRoute(.local, generation: generation))
        }
        ready = value
        readyGeneration.set(generation)
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
        readyGeneration.set(nil)
        outputGeneration.set(nil)
        outputReceipt.set(nil)
        _ = pending?.state.invalidate()
        pending?.timeout.cancel()
        gate.close()?.finish()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil; engineID = nil; deviceID = nil; preparedFormat = nil; ready = nil
        hardwareFormat = nil; outputDeviceID = nil; playbackFormat = nil
        playbackNodes = [:]; voiceProcessing = false; duplexReadiness = DuplexReadiness()
        gate.resetInputSnapshot()
        pending?.continuation.resume(throwing: CancellationError())
    }
    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat, generation: UUID, tap: UUID) {
        let gate = self.gate
        let readyGeneration = self.readyGeneration
        let outputGeneration = self.outputGeneration
        let sampleRate = format.sampleRate
        let channels = format.channelCount
        let healthTickPending = OSAllocatedUnfairLock(initialState: false)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            gate.append(buffer, at: time)
            guard buffer.frameLength > 0, time.isHostTimeValid, time.hostTime > 0,
                  buffer.format.sampleRate == sampleRate, buffer.format.channelCount == channels,
                  readyGeneration.value != generation || outputGeneration.value == generation,
                  let self else { return }
            guard healthTickPending.withLock({ pending in
                guard !pending else { return false }
                pending = true
                return true
            }) else { return }
            let frames = buffer.frameLength
            self.queue.async { [weak self] in
                defer { healthTickPending.withLock { $0 = false } }
                self?.receivedInput(generation: generation, tap: tap, frames: frames)
            }
        }
    }

    private func outputFormatReady(_ node: AVAudioOutputNode) -> Bool {
        guard let unit = node.audioUnit else { return false }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &format, &size)
        return status == noErr && size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            && format.mSampleRate.isFinite && format.mSampleRate > 0 && format.mChannelsPerFrame > 0
    }

    private func duplexHealthy() -> Bool {
        guard voiceProcessing, let engine, engine.isRunning,
              engine.inputNode.isVoiceProcessingEnabled, engine.outputNode.isVoiceProcessingEnabled,
              let deviceID, currentDevice(engine.inputNode, input: true) == deviceID,
              let outputDeviceID, outputDeviceID != 0,
              currentDevice(engine.outputNode, input: false) == outputDeviceID,
              outputFormatReady(engine.outputNode),
              engine.outputConnectionPoints(for: engine.mainMixerNode, outputBus: 0)
                .contains(where: { $0.node === engine.outputNode }),
              playbackNodes.count == VoicePlaybackChannel.allCases.count else { return false }
        return playbackNodes.values.allSatisfy { player in
            engine.outputConnectionPoints(for: player, outputBus: 0)
                .contains(where: { $0.node === engine.mainMixerNode })
        }
    }

    private func withPlaybackNode(_ channel: VoicePlaybackChannel, generation: UUID,
                                  _ action: @escaping @Sendable (AVAudioPlayerNode) -> Void) {
        queue.async { [weak self] in
            guard let self, self.engineID == generation,
                  self.outputGeneration.value == generation,
                  let player = self.playbackNodes[channel] else { return }
            action(player)
        }
    }

    private func playbackRoute(_ channel: VoicePlaybackChannel, generation: UUID) -> VoicePlaybackRoute {
        let outputGeneration = self.outputGeneration
        let outputReceipt = self.outputReceipt
        let gate = self.gate
        return VoicePlaybackRoute(id: generation, isReady: {
            guard let receipt = outputReceipt.value, receipt.generation == generation else { return false }
            let renderAge = ProcessInfo.processInfo.systemUptime - receipt.advancedAt
            let latest = gate.snapshot().lastHostTime
            let now = mach_absolute_time()
            return outputGeneration.value == generation && renderAge >= 0 && renderAge < 0.5
                && latest > 0 && now >= latest
                && AVAudioTime.seconds(forHostTime: now - latest) < 0.5
        },
            schedule: { [weak self] data, completed in
                self?.withPlaybackNode(channel, generation: generation) { [weak self] player in
                    guard let format = self?.playbackFormat, !data.isEmpty, data.count.isMultiple(of: 2),
                          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                            frameCapacity: AVAudioFrameCount(data.count / 2)),
                          let target = buffer.int16ChannelData?[0] else { return }
                    buffer.frameLength = AVAudioFrameCount(data.count / 2)
                    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: target, count: data.count))
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completed() }
                }
            },
            play: { [weak self] in
                self?.withPlaybackNode(channel, generation: generation) { $0.play() }
            },
            stop: { [weak self] in
                self?.withPlaybackNode(channel, generation: generation) { $0.stop() }
            })
    }
}
