import JevVoiceCore
@testable import JevVoice

// Capture fixtures can model session events without starting a physical device.
extension SpeechCapturing {
    var onReadiness: ((SpeechReadiness) -> Void)? { get { nil } set {} }
    func prepare(inputUID: String?) async throws -> String { "" }
    func suspend() async { cancel() }
}
