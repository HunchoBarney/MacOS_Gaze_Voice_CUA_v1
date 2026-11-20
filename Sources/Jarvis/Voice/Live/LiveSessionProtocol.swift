import Foundation

/// The seam between the GPT-Live transport and the parts of Jarvis that use
/// it. The transport (L1) decodes server events into `LiveSessionEvent`,
/// encodes `LiveAppend` into client events and creates sessions from
/// `LiveSessionConfig`. The delegation bridge (L2) and the listening states
/// (L3) see only these types, so they run against a fake in tests.
///
/// Field names follow OpenAI's GPT-Live client delegation guide
/// (developers.openai.com/api/docs/guides/live-delegation, read 2026-11-20).

/// One server event the bridge and listening states care about.
enum LiveSessionEvent: Sendable, Equatable {
    /// `session.started`, with `session.id`.
    case started(sessionID: String)
    /// `session.input_transcript.delta`: what the person said.
    case inputTranscript(LiveTranscriptDelta)
    /// `session.output_transcript.delta`: what Live said.
    case outputTranscript(LiveTranscriptDelta)
    /// `session.delegation.created` with `delegation.target == "client"`.
    /// It carries no task text and no call id.
    case delegation(LiveDelegation)
    /// `session.paused`: Standby.
    case paused
    /// `session.resumed`: speech woke the session from Standby. Anyone in
    /// the room can do that, not only the person who said the name.
    case resumed
    /// `session.closed`.
    case closed(LiveCloseReason)
}

/// `session.closed` `reason`, from OpenAI's Live API reference (2026-11-20).
enum LiveCloseReason: Sendable, Equatable {
    /// Jarvis sent `session.close`, or the broker hung up.
    case closeRequested
    /// The session reached its duration limit.
    case expired
    /// A safety filter ended it.
    case content
    /// The far side disconnected gracefully.
    case remoteHangup
    /// The primary or upstream connection dropped unexpectedly.
    case connectionLost
    /// A reason this build doesn't know yet.
    case other(String)

    init(_ reason: String) {
        switch reason {
        case "close_requested": self = .closeRequested
        case "expired": self = .expired
        case "content": self = .content
        case "remote_hangup": self = .remoteHangup
        case "connection_lost": self = .connectionLost
        default: self = .other(reason)
        }
    }
}

/// A transcript fragment. `startMs`/`endMs` are milliseconds from the start
/// of the session, end exclusive. A fragment is not a whole turn.
struct LiveTranscriptDelta: Sendable, Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
}

/// `session.delegation.created`: `delegation.id` and the event's `offset_ms`.
struct LiveDelegation: Sendable, Equatable {
    let id: String
    let offsetMs: Int
}

/// One client event that adds text to the conversation. `content` is a
/// plain string of at most 500 tokens. `delegationID` must name a client
/// delegation of the current session, or be nil for general context.
struct LiveAppend: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// Facts or progress Live may use later without saying them now.
        case thinking = "session.thinking.append"
        /// A result Live says aloud, in its own words.
        case commentary = "session.commentary.append"
        /// An instruction for the rest of the conversation.
        case instructions = "session.instructions.append"
    }
    let kind: Kind
    let content: String
    let delegationID: String?
}

/// The open session's outgoing side. Sending to a closed session is dropped
/// by the transport.
@MainActor
protocol LiveSessionSending: AnyObject {
    func send(_ append: LiveAppend)
}

/// What the app sends to the broker's `POST /v1/live/sessions` (#582).
/// The broker fixes the model, client delegation, no tools, no storage and
/// the speech wake policy, and refuses any other field. There's no tools
/// field here on purpose: GPT-Live never acts on its own, and the only way to
/// an action is a client delegation the bridge's ledger admits.
struct LiveSessionConfig: Sendable, Equatable {
    var instructions: String
    var voice = "marin"
    /// `idle_timeout_s`, 5–60: talking turns into Standby after this.
    var idleTimeoutS = 8

    func brokerBody(sdp: String) -> [String: Any] {
        ["sdp": sdp, "instructions": instructions, "voice": voice, "idle_timeout_s": idleTimeoutS]
    }
}
