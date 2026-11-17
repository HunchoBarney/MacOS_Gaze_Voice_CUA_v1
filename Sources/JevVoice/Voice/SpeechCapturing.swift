import Foundation
import JevVoiceCore

enum SpeechEvent {
    case partial(String), final(String), failure(String), level(Float)
    case timing(String, milliseconds: Double)
    /// User transcript from the realtime lane — display only; the model
    /// already heard the audio, so this text must not be re-submitted.
    case heardFinal(String)
    /// Streaming / final text of the model's spoken reply.
    case assistantDelta(String)
    case assistant(String)
    /// A tool result's verbatim `say` — the lane suppressed the second
    /// model turn, so the controller voices it through the TTS seam and
    /// fills the card's detail from it directly.
    case toolSay(String)
    /// The model finished responding for this hold (after any tool calls).
    case turnEnded
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
