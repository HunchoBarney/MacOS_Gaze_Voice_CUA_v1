#if canImport(LiveKitWebRTC)
import AVFoundation
import LiveKitWebRTC
@testable import Jarvis

/// Takes over the WebRTC audio engine's input and watches its output, for
/// the paid Live tests. With \`.rendered\` the engine runs in manual rendering
/// mode: no audio device opens, nothing is heard, and \`play\` feeds speech in.
/// With \`.microphone\` the engine keeps the real mic, and every input buffer
/// also reaches \`onInput\`, as the wake word would share it.
final class LiveAudioRig: NSObject, LKRTCAudioDeviceModuleDelegate, LKRTCAudioRenderer, @unchecked Sendable {
    enum Input { case microphone, rendered }

    struct InputStats: Sendable {
        var frames = 0
        var buffers = 0
        var largestGap: Double = 0
        var configChanges = 0
        var engines = 0
        /// Whether every engine started was offline, with no audio device.
        var allManual = true
        var starts = 0
        var playoutBuffers = 0
        var remoteBuffers = 0
    }

    let input: Input
    var onInput: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private let player = AVAudioPlayerNode()
    private let feed = AVAudioMixerNode()
    private let lock = NSLock()
    private var loud: [ContinuousClock.Instant] = []
    private var stats = InputStats()
    private var lastInputAt: ContinuousClock.Instant?
    private var observers: [NSObjectProtocol] = []

    init(_ input: Input) throws {
        self.input = input
        super.init()
        let module = WebRTCLiveTransport.factory.audioDeviceModule
        if input == .rendered {
            let status = module.setManualRenderingMode(true)
            guard status == 0 else { throw VoiceError("Manual rendering failed: \(status)") }
        }
        module.observer = self
    }

    /// Output buffers louder than speech level since \`instant\`.
    func loudOutput(since instant: ContinuousClock.Instant) -> [ContinuousClock.Instant] {
        lock.withLock { loud.filter { $0 >= instant } }
    }

    func clearOutput() { lock.withLock { loud.removeAll() } }

    var inputStats: InputStats { lock.withLock { stats } }

    /// Schedules rendered speech and returns its duration.
    func play(_ buffer: AVAudioPCMBuffer) -> Duration {
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
        return .milliseconds(Int(Double(buffer.frameLength) / buffer.format.sampleRate * 1000))
    }

    // MARK: LKRTCAudioDeviceModuleDelegate

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent event: LKRTCSpeechActivityEvent) {}

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        lock.withLock { stats.engines += 1 }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.stats.configChanges += 1 }
        })
        return 0
    }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        lock.withLock {
            stats.starts += 1
            if !engine.isInManualRenderingMode { stats.allManual = false }
        }
        return 0
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        if player.engine === engine { engine.detach(player) }
        if feed.engine === engine { engine.detach(feed) }
        return 0
    }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        switch input {
        case .rendered:
            if player.engine == nil { engine.attach(player) }
            if feed.engine == nil { engine.attach(feed) }
            engine.connect(player, to: feed, format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
            engine.connect(feed, to: destination, format: format)
        case .microphone:
            guard let source else { return 0 }
            engine.connect(source, to: destination, format: format)
            source.removeTap(onBus: 0)
            source.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
                guard let self else { return }
                let now = ContinuousClock.now
                self.lock.withLock {
                    if let last = self.lastInputAt {
                        let gap = now - last
                        self.stats.largestGap = max(self.stats.largestGap,
                                                    Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18)
                    }
                    self.lastInputAt = now
                    self.stats.frames += Int(buffer.frameLength)
                    self.stats.buffers += 1
                }
                self.onInput?(buffer, time)
            }
        }
        return 0
    }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        if let destination { engine.connect(source, to: destination, format: format) }
        source.removeTap(onBus: 0)
        source.installTap(onBus: 0, bufferSize: 480, format: nil) { [weak self] buffer, _ in
            self?.lock.withLock { self?.stats.playoutBuffers += 1 }
        }
        return 0
    }

    /// Live's decoded voice, from `WebRTCLiveTransport.remoteAudio`.
    func render(pcmBuffer buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<count { sum += samples[index] * samples[index] }
        } else if let samples = buffer.int16ChannelData?[0] {
            for index in 0..<count { let value = Float(samples[index]) / 32768; sum += value * value }
        } else { return }
        let now = ContinuousClock.now
        lock.withLock {
            stats.remoteBuffers += 1
            if (sum / Float(count)).squareRoot() > 0.01 { loud.append(now) }
        }
    }

    func audioDeviceModuleDidUpdateDevices(_ module: LKRTCAudioDeviceModule) {}

    /// Renders text with the system voice at 48 kHz mono.
    static func speech(_ text: String, voice: String = "Samantha") throws -> AVAudioPCMBuffer {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("live-bench-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", file.path, "--data-format=LEI16@48000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw VoiceError("say failed for a bench line") }
        let audio = try AVAudioFile(forReading: file)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                            frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw VoiceError("No buffer for a bench line")
        }
        try audio.read(into: buffer)
        return buffer
    }
}
#endif
