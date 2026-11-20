import AVFoundation
import Foundation
import Speech

/// The person's recent hands-free speech exactly as the lane sent it to
/// Realtime: 24 kHz mono PCM16, the last 20 seconds. L7 transcribes it a
/// second time on device to check a "type this" span. Memory only, and
/// nothing is kept until `isRecording` is set, which only `voice.live` does.
final class RecentSpeechAudio: @unchecked Sendable {
    static let sampleRate = 24_000.0
    static let limit = 20.0
    private let lock = NSLock()
    private var pcm = Data()
    private var recording = false

    init(isRecording: Bool = false) {
        recording = isRecording
    }

    var isRecording: Bool {
        get { lock.lock(); defer { lock.unlock() }; return recording }
        set {
            lock.lock(); defer { lock.unlock() }
            recording = newValue
            if !newValue { pcm = Data() }
        }
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
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
    var analyze: @Sendable (Data) async -> String? = { await LocalSpanTranscriber.analyze($0) }

    func transcribe(_ pcm: Data) async -> String? {
        guard pcm.count >= 2 else { return nil }
        switch authorization() {
        case .authorized: break
        case .notDetermined: requestAuthorization(); return nil
        default: return nil
        }
        let race = Race()
        let analyze = analyze
        let work = Task { race.finish(await analyze(pcm)) }
        let timeout = timeout
        let timer = Task { try? await Task.sleep(for: timeout); race.finish(nil) }
        let text = await race.value()
        work.cancel()
        timer.cancel()
        return text
    }

    /// First answer wins and nothing waits on the loser, so a wedged speech
    /// service can't hold "type this" past the timeout.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        private var settled = false
        private var outcome: String?

        func finish(_ text: String?) {
            lock.lock()
            guard !settled else { lock.unlock(); return }
            settled = true
            outcome = text
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: text)
        }

        func value() async -> String? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if settled { lock.unlock(); continuation.resume(returning: outcome) }
                else { self.continuation = continuation; lock.unlock() }
            }
        }
    }

    static func analyze(_ pcm: Data) async -> String? {
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
            for try await result in transcriber.results {
                let segment = String(result.text.characters)
                let joins = text.isEmpty || text.last?.isWhitespace == true || segment.first?.isWhitespace == true
                text += (joins ? "" : " ") + segment
            }
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
