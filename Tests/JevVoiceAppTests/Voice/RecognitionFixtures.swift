import JevVoiceCore
@testable import JevVoice

@MainActor
extension ContinuousIntentCoordinator {
    func record(_ revision: SpeechRevision) {
        var snapshot = audio
        try! snapshot.apply(revision)
        record(snapshot)
    }
}

// Capture fixtures can model session events without starting a physical device.
extension SpeechCapturing {
    var onReadiness: ((SpeechReadiness) -> Void)? { get { nil } set {} }
    func prepare(inputUID: String?) async throws -> String { "" }
    func suspend() async { cancel() }
}
