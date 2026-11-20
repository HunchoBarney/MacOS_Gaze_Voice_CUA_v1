import AVFoundation
import Foundation
import Speech

/// The person's recent hands-free speech exactly as the lane sent it to
/// Realtime: 24 kHz mono PCM16, the last 20 seconds. L7 transcribes it a
/// second time on device to check a "type this" span. Memory only.
final class RecentSpeechAudio: @unchecked Sendable {
    static let sampleRate = 24_000.0
    static let limit = 20.0
    private let lock = NSLock()
    private var pcm = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        pcm.append(chunk)
        let cap = Int(Self.sampleRate * Self.limit) * 2
        if pcm.count > cap { pcm.removeFirst(pcm.count - cap) }
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return pcm
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        pcm = Data()
    }
}

/// On-device transcription of recent speech with Apple's SpeechAnalyzer
/// (macOS 26), the second opinion plan §8 asks for. It never downloads a
/// model and never waits on the permission prompt: when it can't answer in
/// time, the caller shows the text before typing it.
struct LocalSpanTranscriber: Sendable {
    var authorization: @Sendable () -> SFSpeechRecognizerAuthorizationStatus = {
        SFSpeechRecognizer.authorizationStatus()
    }
    /// Asked once, at the first "type this"; Info.plist carries the reason.
    var requestAuthorization: @Sendable () -> Void = {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }
    var timeout: Duration = .seconds(4)

    func transcribe(_ pcm: Data) async -> String? {
        guard pcm.count >= 2 else { return nil }
        switch authorization() {
        case .authorized: break
        case .notDetermined: requestAuthorization(); return nil
        default: return nil
        }
        let timeout = timeout
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await Self.analyze(pcm) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func analyze(_ pcm: Data) async -> String? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return nil }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let buffer = convert(pcm, to: format) else { return nil }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        let input = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
        }
        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(input) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            return nil
        }
        guard let text = try? await collector.value.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    static func convert(_ pcm: Data, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: RecentSpeechAudio.sampleRate,
                                         channels: 1, interleaved: true),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let samples = input.int16ChannelData?[0] else { return nil }
        input.frameLength = input.frameCapacity
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(samples, base, Int(input.frameLength) * 2)
        }
        if source == format { return input }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / source.sampleRate) + 1024
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
