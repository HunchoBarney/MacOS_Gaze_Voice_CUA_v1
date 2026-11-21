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

    var title: String { title(name: AssistantName.standard) }

    func title(name: String) -> String {
        switch self {
        case .conversation: return "Hands-free"
        case .standby: return "Wait for “Hey \(name)”"
        }
    }

    var detail: String {
        switch self {
        case .conversation: return "Jarvis listens all the time, so you can just talk."
        case .standby: return "Jarvis listens on your Mac for its name. Nothing leaves your Mac until you say it."
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
/// Standby is the default and is offered first. Without an engine it can't
/// arm and Jarvis says so; it never falls back to streaming.
struct ListeningPolicy {
    var wakeWordAvailable: Bool

    /// The engine the app was built with — nil until one ships.
    nonisolated(unsafe) static var wakeWord: (any WakeWordDetecting)?
    static var current: ListeningPolicy { ListeningPolicy(wakeWordAvailable: wakeWord != nil) }

    var defaultMode: ListeningMode { .standby }

    var offeredModes: [ListeningMode] { [.standby, .conversation] }

    /// Whether the mode keeps a speech session streaming between turns.
    func streamsContinuously(_ chosen: ListeningMode) -> Bool { chosen == .conversation }

    /// The first-run screen that explains the orange microphone dot shows
    /// only when Standby can actually run.
    var showsStandbyIntro: Bool { wakeWordAvailable }
}
