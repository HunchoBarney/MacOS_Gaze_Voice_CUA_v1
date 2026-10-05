import AVFoundation
import Foundation
import Darwin
import OSLog

/// The tap holds no idle audio. Closing admission waits for an accepted callback,
/// so the session can safely drain its converter without stopping the device.
final class MicrophoneAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var feed: ConvertedAudioFeed?
    private var openedAt: UInt64 = 0

    func open(_ feed: ConvertedAudioFeed, at hostTime: UInt64 = mach_absolute_time()) {
        lock.lock(); defer { lock.unlock() }
        self.feed = feed
        openedAt = hostTime
    }
    @discardableResult
    func close() -> ConvertedAudioFeed? {
        lock.lock(); defer { lock.unlock() }
        let previous = feed
        feed = nil
        return previous
    }
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard let feed, time.isHostTimeValid else { return }
        // A tap buffer can straddle Fn down. Exclude its pre-press prefix.
        let offset = time.hostTime < openedAt
            ? Int(ceil(AVAudioTime.seconds(forHostTime: openedAt - time.hostTime) * buffer.format.sampleRate)) : 0
        guard offset < Int(buffer.frameLength) else { return }
        if offset == 0 { feed.append(buffer); return }
        let count = buffer.frameLength - AVAudioFrameCount(offset)
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { return }
        trimmed.frameLength = count
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(trimmed.mutableAudioBufferList)
        for index in source.indices {
            guard let src = source[index].mData, let dst = target[index].mData else { return }
            memcpy(dst, src.advanced(by: offset * bytesPerFrame), Int(count) * bytesPerFrame)
        }
        feed.append(trimmed)
    }
}

/// Device setup and teardown share a serial owner away from the main actor.
/// Only the gate crosses into the real-time tap; it never creates a Task per buffer.
final class MicrophoneInput: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "microphone")
    enum ConfigurationResponse: Equatable { case restoreTap, interrupt }
    static func configurationResponse(engineRunning: Bool, sameDevice: Bool, sameFormat: Bool) -> ConfigurationResponse {
        guard engineRunning, sameDevice, sameFormat else { return .interrupt }
        return .restoreTap
    }
    struct Ready {
        let name: String
        let format: AVAudioFormat
    }
    let gate = MicrophoneAudioGate()
    private let queue = DispatchQueue(label: "voice.microphone", qos: .userInitiated)
    private enum Backend { case legacy, duplex(RealtimeDuplexAudioEngine) }
    private var activeBackend: Backend?
    private var engine: AVAudioEngine?
    private var duplex: RealtimeDuplexAudioEngine?
    /// A VPIO unit that refused to build won't succeed on the next hold
    /// either — stick to the tap for the process lifetime instead of paying
    /// failed-start latency on every Fn press.
    private var duplexUnavailable = false
    private var deviceID: AudioDeviceID?
    private var preparedFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?
    private var interrupted: (@Sendable () -> Void)?
    /// When the duplex engine is live its render callback is the AEC echo
    /// reference — the player routes decoded model audio through this.
    var renderSink: RealtimeRenderSink? { duplex }

    func prepare(device: MicrophoneDevice, interrupted: @escaping @Sendable () -> Void) async throws -> Ready {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.interrupted = interrupted
                    if self.deviceID == device.hardwareID {
                        if case .duplex(let duplex)? = self.activeBackend,
                           duplex.running, let format = duplex.captureFormat {
                            continuation.resume(returning: Ready(name: device.name, format: format))
                            return
                        }
                        if let engine = self.engine, engine.isRunning {
                            continuation.resume(returning: Ready(name: device.name, format: engine.inputNode.outputFormat(forBus: 0)))
                            return
                        }
                    }
                    self.stopOnQueue()
                    // The VoiceProcessingIO unit only forms a valid AEC pair
                    // on the system default input/output — anywhere else we
                    // stay on the tap path unchanged.
                    if !self.duplexUnavailable, RealtimeDuplexAudioEngine.isEligible(device: device) {
                        Self.log.notice("duplex mic pin: policy=systemDefaultOnly — following default input")
                        let duplex = RealtimeDuplexAudioEngine()
                        duplex.onDeath = { [weak self] in
                            self?.queue.async { self?.interrupted?() }
                        }
                        do {
                            let format = try duplex.start(device: device, gate: self.gate)
                            self.duplex = duplex
                            self.deviceID = device.hardwareID
                            self.activeBackend = .duplex(duplex)
                            continuation.resume(returning: Ready(name: device.name, format: format))
                            return
                        } catch {
                            Self.log.notice("duplex start failed — tap fallback: \(error.localizedDescription, privacy: .public)")
                            self.duplexUnavailable = true
                            duplex.stop()
                        }
                    }
                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    self.engine = engine; self.deviceID = device.hardwareID
                    self.activeBackend = .legacy
                    // Observe before selecting the device or starting the graph. Changing an
                    // AUAudioUnit device can leave CoreAudio's graph reconfiguring while the
                    // first tap is installed. The notification lets us attach it again once
                    // the route has settled instead of treating a running engine as proof that
                    // the tap exists.
                    self.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                        object: engine, queue: nil) { [weak self, weak engine] _ in
                            self?.queue.async { [weak self, weak engine] in
                                guard let self, let engine, self.engine === engine else { return }
                                let input = engine.inputNode
                                let sameDevice = input.auAudioUnit.deviceID == self.deviceID
                                let currentFormat = input.outputFormat(forBus: 0)
                                let sameFormat = currentFormat == self.preparedFormat
                                let running = engine.isRunning
                                Self.log.notice("configuration running=\(running) selected_device=\(sameDevice) same_format=\(sameFormat)")
                                switch Self.configurationResponse(engineRunning: running, sameDevice: sameDevice,
                                                                  sameFormat: sameFormat) {
                                case .restoreTap:
                                    Self.log.notice("configuration stable; restoring input tap")
                                    // Tap surgery on a running engine races the IO
                                    // thread — it can call through a render proc the
                                    // remove just nulled (SIGSEGV in IOWorkLoop).
                                    // Stop first so the swap happens on a dead AU.
                                    engine.stop()
                                    input.removeTap(onBus: 0)
                                    self.installTap(on: input, format: currentFormat)
                                    do { try engine.start() } catch { self.interrupted?() }
                                case .interrupt:
                                    self.interrupted?()
                                }
                            }
                        }
                    if input.auAudioUnit.deviceID != device.hardwareID { try input.auAudioUnit.setDeviceID(device.hardwareID) }
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("The microphone has no usable input.") }
                    self.preparedFormat = format
                    self.installTap(on: input, format: format)
                    engine.prepare()
                    try engine.start()
                    continuation.resume(returning: Ready(name: device.name, format: format))
                } catch {
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    func stop() async {
        gate.close()?.finish()
        await withCheckedContinuation { continuation in
            queue.async { self.stopOnQueue(); continuation.resume() }
        }
    }
    private func stopOnQueue() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil; deviceID = nil; preparedFormat = nil
        duplex?.stop()
        duplex = nil
        activeBackend = nil
    }
    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let gate = self.gate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            gate.append(buffer, at: time)
        }
    }
}
