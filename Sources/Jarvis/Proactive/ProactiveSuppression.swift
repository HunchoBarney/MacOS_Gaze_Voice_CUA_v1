import Foundation

/// What the person is doing right now, read fresh before every spoken
/// alert. `jarvisSpeaking` includes the one-way alert voice. `focus` is
/// nil when macOS won't say (no Focus permission).
struct ProactiveContext: Equatable, Sendable {
    var userTalking = false
    var jarvisSpeaking = false
    var onCall = false
    var screenSharing = false
    var presenting = false
    var focus: Bool? = false

    static let clear = ProactiveContext()
}

/// Whether a speak-now alert may be spoken at this moment.
enum ProactiveSuppression {
    enum Verdict: Equatable, Sendable {
        case speak
        /// Wait until the person or Jarvis stops talking, then try again.
        case hold
        /// Show a large card and say nothing: a scammer on the call would
        /// hear a spoken warning.
        case card
        /// Put it on the glow instead.
        case glow
    }

    static func verdict(for alert: ProactiveAlert, in context: ProactiveContext) -> Verdict {
        if context.userTalking || context.jarvisSpeaking { return .hold }
        let busy = context.onCall || context.screenSharing || context.presenting || context.focus == true
        guard busy else { return .speak }
        return alert.category == .security ? .card : .glow
    }
}
