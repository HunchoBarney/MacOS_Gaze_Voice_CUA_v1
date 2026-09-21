import Foundation
import JevVoiceCore

enum SpeechEvent {
    case partial(String), final(String), failure(String), level(Float)
    case revision(SpeechRevision, transcript: String)
    case timing(String, milliseconds: Double)
}

@MainActor
protocol SpeechCapturing: AnyObject {
    var onEvent: ((UUID, SpeechEvent) -> Void)? { get set }
    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String
    func finish()
    func cancel()
}

