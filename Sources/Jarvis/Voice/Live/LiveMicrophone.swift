#if canImport(LiveKitWebRTC)
import AVFoundation
import Foundation
import LiveKitWebRTC
import os

/// KAR-75 L3: the one microphone owner while `voice.live` is on. LiveKit's
/// audio engine (the one WebRTC sends from) records from Asleep onward. Its
/// input runs through Jarvis rather than straight into WebRTC: the wake word
/// hears every buffer on the Mac, and the session's input track plays from
/// `relay`, which holds the request said in the same breath as the wake word.
final class LiveMicrophone: NSObject, LKRTCAudioDeviceModuleDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis", category: "live")
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    let relay = LiveInputRelay(sampleRate: LiveMicrophone.format.sampleRate)
    /// Every input buffer, on the audio thread, for the wake word.
    var onInput: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private let downmix = AVAudioMixerNode()
    private lazy var tap = AVAudioSinkNode { [weak self] timestamp, frames, list in
        guard let self, frames > 0 else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let data = buffers.first?.mData else { return noErr }
        let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frames))
        let host = timestamp.pointee.mHostTime
        let end = AVAudioTime.seconds(forHostTime: host) + Double(frames) / Self.format.sampleRate
        self.relay.write(samples, endingAt: end)
        if let onInput = self.onInput,
           let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, bufferListNoCopy: list, deallocator: nil) {
            onInput(buffer, AVAudioTime(hostTime: host))
        }
        return noErr
    }
    private lazy var feed = AVAudioSourceNode(format: Self.format) { [weak self] _, _, frames, list in
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let out = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frames))
            if let self { self.relay.read(into: out) } else { out.update(repeating: 0) }
        }
        return noErr
    }

    private var module: LKRTCAudioDeviceModule { WebRTCLiveTransport.factory.audioDeviceModule }

    /// Starts recording on LiveKit's engine, with no session open.
    func start() throws {
        guard !MicrophoneTestGuard.blocksRealMicrophone else {
            throw VoiceError("Unit tests don't open the microphone. Set JARVIS_LIVE_MIC=1 for a live test.")
        }
        module.observer = self
        let status = module.initAndStartRecording()
        guard status == 0 else { throw VoiceError("Couldn't start the microphone (\(status)).") }
    }

    func stop() {
        relay.stop()
        _ = module.stopRecording()
    }

    // MARK: LKRTCAudioDeviceModuleDelegate

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule,
                           didReceiveSpeechActivityEvent event: LKRTCSpeechActivityEvent) {}
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        for node in [downmix, tap, feed] as [AVAudioNode] where node.engine === engine { engine.detach(node) }
        return 0
    }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        for node in [downmix, tap, feed] as [AVAudioNode] where node.engine == nil { engine.attach(node) }
        if let source {
            engine.connect(source, to: downmix, format: nil)
            engine.connect(downmix, to: tap, format: Self.format)
        }
        engine.connect(feed, to: destination, format: format)
        Self.log.notice("live_microphone_configured input=\(source != nil, privacy: .public) rate=\(format.sampleRate, privacy: .public)")
        return 0
    }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        if let destination { engine.connect(source, to: destination, format: format) }
        return 0
    }

    func audioDeviceModuleDidUpdateDevices(_ module: LKRTCAudioDeviceModule) {}
}
#endif
