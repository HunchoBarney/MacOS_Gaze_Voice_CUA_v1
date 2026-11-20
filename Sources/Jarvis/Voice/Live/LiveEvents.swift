import Foundation

/// The wire side of the Live seam: OpenAI's data-channel JSON in and out.
extension LiveSessionEvent {
    /// Decodes one server event. Events Jarvis doesn't use, and delegations
    /// for any target but the client, come back nil.
    static func decode(_ json: Data) throws -> LiveSessionEvent? {
        let wire = try JSONDecoder().decode(Wire.self, from: json)
        switch wire.type {
        case "session.started":
            guard let id = wire.session?.id else { throw LiveEventError.missing("session.id", in: wire.type) }
            return .started(sessionID: id)
        case "session.resumed": return .resumed
        case "session.paused": return .paused
        case "session.usage.updated":
            guard let usage = wire.usage else { throw LiveEventError.missing("usage", in: wire.type) }
            return .usage(usage.value(contextRatio: wire.context_window?.usage_ratio))
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let text = wire.delta, let start = wire.start_ms, let end = wire.end_ms else {
                throw LiveEventError.missing("delta", in: wire.type)
            }
            let delta = LiveTranscriptDelta(text: text, startMs: start, endMs: end)
            return wire.type == "session.input_transcript.delta" ? .inputTranscript(delta) : .outputTranscript(delta)
        case "session.delegation.created":
            guard let delegation = wire.delegation, let offset = wire.offset_ms else {
                throw LiveEventError.missing("delegation", in: wire.type)
            }
            guard delegation.target == "client" else { return nil }
            return .delegation(LiveDelegation(id: delegation.id, offsetMs: offset))
        case "error":
            guard let error = wire.error else { throw LiveEventError.missing("error", in: wire.type) }
            return .error(LiveError(type: error.type, code: error.code, message: error.message,
                                    clientEventID: error.client_event_id, param: error.param))
        case "session.closed":
            guard let reason = wire.reason, let usage = wire.usage else {
                throw LiveEventError.missing("reason or usage", in: wire.type)
            }
            return .closed(reason: LiveCloseReason(reason), usage: usage.value(contextRatio: nil))
        default:
            return nil
        }
    }

    private struct Wire: Decodable {
        struct Session: Decodable { let id: String }
        struct Usage: Decodable {
            let seconds: Double
            let active_seconds: Int?
            let paused_seconds: Int?
            func value(contextRatio: Double?) -> LiveUsage {
                LiveUsage(seconds: seconds, activeSeconds: active_seconds, pausedSeconds: paused_seconds,
                          contextRatio: contextRatio)
            }
        }
        struct ContextWindow: Decodable { let usage_ratio: Double }
        struct Delegation: Decodable { let id: String; let target: String? }
        struct Failure: Decodable {
            let type: String
            let code: String?
            let message: String
            let client_event_id: String?
            let param: String?
        }
        let type: String
        let session: Session?
        let usage: Usage?
        let context_window: ContextWindow?
        let delta: String?
        let start_ms: Int?
        let end_ms: Int?
        let offset_ms: Int?
        let delegation: Delegation?
        let error: Failure?
        let reason: String?
    }
}

enum LiveEventError: Error, Equatable {
    case missing(String, in: String)
}

extension LiveAppend {
    /// The client event, with \`delegation_id\` present even when null, as the
    /// API requires.
    func json() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": kind.rawValue, "event_id": eventID, "content": content,
            "delegation_id": delegationID ?? NSNull(),
        ] as [String: Any], options: [.sortedKeys])
    }
}
