import Foundation

/// GPT-Live's data-channel events, decoded into what Jarvis acts on. The wire
/// shapes follow OpenAI's Live reference (session.started, paused, resumed,
/// usage, transcript deltas, error, closed); anything else is kept by name so
/// a new server event never breaks a session.
enum LiveServerEvent: Equatable, Sendable {
    case started(sessionID: String)
    case resumed
    case paused
    case usage(LiveUsage)
    case inputTranscript(LiveTranscriptDelta)
    case outputTranscript(LiveTranscriptDelta)
    case error(LiveError)
    case closed(reason: LiveCloseReason, usage: LiveUsage)
    case other(type: String)

    init(json: Data) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: json)
        switch wire.type {
        case "session.started":
            guard let id = wire.session?.id else { throw LiveEventError.missing("session.id", in: wire.type) }
            self = .started(sessionID: id)
        case "session.resumed": self = .resumed
        case "session.paused": self = .paused
        case "session.usage.updated":
            guard let usage = wire.usage else { throw LiveEventError.missing("usage", in: wire.type) }
            self = .usage(usage.with(contextRatio: wire.context_window?.usage_ratio))
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let delta = wire.delta, let start = wire.start_ms, let end = wire.end_ms else {
                throw LiveEventError.missing("delta", in: wire.type)
            }
            let fragment = LiveTranscriptDelta(text: delta, startMs: start, endMs: end)
            self = wire.type == "session.input_transcript.delta" ? .inputTranscript(fragment) : .outputTranscript(fragment)
        case "error":
            guard let error = wire.error else { throw LiveEventError.missing("error", in: wire.type) }
            self = .error(error)
        case "session.closed":
            guard let reason = wire.reason, let usage = wire.usage else {
                throw LiveEventError.missing("reason or usage", in: wire.type)
            }
            self = .closed(reason: LiveCloseReason(rawValue: reason) ?? .other(reason), usage: usage)
        default:
            self = .other(type: wire.type)
        }
    }

    private struct Wire: Decodable {
        struct Session: Decodable { let id: String }
        struct ContextWindow: Decodable { let usage_ratio: Double }
        let type: String
        let session: Session?
        let usage: LiveUsage?
        let context_window: ContextWindow?
        let delta: String?
        let start_ms: Int?
        let end_ms: Int?
        let error: LiveError?
        let reason: String?
    }
}

enum LiveEventError: Error, Equatable {
    case missing(String, in: String)
}

/// Cumulative billable seconds. Each report replaces the last; never sum them.
struct LiveUsage: Equatable, Sendable, Decodable {
    let seconds: Double
    var activeSeconds: Int?
    var pausedSeconds: Int?
    var contextRatio: Double?

    init(seconds: Double, activeSeconds: Int? = nil, pausedSeconds: Int? = nil, contextRatio: Double? = nil) {
        self.seconds = seconds; self.activeSeconds = activeSeconds
        self.pausedSeconds = pausedSeconds; self.contextRatio = contextRatio
    }

    private enum CodingKeys: String, CodingKey {
        case seconds, activeSeconds = "active_seconds", pausedSeconds = "paused_seconds"
    }

    func with(contextRatio: Double?) -> LiveUsage {
        var usage = self; usage.contextRatio = contextRatio; return usage
    }
}

/// One transcript fragment and where it sits on the session timeline.
struct LiveTranscriptDelta: Equatable, Sendable {
    let text: String
    let startMs: Int
    let endMs: Int
}

struct LiveError: Equatable, Sendable, Decodable {
    let type: String
    let code: String?
    let message: String
    var clientEventID: String?
    var param: String?

    private enum CodingKeys: String, CodingKey {
        case type, code, message, clientEventID = "client_event_id", param
    }
}

/// Why a session ended, from session.closed.
enum LiveCloseReason: Equatable, Sendable {
    case closeRequested, expired, content, remoteHangup, connectionLost
    case other(String)

    init?(rawValue: String) {
        switch rawValue {
        case "close_requested": self = .closeRequested
        case "expired": self = .expired
        case "content": self = .content
        case "remote_hangup": self = .remoteHangup
        case "connection_lost": self = .connectionLost
        default: return nil
        }
    }
}

/// The commands Jarvis sends on the data channel.
enum LiveClientCommand: Equatable, Sendable {
    case close
    case appendInstructions(String)
    case appendThinking(String, delegationID: String?)
    case appendCommentary(String, delegationID: String?)
    case muteInput
    case unmuteInput

    func json(eventID: String) throws -> Data {
        var body: [String: Any] = ["event_id": eventID]
        switch self {
        case .close: body["type"] = "session.close"
        case .muteInput: body["type"] = "session.input_audio.mute"
        case .unmuteInput: body["type"] = "session.input_audio.unmute"
        case .appendInstructions(let text):
            body["type"] = "session.instructions.append"
            body["content"] = text; body["delegation_id"] = NSNull()
        case .appendThinking(let text, let delegation):
            body["type"] = "session.thinking.append"
            body["content"] = text; body["delegation_id"] = delegation ?? NSNull()
        case .appendCommentary(let text, let delegation):
            body["type"] = "session.commentary.append"
            body["content"] = text; body["delegation_id"] = delegation ?? NSNull()
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
