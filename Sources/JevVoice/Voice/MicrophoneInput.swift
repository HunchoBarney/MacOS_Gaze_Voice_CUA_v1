import AVFoundation
import Foundation
import Darwin
import OSLog

/// The tap holds no idle audio. Closing admission waits for an accepted callback,
/// so the session can safely drain its converter without stopping the device.
final class MicrophoneAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var feed: AnalyzerAudioFeed?
    private var openedAt: UInt64 = 0

    func open(_ feed: AnalyzerAudioFeed, at hostTime: UInt64 = mach_absolute_time()) {
        lock.lock(); defer { lock.unlock() }
        self.feed = feed
        openedAt = hostTime
    }
    @discardableResult
    func close() -> AnalyzerAudioFeed? {
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
    struct Ready {
        let name: String
        let format: AVAudioFormat
    }
    let gate = MicrophoneAudioGate()
    private let queue = DispatchQueue(label: "voice.microphone", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var deviceID: AudioDeviceID?
    private var observer: NSObjectProtocol?
    private var interrupted: (@Sendable () -> Void)?

    func prepare(device: MicrophoneDevice, interrupted: @escaping @Sendable () -> Void) async throws -> Ready {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.interrupted = interrupted
                    if let engine = self.engine, self.deviceID == device.hardwareID, engine.isRunning {
                        continuation.resume(returning: Ready(name: device.name, format: engine.inputNode.outputFormat(forBus: 0)))
                        return
                    }
                    self.stopOnQueue()
                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    if input.auAudioUnit.deviceID != device.hardwareID { try input.auAudioUnit.setDeviceID(device.hardwareID) }
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("The microphone has no usable input.") }
                    let gate = self.gate
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in gate.append(buffer, at: time) }
                    self.engine = engine; self.deviceID = device.hardwareID
                    engine.prepare()
                    try engine.start()
                    self.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                        object: engine, queue: nil) { [weak self, weak engine] _ in
                            self?.queue.async { [weak self, weak engine] in
                                guard let self, let engine, self.engine === engine else { return }
                                let sameDevice = engine.inputNode.auAudioUnit.deviceID == device.hardwareID
                                let sameFormat = engine.inputNode.outputFormat(forBus: 0) == format
                                let running = engine.isRunning
                                Self.log.notice("configuration running=\(running) selected_device=\(sameDevice) same_format=\(sameFormat)")
                                // Device setup can deliver a delayed notification after
                                // startup. Preserve a healthy engine; only actual loss
                                // or a changed route/format interrupts the hold.
                                if !running || !sameDevice || !sameFormat { self.interrupted?() }
                            }
                        }
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
        engine = nil; deviceID = nil
    }
}
