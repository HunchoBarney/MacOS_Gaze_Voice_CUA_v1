import AVFoundation
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

    var title: String { title(name: AssistantName.standard) }

    func title(name: String) -> String {
        switch self {
        case .conversation: return "Hands-free"
        case .standby: return "Wait for “Hey \(name)”"
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
    var disclosure: String { disclosure(name: AssistantName.standard) }

    func disclosure(name: String) -> String {
        switch self {
        case .conversation:
            return "When you speak, your voice goes to OpenAI and your words go to TypeSafe, so Jarvis can understand you. Long silences and room noise stay on your Mac."
        case .standby:
            return "Nothing leaves your Mac until you say “Hey \(name)”. Then your voice goes to OpenAI and your words go to TypeSafe, so Jarvis can understand you."
        case .pushToTalk:
            return "While you hold fn, everything Jarvis hears goes to OpenAI and your words go to TypeSafe, so it can understand you. Nothing is sent once you let go."
        }
    }
}

/// A local wake-word engine (`VoskWakeWordDetector`), registered in
/// `ListeningPolicy.wakeWord` at launch when the build carries it.
protocol WakeWordDetecting: AnyObject, Sendable {
    /// Starts spotting "Hey <name>" in the audio passed to `hear`. `heard`
    /// fires once per wake phrase with the moment it was first heard, on
    /// the `systemUptime` clock.
    func start(name: String, heard: @escaping @MainActor (TimeInterval) -> Void) throws
    func stop()
    /// Microphone audio straight from the input tap, on its audio thread.
    func hear(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
    /// Why the engine can't listen for this name, in words for the person
    /// typing it; nil when it can. May load the model, so call it off the
    /// main actor.
    func problem(with name: String) -> String?
}

/// The name in "Hey <name>": 1–20 letters, spaces, apostrophes or hyphens.
enum AssistantName {
    static let standard = "Jarvis"

    static func cleaned(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What's wrong with a typed name, before the engine is asked.
    static func problem(with name: String) -> String? {
        let name = cleaned(name)
        if name.isEmpty { return "Type a name, like \(standard)." }
        if name.count > 20 { return "Keep the name to 20 letters or fewer." }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: " '’-"))
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use only letters, spaces, apostrophes and hyphens."
        }
        return nil
    }
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
