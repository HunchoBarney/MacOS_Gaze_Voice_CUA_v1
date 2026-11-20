import Foundation

/// How loudly an alert reaches the person. Speak now is one spoken
/// sentence with an offer; glow is a badge Jarvis reads out on "what's
/// up"; digest waits for "what did I miss".
enum ProactiveTier: Int, Comparable, Sendable {
    case digest, glow, speakNow
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum ProactiveCategory: String, Codable, CaseIterable, Sendable {
    case meetingNow, meetingClash, urgentMessage, awaitedReply, reminder, security
    case message, update, other

    var baseTier: ProactiveTier {
        switch self {
        case .meetingNow, .meetingClash, .urgentMessage, .awaitedReply, .reminder, .security: .speakNow
        case .message, .update: .glow
        case .other: .digest
        }
    }

    /// Security warnings and reminders the person set never count against
    /// the spoken budget and are never demoted by quiet levels.
    var exemptFromBudget: Bool { self == .security || self == .reminder }

    /// "Not now" never teaches Jarvis to hide a security warning.
    var learns: Bool { self != .security }
}

enum ProactiveSource: String, Codable, Sendable {
    case calendar, reminders, safety, notifications
}

/// What "yes" does. Everything an offer can do goes through an existing
/// path: a link opens, a request goes to the spine as if spoken, a
/// reminder is completed through EventKit, or text is read aloud on the Mac.
enum ProactiveAction: Equatable, Sendable {
    case openURL(URL)
    case request(String)
    case completeReminder(String)
    case read(String)
}

struct ProactiveAlert: Equatable, Identifiable, Sendable {
    /// Stable across polls: a key is delivered once.
    var key: String
    var source: ProactiveSource
    var category: ProactiveCategory
    /// One short clause without a full stop: "Standup starts in 2 minutes".
    var headline: String
    /// The question after the headline: "Want me to open the meeting link?"
    var offer: String?
    var action: ProactiveAction?
    var sender: String? = nil
    var at: Date
    /// After this the alert is stale and only reaches the digest.
    var expires: Date? = nil

    var id: String { key }
    var sentence: String { headline + "." }
    var spoken: String { [sentence, offer].compactMap { $0 }.joined(separator: " ") }
}

/// The more/less setting. Quiet speaks only safety and the person's own
/// reminders; Chatty also speaks glow items and allows more per hour.
enum ProactiveLevel: String, CaseIterable, Codable, Sendable {
    case quiet, normal, chatty

    var label: String {
        switch self {
        case .quiet: "Quiet"
        case .normal: "Normal"
        case .chatty: "Chatty"
        }
    }

    var hourlyCap: Int { self == .chatty ? 6 : 3 }
    var dailyCap: Int { self == .chatty ? 20 : 10 }
}
