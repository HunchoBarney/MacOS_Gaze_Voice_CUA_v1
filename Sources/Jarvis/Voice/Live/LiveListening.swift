import Foundation

/// The words that steer listening, heard in Live's transcript of the user.
/// "That's all" and "stay with me" change the listening state here; stop,
/// cancel and undo go to whatever is running the work.
enum LiveControlWord: String, Equatable, Sendable, CaseIterable {
    case thatsAll, stayWithMe, stop, cancel, undo

    /// The control word a whole utterance amounts to, or nil when it says
    /// anything more. "Open Mail, that's all" is a request, not a goodbye.
    static func find(in utterance: String, name: String) -> LiveControlWord? {
        let filler = Set(["hey", "ok", "okay", "please", "thanks", "thank", "you"]
            + name.lowercased().split(separator: " ").map(String.init))
        let words = utterance.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
            .joined(separator: " ")
        switch words {
        case "that's all", "that is all", "that's it", "that'll be all", "goodbye", "bye": return .thatsAll
        case "stay with me", "keep listening": return .stayWithMe
        case "stop", "stop that": return .stop
        case "cancel", "cancel that", "never mind", "nevermind": return .cancel
        case "undo", "undo that": return .undo
        default: return nil
        }
    }
}

/// KAR-75 L3: when Jarvis listens, and when a GPT-Live session is open.
///
/// - Asleep: only the wake word listens, on the Mac. Nothing leaves it.
/// - Connecting, Talking: a session is open and Live is listening.
/// - Standby: the session is open but paused (Live's idle timeout); any
///   speech resumes it.
/// - Off: listening is paused.
///
/// Jarvis closes the session itself: 8 s after a wake that brought no
/// request (a false wake), 90 s after the last turn, on "that's all", or,
/// after "stay with me", 30 minutes after the last turn. An utterance counts
/// as a control word only once it has settled (no new words for a moment, or
/// Live answered), so "stop the music" never reads as "stop". Times are
/// seconds on one monotonic clock, passed in, so tests drive them.
struct LiveListening: Equatable {
    enum State: Equatable { case asleep, connecting, talking, standby, off }

    enum Input: Equatable {
        case wake
        case started
        case resumed
        case paused
        /// The user's words so far in this turn.
        case heard(utterance: String)
        /// Live said something.
        case answered
        /// Live handed a task to Jarvis.
        case delegated
        /// The session ended, for any reason.
        case ended
        case pause, resume
        /// A deadline passed.
        case tick
    }

    enum Effect: Equatable {
        case openSession
        case closeSession
        case control(LiveControlWord)
    }

    struct Timings: Equatable {
        var falseWake: TimeInterval = 8
        var followUp: TimeInterval = 90
        var holdCap: TimeInterval = 30 * 60
        /// How long after the user's last words Jarvis shows it's thinking.
        var thinkingAfter: TimeInterval = 0.3
        /// How long an utterance must go without new words to be judged whole.
        var settle: TimeInterval = 0.8
    }

    let name: String
    let timings: Timings
    private(set) var state: State = .asleep
    /// "Stay with me": the 90 s close waits for "that's all" or the cap.
    private(set) var held = false
    private var startedAt: TimeInterval?
    private var lastTurnAt: TimeInterval?
    private var lastHeardAt: TimeInterval?
    private var unsettled: String?
    /// The user has spoken (or a task was handed over) since Live last answered.
    private var awaitingAnswer = false

    init(name: String, timings: Timings = Timings()) {
        self.name = name
        self.timings = timings
    }

    var sessionOpen: Bool { state == .connecting || state == .talking || state == .standby }

    /// Whether to show that Jarvis is working out an answer: the user has
    /// stopped talking, or handed over a task, and Live hasn't answered.
    func thinking(at now: TimeInterval) -> Bool {
        guard sessionOpen, awaitingAnswer, let lastHeardAt else { return false }
        return now - lastHeardAt >= timings.thinkingAfter
    }

    /// The next moment `tick` has something to do, if any.
    func deadline(after now: TimeInterval) -> TimeInterval? {
        guard state == .talking || state == .standby else { return nil }
        var moments = [closeAt].compactMap { $0 }
        if let lastHeardAt {
            if unsettled != nil { moments.append(lastHeardAt + timings.settle) }
            if awaitingAnswer, now < lastHeardAt + timings.thinkingAfter {
                moments.append(lastHeardAt + timings.thinkingAfter)
            }
        }
        return moments.min()
    }

    mutating func handle(_ input: Input, at now: TimeInterval) -> [Effect] {
        switch input {
        case .pause:
            let wasOpen = sessionOpen
            state = .off
            reset()
            return wasOpen ? [.closeSession] : []
        case .resume:
            if state == .off { state = .asleep }
            return []
        case .wake:
            guard state == .asleep else { return [] }
            reset()
            state = .connecting
            return [.openSession]
        case .started:
            guard state == .connecting else { return [] }
            state = .talking
            startedAt = now
            return []
        case .resumed:
            if state == .standby { state = .talking }
            return []
        case .paused:
            if state == .talking { state = .standby }
            return []
        case .heard(let utterance):
            guard state == .talking || state == .standby else { return [] }
            state = .talking
            unsettled = utterance
            lastTurnAt = now
            lastHeardAt = now
            awaitingAnswer = true
            return []
        case .answered, .delegated:
            guard state == .talking || state == .standby else { return [] }
            let effects = settle(now: now, force: true)
            guard sessionOpen else { return effects }
            lastTurnAt = now
            awaitingAnswer = input == .delegated
            if input == .delegated, lastHeardAt == nil { lastHeardAt = now }
            return effects
        case .ended:
            guard sessionOpen else { return [] }
            state = .asleep
            reset()
            return []
        case .tick:
            guard state == .talking || state == .standby else { return [] }
            let effects = settle(now: now, force: false)
            if !sessionOpen { return effects }
            if let closeAt, now >= closeAt { return effects + close() }
            return effects
        }
    }

    private var closeAt: TimeInterval? {
        if let lastTurnAt { return lastTurnAt + (held ? timings.holdCap : timings.followUp) }
        return startedAt.map { $0 + timings.falseWake }
    }

    private mutating func settle(now: TimeInterval, force: Bool) -> [Effect] {
        guard let utterance = unsettled, let lastHeardAt,
              force || now - lastHeardAt >= timings.settle else { return [] }
        unsettled = nil
        switch LiveControlWord.find(in: utterance, name: name) {
        case nil: return []
        case .thatsAll?: return close()
        case .stayWithMe?:
            held = true
            awaitingAnswer = false
            return []
        case let word?:
            awaitingAnswer = false
            return [.control(word)]
        }
    }

    private mutating func close() -> [Effect] {
        state = .asleep
        reset()
        return [.closeSession]
    }

    private mutating func reset() {
        held = false
        startedAt = nil
        lastTurnAt = nil
        lastHeardAt = nil
        unsettled = nil
        awaitingAnswer = false
    }
}
