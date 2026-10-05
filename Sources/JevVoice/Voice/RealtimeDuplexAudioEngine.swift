import AudioToolbox
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import OSLog
import Synchronization

enum DuplexError: LocalizedError {
    case componentNotFound
    case enableIOFailed(status: OSStatus)
    case voiceProcessingFailed(status: OSStatus)
    case unsuitableDevice
    case initFailed(status: OSStatus)
    case startFailed(status: OSStatus)
    var errorDescription: String? {
        switch self {
        case .componentNotFound: return "The VoiceProcessingIO unit is unavailable."
        case .enableIOFailed(let s): return "Duplex IO could not be enabled (OSStatus \(s))."
        case .voiceProcessingFailed(let s): return "Voice processing could not be enabled (OSStatus \(s))."
        case .unsuitableDevice: return "The default input has no duplex-capable output."
        case .initFailed(let s): return "The duplex unit failed to initialize (OSStatus \(s))."
        case .startFailed(let s): return "The duplex unit failed to start (OSStatus \(s))."
        }
    }
}

/// Single-producer/single-consumer ring of interleaved Float32 frames.
/// One thread writes via `write`, one thread reads via `read` — each owns
/// its index, so no lock is needed: the payload memcpy is sequenced by
/// publishing the index with release ordering and observing it with
/// acquire ordering, which guarantees the consumer never sees the bumped
/// tail before the samples are visible (and symmetrically for head/space).
final class DuplexRingBuffer: @unchecked Sendable {
    let capacity: Int
    let channels: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<UInt64>(0)   // frames consumed (consumer-owned)
    private let tail = Atomic<UInt64>(0)   // frames written (producer-owned)
    private let emitted = Atomic<UInt64>(0)
    private let dropped = Atomic<UInt64>(0)

    init(capacity: Int, channels: Int) {
        self.capacity = capacity
        self.channels = channels
        storage = .allocate(capacity: capacity * channels)
        storage.initialize(repeating: 0, count: capacity * channels)
    }
    deinit { storage.deallocate() }

    var availableFrames: Int {
        // Signed math: a flush racing an in-flight read can briefly leave
        // head ahead of tail — the ring is then simply empty, not corrupt.
        max(0, Int(tail.load(ordering: .acquiring)) - Int(head.load(ordering: .acquiring)))
    }
    var freeFrames: Int { capacity - availableFrames }
    /// Real frames the consumer pulled — the played-position clock.
    var consumedFrames: UInt64 { emitted.load(ordering: .acquiring) }
    var droppedFrames: UInt64 { dropped.load(ordering: .acquiring) }

    /// Producer side. Returns frames accepted; the overflow tail of `source`
    /// is counted in `droppedFrames` rather than overwriting unread audio.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, frames: Int) -> Int {
        let w = tail.load(ordering: .relaxed)
        // Clamped to capacity: index skew after a flush race must never
        // let a wrap memcpy run past the allocation.
        let free = min(capacity, max(0, capacity - (Int(w) - Int(head.load(ordering: .acquiring)))))
        let n = min(frames, free)
        if n < frames { _ = dropped.wrappingAdd(UInt64(frames - n), ordering: .relaxed) }
        guard n > 0 else { return 0 }
        let start = Int(w % UInt64(capacity))
        let first = min(n, capacity - start)
        memcpy(storage + start * channels, source, first * channels * MemoryLayout<Float>.size)
        if first < n {
            memcpy(storage, source + first * channels,
                   (n - first) * channels * MemoryLayout<Float>.size)
        }
        tail.store(w + UInt64(n), ordering: .releasing)
        return n
    }

    /// Consumer side (the render proc). Returns real frames copied into
    /// `dst`; callers zero-fill the remainder so an empty ring emits
    /// silence instead of underflowing.
    @discardableResult
    func read(_ dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let r = head.load(ordering: .relaxed)
        let n = min(frames, max(0, Int(tail.load(ordering: .acquiring)) - Int(r)))
        guard n > 0 else { return 0 }
        let start = Int(r % UInt64(capacity))
        let first = min(n, capacity - start)
        memcpy(dst, storage + start * channels, first * channels * MemoryLayout<Float>.size)
        if first < n {
            memcpy(dst + first * channels, storage,
                   (n - first) * channels * MemoryLayout<Float>.size)
        }
        head.store(r + UInt64(n), ordering: .releasing)
        _ = emitted.wrappingAdd(UInt64(n), ordering: .relaxed)
        return n
    }

    /// Producer side. A consumer mid-read may observe part-zeroed frames —
    /// acceptable, since flush only ever runs on an interruption.
    func flush() {
        storage.initialize(repeating: 0, count: capacity * channels)
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// int16/24kHz/mono wire format → interleaved Float32 in the render unit's
/// rate and channel count. Conversion runs on the duplex write queue —
/// AVAudioConverter allocates, so it must stay off the render thread.
///
/// The converter emits output in ~2048-input-frame blocks and holds the
/// remainder internally (bounded < ~90ms); only fresh input or an
/// end-of-stream drains it. `drain()` exists so the last held frames of a
/// reply actually render when the delta stream goes quiet.
final class RenderConverter {
    let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(outputFormat: AVAudioFormat) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                                        channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: outputFormat) else { return nil }
        self.inputFormat = input
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let dst = input.int16ChannelData?[0] else { return nil }
        input.frameLength = frames
        dst.withMemoryRebound(to: UInt8.self, capacity: Int(frames) * 2) {
            pcm.copyBytes(to: $0, count: Int(frames) * 2)
        }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * outputFormat.sampleRate / 24000) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return input
        }
        return status == .error ? nil : output
    }

    /// endOfStream flushes the converter's held tail — and resets it, so
    /// this is only for a stream that has actually gone quiet.
    func drain() -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        return status == .error ? nil : output
    }
}

/// One VoiceProcessingIO unit owns both the echo-cancelled mic and the
/// speaker feed, so the render side doubles as the AEC reference — the
/// same architecture Clicky's RealtimeDuplexAudioEngine runs ("echo-
/// cancelled capture+playback active"). Raw AudioUnit APIs throughout:
/// AVAudioEngine exposes no input-callback/render-callback pair.
final class RealtimeDuplexAudioEngine: RealtimeRenderSink, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "duplex")
    private static let maxFrames = AVAudioFrameCount(4096)

    /// Serializes conversion + ring writes — and receives the drain/death
    /// signals the RT callbacks raise — so nothing in either IO proc allocs.
    private let writeQueue = DispatchQueue(label: "voice.duplex.render", qos: .userInitiated)
    private var unit: AudioUnit?
    private var gate: MicrophoneAudioGate?
    private var ring: DuplexRingBuffer?
    private var converter: RenderConverter?
    private var renderRate = 0.0
    private var renderChannels = 0
    private var scratch: UnsafeMutablePointer<Float>?
    /// Reusable capture buffers — the render-into ABL is each buffer's own
    /// audioBufferList, so frames land in AVAudioPCMBuffer storage with no
    /// per-callback allocation and nothing outlives the callback.
    private var captureBuffer: AVAudioPCMBuffer?
    private var captureInterleaved = false
    private var monoBuffer: AVAudioPCMBuffer?
    private var drainSignal: DispatchSourceUserDataAdd?
    private let signalLock = NSLock()
    private let dead = Atomic<Bool>(false)
    private var lastDropLog = 0.0
    /// Scheduled converter tail-flush — deltas stream continuously, so a
    /// quiet writeQueue is the only end-of-reply signal the sink can see.
    private var tailDrain: DispatchWorkItem?
    /// Jitter prebuffer (~120ms): the render proc emits silence until the
    /// ring holds primeFrames OR the deadline passes, whichever first —
    /// so delta-arrival jitter and CPU contention never reach the speaker
    /// as a dropout, while short replies still start. Re-arms whenever the
    /// ring runs dry so an underrun doesn't restart as stutter.
    private let primed = Atomic<Bool>(false)
    private let primeDeadline = Atomic<UInt64>(0)   // mach_absolute_time
    private var primeFrames = 0
    private var primeTicks: UInt64 = 0
    private(set) var running = false
    /// The format handed to the gate (mono-extracted when the unit insists
    /// on multi-channel) — MicrophoneInput's Ready contract.
    private(set) var captureFormat: AVAudioFormat?
    /// The duplex unit died mid-session (device pulled, IO proc erroring)
    /// — MicrophoneInput forwards this to its `interrupted` handler.
    var onDeath: (@Sendable () -> Void)?
    private var _onDrained: (@Sendable () -> Void)?
    /// Assigned mid-flight from the player's queue while the signal
    /// handler reads it on writeQueue — lock-backed for that crossing.
    var onDrained: (@Sendable () -> Void)? {
        get { signalLock.lock(); defer { signalLock.unlock() }; return _onDrained }
        set { signalLock.lock(); _onDrained = newValue; signalLock.unlock() }
    }
    /// writeQueue-only — the death signal must reach onDeath exactly once.
    private var deathFired = false

    var consumedMs: Double {
        guard let ring, renderRate > 0 else { return 0 }
        return Double(ring.consumedFrames) / renderRate * 1000
    }

    /// Overflow the render ring dropped — it resolves the player's drain
    /// wait but was never heard, so it stays out of playedMs.
    var droppedMs: Double {
        guard let ring, renderRate > 0 else { return 0 }
        return Double(ring.droppedFrames) / renderRate * 1000
    }

    /// Duplex pin policy: only the system default input is a valid AEC
    /// pairing (its output must be the same device), matching Clicky's
    /// "systemDefaultOnly → following default input".
    static func isEligible(device: MicrophoneDevice) -> Bool {
        guard device.hardwareID == defaultInputDevice() else { return false }
        return channelCount(of: device.hardwareID, scope: kAudioObjectPropertyScopeOutput) > 0
    }

    func start(device: MicrophoneDevice, gate: MicrophoneAudioGate) throws -> AVAudioFormat {
        let began = ProcessInfo.processInfo.systemUptime
        guard Self.isEligible(device: device) else { throw DuplexError.unsuitableDevice }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw DuplexError.componentNotFound }
        var created: AudioUnit?
        guard AudioComponentInstanceNew(component, &created) == noErr, let unit = created else {
            throw DuplexError.componentNotFound
        }
        do { try configure(unit, device: device) }
        catch { AudioComponentInstanceDispose(unit); throw error }
        var status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw DuplexError.initFailed(status: status)
        }
        // Publish before Start — the IO procs can fire immediately.
        self.unit = unit
        self.gate = gate
        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            self.unit = nil
            self.gate = nil
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw DuplexError.startFailed(status: status)
        }
        running = true
        Self.log.notice("duplex AEC engine started in \(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms inputFormat=\(self.captureFormat?.description ?? "?", privacy: .public)")
        return captureFormat!
    }

    deinit { stop() }

    private func configure(_ unit: AudioUnit, device: MicrophoneDevice) throws {
        dead.store(false, ordering: .relaxed)
        deathFired = false
        var status: OSStatus
        var enable: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw DuplexError.enableIOFailed(status: status) }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw DuplexError.enableIOFailed(status: status) }
        // On macOS the AEC+AGC+noise-suppression chain is the Bypass
        // switch — 0 means voice processing active (the iOS-only
        // VoiceProcessingEnableIO property doesn't exist here).
        var bypass: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing,
                                      kAudioUnitScope_Global, 0, &bypass, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw DuplexError.voiceProcessingFailed(status: status) }
        status = AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                      kAudioUnitScope_Global, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw DuplexError.voiceProcessingFailed(status: status) }
        var mute: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAUVoiceIOProperty_MuteOutput,
                                      kAudioUnitScope_Global, 0, &mute, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw DuplexError.voiceProcessingFailed(status: status) }
        var maxFrames = Self.maxFrames
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        var deviceID = device.hardwareID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw DuplexError.unsuitableDevice }
        try configureCapture(unit, device: device)
        try configureRender(unit)
        var inputCallback = AURenderCallbackStruct(inputProc: { refCon, flags, timestamp, _, frames, _ in
            Unmanaged<RealtimeDuplexAudioEngine>.fromOpaque(refCon).takeUnretainedValue()
                .pullInput(flags: flags, timestamp: timestamp, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 0, &inputCallback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw DuplexError.enableIOFailed(status: status) }
        var renderCallback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, ioData in
            Unmanaged<RealtimeDuplexAudioEngine>.fromOpaque(refCon).takeUnretainedValue()
                .renderOutput(frames: frames, ioData: ioData)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &renderCallback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw DuplexError.enableIOFailed(status: status) }
        let signal = DispatchSource.makeUserDataAddSource(queue: writeQueue)
        signal.setEventHandler { [weak self] in
            guard let self else { return }
            if self.dead.load(ordering: .relaxed), !self.deathFired {
                self.deathFired = true
                self.onDeath?()
            }
            self.onDrained?()
        }
        signal.resume()
        drainSignal = signal
    }

    /// Capture format negotiation: ask for mono Float32 non-interleaved at
    /// the device's rate; if the unit refuses, keep whatever it reports
    /// and extract channel 0 in the callback wrapper instead.
    private func configureCapture(_ unit: AudioUnit, device: MicrophoneDevice) throws {
        let rate = Self.nominalRate(of: device.hardwareID)
        var wanted = Self.floatASBD(rate: rate, channels: 1, interleaved: false)
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1, &wanted,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var actual = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Output, 1, &actual, &size)
        if status != noErr || actual.mFormatID != kAudioFormatLinearPCM
            || actual.mFormatFlags & kAudioFormatFlagIsFloat == 0 || actual.mChannelsPerFrame == 0 {
            // The unit ignored our preference — adopt the device layout.
            let deviceChannels = Self.channelCount(of: device.hardwareID,
                                                   scope: kAudioObjectPropertyScopeInput)
            guard deviceChannels > 0 else { throw DuplexError.unsuitableDevice }
            actual = Self.floatASBD(rate: rate, channels: UInt32(deviceChannels), interleaved: false)
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Output, 1, &actual,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            guard status == noErr else { throw DuplexError.unsuitableDevice }
        }
        guard let format = AVAudioFormat(streamDescription: &actual) else {
            throw DuplexError.unsuitableDevice
        }
        captureInterleaved = actual.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard let capture = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maxFrames) else {
            throw DuplexError.unsuitableDevice
        }
        captureBuffer = capture
        if format.channelCount > 1 {
            guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: format.sampleRate,
                                                 channels: 1, interleaved: false),
                  let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: Self.maxFrames)
            else { throw DuplexError.unsuitableDevice }
            monoBuffer = mono
            captureFormat = monoFormat
        } else {
            captureFormat = format
        }
    }

    /// The render side — what makes this duplex. The unit pulls Float32
    /// frames from the ring; the format is whatever it reports (typically
    /// interleaved stereo at the device rate).
    private func configureRender(_ unit: AudioUnit) throws {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 0, &asbd, &size) == noErr,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0 else {
            throw DuplexError.unsuitableDevice
        }
        renderRate = asbd.mSampleRate
        renderChannels = Int(asbd.mChannelsPerFrame)
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: renderRate,
                                         channels: AVAudioChannelCount(renderChannels), interleaved: true),
              let converter = RenderConverter(outputFormat: output) else {
            throw DuplexError.unsuitableDevice
        }
        self.converter = converter
        ring = DuplexRingBuffer(capacity: Int(renderRate * 2), channels: renderChannels)
        primeFrames = Int(renderRate * 0.12)
        primeTicks = UInt64(0.12 / AVAudioTime.seconds(forHostTime: 1))
        primed.store(false, ordering: .releasing)
        primeDeadline.store(0, ordering: .releasing)
        scratch = .allocate(capacity: Int(Self.maxFrames) * renderChannels)
        scratch?.initialize(repeating: 0, count: Int(Self.maxFrames) * renderChannels)
    }

    // MARK: - RealtimeRenderSink (producer side — writeQueue, never RT)

    func enqueue(_ pcm: Data) {
        writeQueue.async { [weak self] in
            guard let self, let converter = self.converter, let ring = self.ring,
                  let output = converter.convert(pcm), let src = output.floatChannelData?[0]
            else { return }
            ring.write(src, frames: Int(output.frameLength))
            self.armPrimeDeadline()
            let dropped = ring.droppedFrames
            // Overflow means the producer outran 2s of playback — loud in
            // logs, silent in audio (the unread tail survives).
            let now = ProcessInfo.processInfo.systemUptime
            if dropped > 0, now - self.lastDropLog > 1 {
                self.lastDropLog = now
                Self.log.notice("duplex render ring overflow dropped=\(dropped)")
            }
            // Without this the converter's held tail keeps consumedMs
            // permanently short of scheduledMs and playback never idles.
            self.tailDrain?.cancel()
            let drain = DispatchWorkItem { [weak self] in
                guard let self, let flushed = self.converter?.drain(),
                      flushed.frameLength > 0, let tail = flushed.floatChannelData?[0]
                else { return }
                self.ring?.write(tail, frames: Int(flushed.frameLength))
                self.armPrimeDeadline()
            }
            self.tailDrain = drain
            self.writeQueue.asyncAfter(deadline: .now() + .milliseconds(150), execute: drain)
        }
    }

    /// writeQueue-only. The first write after an underrun or flush starts
    /// the prime deadline — a reply shorter than primeFrames still plays.
    private func armPrimeDeadline() {
        if !primed.load(ordering: .acquiring), primeDeadline.load(ordering: .acquiring) == 0 {
            primeDeadline.store(mach_absolute_time() + primeTicks, ordering: .releasing)
        }
    }

    func flush() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.tailDrain?.cancel()
            self.primed.store(false, ordering: .releasing)
            self.primeDeadline.store(0, ordering: .releasing)
            self.ring?.flush()
        }
    }

    // MARK: - RT callbacks — no locks, no allocation, no ARC traffic that
    // can block: the ring is preallocated, the scratch buffer is
    // preallocated, gate is the deliberate seam (its lock guards a pointer
    // swap — the same trade-off the legacy tap makes on its IO thread).

    /// Input callback: pull echo-cancelled mic frames via AudioUnitRender
    /// into the reusable capture buffer, wrap, hand to the gate.
    private func pullInput(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                           timestamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, let captureBuffer else { return noErr }
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames,
                                     captureBuffer.mutableAudioBufferList)
        guard status == noErr else {
            if dead.compareExchange(expected: false, desired: true,
                                    ordering: .releasing).exchanged { signal() }
            return noErr
        }
        let count = min(frames, Self.maxFrames)
        captureBuffer.frameLength = count
        let buffer: AVAudioPCMBuffer
        if let mono = monoBuffer, let dst = mono.floatChannelData?[0],
           let src = captureBuffer.floatChannelData?[0] {
            if captureInterleaved {
                let stride = Int(captureBuffer.format.channelCount)
                for f in 0..<Int(count) { dst[f] = src[f * stride] }
            } else {
                memcpy(dst, src, Int(count) * MemoryLayout<Float>.size)
            }
            mono.frameLength = count
            buffer = mono
        } else {
            buffer = captureBuffer
        }
        gate?.append(buffer, at: AVAudioTime(hostTime: timestamp.pointee.mHostTime))
        return noErr
    }

    /// Render callback: the unit pulls speaker frames each cycle — this
    /// feed is the AEC echo reference. Atomic index reads + memcpy only;
    /// an empty (or still-priming) ring emits zeros rather than stalling
    /// the IO proc.
    private func renderOutput(frames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData, let ring, let scratch else { return noErr }
        let n = Int(frames)
        let wasNonEmpty = ring.availableFrames > 0
        var got = 0
        if wasNonEmpty {
            if primed.load(ordering: .acquiring) {
                got = ring.read(scratch, frames: n)
            } else {
                let deadline = primeDeadline.load(ordering: .acquiring)
                if ring.availableFrames >= primeFrames
                    || (deadline != 0 && mach_absolute_time() >= deadline) {
                    primed.store(true, ordering: .releasing)
                    got = ring.read(scratch, frames: n)
                }
            }
        }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        if buffers.count == 1, let mData = buffers[0].mData,
           buffers[0].mNumberChannels == UInt32(renderChannels) {
            let dst = mData.assumingMemoryBound(to: Float.self)
            memcpy(dst, scratch, got * renderChannels * MemoryLayout<Float>.size)
            if got < n {
                memset(dst + got * renderChannels, 0,
                       (n - got) * renderChannels * MemoryLayout<Float>.size)
            }
        } else {
            // De-interleaved or otherwise split ioData — per-sample copy,
            // still allocation-free.
            var channel = 0
            for buffer in buffers {
                guard let mData = buffer.mData else { continue }
                let dst = mData.assumingMemoryBound(to: Float.self)
                let width = Int(buffer.mNumberChannels)
                for f in 0..<n {
                    for c in 0..<width {
                        dst[f * width + c] = f < got ? scratch[f * renderChannels + channel + c] : 0
                    }
                }
                channel += width
            }
        }
        if wasNonEmpty, ring.availableFrames == 0 {
            // Ran dry — re-arm the prebuffer so a late next delta buffers
            // again instead of trickling straight out as stutter.
            primed.store(false, ordering: .releasing)
            primeDeadline.store(0, ordering: .releasing)
            signal()
        }
        return noErr
    }

    /// RT→writeQueue handoff. dispatch_source_merge_data is the sanctioned
    /// realtime-safe signal — it never locks or allocates on the caller.
    private func signal() { drainSignal?.add(data: 1) }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        running = false
        drainSignal?.cancel()
        drainSignal = nil
        primed.store(false, ordering: .releasing)
        primeDeadline.store(0, ordering: .releasing)
        gate = nil
        ring = nil
        converter = nil
        captureBuffer = nil
        monoBuffer = nil
        scratch?.deallocate()
        scratch = nil
        captureFormat = nil
    }

    // MARK: - CoreAudio helpers

    private static func floatASBD(rate: Double, channels: UInt32, interleaved: Bool) -> AudioStreamBasicDescription {
        let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved)
        return AudioStreamBasicDescription(mSampleRate: rate,
                                           mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                           mBytesPerPacket: 4, mFramesPerPacket: 1,
                                           mBytesPerFrame: interleaved ? 4 * channels : 4,
                                           mChannelsPerFrame: channels, mBitsPerChannel: 32,
                                           mReserved: 0)
    }

    private static func defaultInputDevice() -> AudioDeviceID {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func nominalRate(of id: AudioDeviceID) -> Double {
        var rate = 0.0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }

    private static func channelCount(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
