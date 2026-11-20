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
        case .conversation: return "Hands-free"
        case .standby: return "Wait for “Hey Jarvis”"
        case .pushToTalk: return "Hold fn to talk"
        }
    }

    var detail: String {
        switch self {
        case .conversation: return "Jarvis listens all the time, so you can just talk."
        case .standby: return "Jarvis listens on your Mac for its name. Nothing leaves your Mac until you say it."
        case .pushToTalk: return "Hold the fn key while you speak, then let go."
        }
    }

    /// What leaves the Mac in this mode, and where it goes. Audio goes to
    /// OpenAI to hear the words; the words go to TypeSafe to understand them.
    var disclosure: String {
        switch self {
        case .conversation:
            return "When you speak, your voice goes to OpenAI and your words go to TypeSafe, so Jarvis can understand you. Long silences and room noise stay on your Mac."
        case .standby:
            return "Nothing leaves your Mac until you say its name. Then your voice goes to OpenAI and your words go to TypeSafe, so Jarvis can understand you."
        case .pushToTalk:
            return "While you hold fn, everything Jarvis hears goes to OpenAI and your words go to TypeSafe, so it can understand you. Nothing is sent once you let go."
        }
    }
}

/// A local wake-word engine. `VoskWakeWordDetector` is the one Jarvis
/// ships; it plugs in through `ListeningPolicy.wakeWord` once Standby can
/// start a turn when it fires.
protocol WakeWordDetecting: AnyObject {
    /// Starts listening locally; `heard` fires once per wake word.
    func start(heard: @escaping @MainActor () -> Void) throws
    func stop()
}

/// The rules for listening modes, given whether a wake-word engine exists.
/// Until one does, Standby isn't offered, the default is Hold fn to talk,
/// and a stored Standby choice behaves like Hands-free. The recommended
/// mode is the default and is offered first.
struct ListeningPolicy {
    var wakeWordAvailable: Bool

    /// The engine the app was built with — nil until one ships.
    nonisolated(unsafe) static var wakeWord: (any WakeWordDetecting)?
    static var current: ListeningPolicy { ListeningPolicy(wakeWordAvailable: wakeWord != nil) }

    var defaultMode: ListeningMode { wakeWordAvailable ? .standby : .pushToTalk }

    var offeredModes: [ListeningMode] {
        wakeWordAvailable ? [.standby, .pushToTalk, .conversation] : [.pushToTalk, .conversation]
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
