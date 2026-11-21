import AVFoundation
import Foundation

/// One request in basic voice, after this month's Live voice is used up
/// (KAR-75 L10, plan §10). The words come from on-device transcription and
/// go through the same spine as always (`run`, `VoiceTaskCoordinator
/// .beginVoiceTask` in the app) while hosted Jev and Responses calls are held,
/// so nothing paid runs. Questions, look-ups and multi-step work wait for
/// Live voice. The reply is spoken only when "Say replies out loud" is on;
/// otherwise it's shown.
@MainActor
struct BasicVoiceTurn {
    let run: (String) async -> String
    let speak: (String) -> Void
    let show: ([String]) -> Void
    let speaksReplies: () -> Bool

    @discardableResult
    func handle(_ text: String, until: Date) async -> String {
        let reply = Self.needsLive(text)
            ? LiveAllowance.needsLiveLine(until: until)
            : VoiceToolResult(jsonString: await run(text))?.say ?? ""
        guard !reply.isEmpty else { return reply }
        if speaksReplies() { speak(reply) } else { show([reply]) }
        return reply
    }

    /// The relay's recording as `LocalSpanTranscriber` takes it: mono
    /// float samples at `sampleRate` to 24 kHz PCM16.
    static func speech(_ samples: [Float], sampleRate: Double) -> Data {
        guard !samples.isEmpty,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: RecentSpeechAudio.sampleRate,
                                         channels: 1, interleaved: true),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: source, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(
                  (Double(samples.count) * target.sampleRate / sampleRate).rounded(.up)) + 1024) else { return Data() }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let pcm = output.int16ChannelData?[0] else { return Data() }
        return Data(bytes: pcm, count: Int(output.frameLength) * 2)
    }

    /// Requests only a conversation or a model can answer: questions,
    /// look-ups, multi-step work and talk aimed at Jarvis. A command the
    /// fast lane parses never needs Live.
    static func needsLive(_ text: String) -> Bool {
        guard FastAction.parse(text) == nil else { return false }
        switch IntentRouter.classify(text).verb {
        case .query, .lookup, .work, .address: return true
        default: return false
        }
    }
}
