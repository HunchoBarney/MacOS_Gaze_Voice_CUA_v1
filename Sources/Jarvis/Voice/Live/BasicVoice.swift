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
