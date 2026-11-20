import Foundation

/// The cheap one-way voice for spoken alerts (D5). It only speaks; it
/// never listens and never opens a Live session. Apple's on-device voice
/// is the only implementation for now, so alerts cost nothing; an OpenAI
/// TTS voice can conform later.
@MainActor
protocol OneWayVoice: AnyObject {
    func speak(_ text: String)
    func stop()
}

/// Apple's on-device voice through the app's existing speech output.
@MainActor
final class OnDeviceAlertVoice: OneWayVoice {
    private let output: any SpeechSynthesizing

    init(output: any SpeechSynthesizing) {
        self.output = output
    }

    func speak(_ text: String) { output.speak(text) }
    func stop() { output.stop() }
}
