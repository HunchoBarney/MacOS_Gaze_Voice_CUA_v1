import Foundation

/// How a turn starts. Settings, the first run, the menu-bar icon and the
/// microphone lifecycle read this, so a new mode lands here and nowhere
/// else.
enum ListeningMode: String, CaseIterable, Sendable {
    /// Every sentence is a turn. Audio streams to the speech service while
    /// listening is on.
    case conversation
    /// A local wake word ("Hey Jarvis") opens the turn. Nothing leaves the
    /// Mac until it's heard.
    case standby
    /// A turn lasts while fn is held.
    case pushToTalk

    var title: String {
        switch self {
        case .conversation: return "Listen all the time"
        case .standby: return "Wait for “Hey Jarvis”"
        case .pushToTalk: return "Only while I hold fn"
        }
    }

    var detail: String {
        switch self {
        case .conversation: return "Just talk. Say “pause listening” when you need quiet."
        case .standby: return "Jarvis listens on your Mac for its name. Nothing leaves your Mac until you say it."
        case .pushToTalk: return "Hold fn, speak, let go."
        }
    }
}

/// A local wake-word engine. None ships yet: the engine arrives as its own
/// change and plugs in through `ListeningPolicy.wakeWord`.
protocol WakeWordDetecting: AnyObject {
    /// Starts listening locally; `heard` fires once per wake word.
    func start(heard: @escaping @MainActor () -> Void) throws
    func stop()
}

/// The rules for listening modes, given whether a wake-word engine exists.
/// Until one does, Standby isn't offered, the default stays Listen all the
/// time, and a stored Standby choice behaves like Listen all the time.
struct ListeningPolicy {
    var wakeWordAvailable: Bool

    /// The engine the app was built with — nil until one ships.
    nonisolated(unsafe) static var wakeWord: (any WakeWordDetecting)?
    static var current: ListeningPolicy { ListeningPolicy(wakeWordAvailable: wakeWord != nil) }

    var defaultMode: ListeningMode { wakeWordAvailable ? .standby : .conversation }

    var offeredModes: [ListeningMode] {
        wakeWordAvailable ? [.standby, .conversation, .pushToTalk] : [.conversation, .pushToTalk]
    }

    func effective(_ chosen: ListeningMode) -> ListeningMode {
        chosen == .standby && !wakeWordAvailable ? .conversation : chosen
    }

    /// Whether the mode keeps a speech session streaming between turns.
    func streamsContinuously(_ chosen: ListeningMode) -> Bool {
        effective(chosen) == .conversation
    }

    /// The first-run screen that explains the orange microphone dot shows
    /// only when Standby can actually run.
    var showsStandbyIntro: Bool { wakeWordAvailable }
}
