import Foundation
import JevVoiceCore

enum SpeechEvent {
    case partial(String), final(String), failure(String), level(Float)
    case transcript(RangedTranscript)
    case timing(String, milliseconds: Double)
}

enum SpeechReadiness {
    case preparing, ready(String), unavailable(String), interrupted(String)
}

@MainActor
protocol SpeechCapturing: AnyObject {
    var onEvent: ((UUID, SpeechEvent) -> Void)? { get set }
    var onReadiness: ((SpeechReadiness) -> Void)? { get set }
    func prepare(inputUID: String?) async throws -> String
    func suspend() async
    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String
    func finish()
    func cancel()
}
