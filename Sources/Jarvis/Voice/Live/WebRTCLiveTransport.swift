#if canImport(LiveKitWebRTC)
import AVFoundation
import Foundation
import LiveKitWebRTC
import os

/// GPT-Live over WebRTC with LiveKit's build of libwebrtc. Its audio device
/// module runs on one AVAudioEngine that owns the microphone and plays Live's
/// voice with Apple's voice processing (echo cancellation), and the JSON
/// events ride the "oai-events" data channel.
final class WebRTCLiveTransport: NSObject, LiveTransport, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis", category: "live")
    /// One per process. The paid tests reach its audio device module to
    /// feed rendered speech or watch the shared engine.
    static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine, bypassVoiceProcessing: false,
                                          encoderFactory: nil, decoderFactory: nil, audioProcessingModule: nil)
    }()

    let incoming: AsyncStream<LiveTransportEvent>
    private let continuation: AsyncStream<LiveTransportEvent>.Continuation
    private let lock = NSLock()
    private var peer: LKRTCPeerConnection?
    private var channel: LKRTCDataChannel?
    private var gathered: CheckedContinuation<Void, Never>?
    private var gatheringComplete = false
    private var finished = false

    override init() {
        (incoming, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        super.init()
    }

    func offer() async throws -> String {
        guard !MicrophoneTestGuard.blocksRealMicrophone else {
            throw VoiceError("Unit tests don't open the microphone. Set JARVIS_LIVE_MIC=1 for a live test.")
        }
        let factory = Self.factory
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let none = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: none, delegate: self) else {
            throw VoiceError("Couldn't open a voice connection.")
        }
        let microphone = factory.audioTrack(with: factory.audioSource(with: none), trackId: "microphone")
        peer.add(microphone, streamIds: ["jarvis"])
        let channelConfig = LKRTCDataChannelConfiguration()
        channelConfig.isOrdered = true
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: channelConfig) else {
            throw VoiceError("Couldn't open the voice event channel.")
        }
        channel.delegate = self
        lock.withLock { self.peer = peer; self.channel = channel }
        let offer = try await peer.offer(for: none)
        try await peer.setLocalDescription(offer)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForGathering() }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
            self.lock.withLock {
                self.gatheringComplete = true
                self.gathered?.resume(); self.gathered = nil
            }
        }
        guard let sdp = peer.localDescription?.sdp else { throw VoiceError("The voice connection has no offer.") }
        return sdp
    }

    func accept(answer: String) async throws {
        guard let peer = lock.withLock({ self.peer }) else { throw VoiceError("The voice connection closed.") }
        try await peer.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer))
    }

    func send(_ message: Data) throws {
        guard let channel = lock.withLock({ self.channel }), channel.readyState == .open,
              channel.sendData(LKRTCDataBuffer(data: message, isBinary: false)) else {
            throw VoiceError("The voice event channel isn't open.")
        }
    }

    func close() {
        let (peer, channel) = lock.withLock { () -> (LKRTCPeerConnection?, LKRTCDataChannel?) in
            defer { self.peer = nil; self.channel = nil }
            return (self.peer, self.channel)
        }
        channel?.close()
        peer?.close()
        finish(nil)
    }

    private func waitForGathering() async {
        await withCheckedContinuation { waiter in
            let done = lock.withLock { () -> Bool in
                if gatheringComplete { return true }
                gathered = waiter
                return false
            }
            if done { waiter.resume() }
        }
    }

    private func finish(_ why: String?) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        continuation.yield(.closed(why))
        continuation.finish()
    }
}

extension WebRTCLiveTransport: LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    func peerConnection(_ peer: LKRTCPeerConnection, didChange state: LKRTCIceGatheringState) {
        guard state == .complete else { return }
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            gatheringComplete = true
            defer { gathered = nil }
            return gathered
        }
        waiter?.resume()
    }

    func peerConnection(_ peer: LKRTCPeerConnection, didChange state: LKRTCPeerConnectionState) {
        if state == .failed || state == .closed { finish("connection \(state.rawValue)") }
    }

    func dataChannel(_ channel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        continuation.yield(.message(buffer.data))
    }

    func dataChannelDidChangeState(_ channel: LKRTCDataChannel) {
        if channel.readyState == .closed { finish("event channel closed") }
    }

    func peerConnection(_ peer: LKRTCPeerConnection, didChange state: LKRTCSignalingState) {}
    func peerConnection(_ peer: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peer: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peer: LKRTCPeerConnection) {}
    func peerConnection(_ peer: LKRTCPeerConnection, didChange state: LKRTCIceConnectionState) {}
    func peerConnection(_ peer: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peer: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peer: LKRTCPeerConnection, didOpen channel: LKRTCDataChannel) {}
}
#endif
