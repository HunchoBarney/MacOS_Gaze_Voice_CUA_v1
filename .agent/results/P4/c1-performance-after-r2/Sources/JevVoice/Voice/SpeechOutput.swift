import AVFoundation
import Foundation

/// Spoken replies over AVSpeechSynthesizer behind the `SpeechSynthesizing`
/// seam. `speak` and `stop` never block: every call hops to the main queue,
/// where the synthesizer is created and driven. A new `speak` barges in on
/// the current utterance.
final class SpeechOutput: SpeechSynthesizing, @unchecked Sendable {
    /// Mirrors Config.ttsEnabled; disabled output drops calls silently.
    var enabled: Bool
    /// AVSpeechUtterance rate (0…1); AVSpeechUtteranceDefaultSpeechRate ≈ 0.5.
    var rate: Float
    private var synthesizer: AVSpeechSynthesizer?

    init(rate: Float = AVSpeechUtteranceDefaultSpeechRate, enabled: Bool = true) {
        self.rate = rate
        self.enabled = enabled
    }

    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async {
            guard self.enabled else { return }
            let synthesizer = self.synthesizerOnMain()
            if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = self.rate
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.synthesizer?.stopSpeaking(at: .immediate)
        }
    }

    private func synthesizerOnMain() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        return synthesizer
    }
}
