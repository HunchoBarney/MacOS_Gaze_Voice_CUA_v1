import Foundation

/// The companion layer's deterministic half: canned or clock-derived replies
/// for whole-utterance exchanges a model round trip adds nothing to — "what
/// time is it", "thanks", "are you there" should never wait on commit →
/// response.create → generated audio when the answer is already known.
///
/// Matching is exact after normalization, the same discipline CuaFastLane
/// uses: the normalized utterance must BE the exchange, not contain it.
/// Anything carrying a verb, a qualifier, or a trailing clause falls through
/// to the model turn — this layer can never answer a work request instead of
/// doing it, and a factual question the clock can't settle ("what time is it
/// in Tokyo") stays with the model and web_lookup.
enum CompanionBrain {

    /// The one call sites need: the reply for an instantly answerable
    /// utterance, or nil when the model turn should have it. `now`/`calendar`
    /// are the test clock; production callers take the defaults.
    ///
    /// `askPending` gates EVERYTHING. The caller folds every parked ask into
    /// it — task consents, dialogue questions, and the agent-gate consent —
    /// because the user's next words may be that answer, and a local match
    /// must never consume them before respond_to_task and the gate see them.
    static func instantReply(for text: String, askPending: Bool,
                             now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard !askPending else { return nil }
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        if clockPhrases.contains(normalized) {
            return "It's \(formatter("h:mm a", calendar: calendar).string(from: now))."
        }
        if datePhrases.contains(normalized) {
            return "It's \(formatter("EEEE, MMMM d", calendar: calendar).string(from: now))."
        }
        return table[normalized]
    }

    /// Spoken-name and politeness prefixes that carry no request. Stripped
    /// like CuaFastLane's fillers so "hey Jarvis, thanks" lands — kept
    /// narrower than the command list: "can you" stays, because "can you
    /// hear me" is a companion phrase while stripping it would also reach
    /// into requests ("can you open Notes"), which must not be re-keyed here.
    private static let fillers = ["hey jev", "hey jarvis", "jev", "jarvis",
                                  "please", "just"]

    private static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: #"[''’‘]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[.,!?;:"“”]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        for filler in fillers {
            if s == filler { s = ""; break }
            if s.hasPrefix(filler + " ") { s.removeFirst(filler.count + 1) }
        }
        if s.hasSuffix(" please") { s = String(s.dropLast(7)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Exact bare-phrase time asks only — a locale qualifier or any tail
    /// ("in Tokyo", "does the meeting start") misses the set and goes to the
    /// model, so the local clock is never quoted for a question it can't
    /// answer honestly.
    private static let clockPhrases: Set<String> = [
        "time", "what time is it", "whats the time", "what is the time",
        "tell me the time", "do you have the time", "got the time",
        "do you know the time", "current time", "whats the current time"
    ]

    private static let datePhrases: Set<String> = [
        "date", "what day is it", "whats the date", "what is the date",
        "whats today", "what is today", "what day is today",
        "what day of the week is it", "whats the date today",
        "whats todays date", "what is todays date", "todays date"
    ]

    /// Whole-utterance canned exchanges. Nothing here asks for an action,
    /// so an exact match can never starve the computer-use path. "stop",
    /// "cancel" and every verb phrase stay out — cancel_task owns them.
    /// Verdict words ("yes", "no", "ok", "sure") stay out too: askPending
    /// only covers parked asks, not the model's own spoken questions —
    /// "okay" answering "want me to go on?" must reach the model's context,
    /// not die on a canned "Okay."
    private static let table: [String: String] = [
        "hi": "Hi.",
        "hello": "Hi.",
        "hey": "Hey.",
        "hi there": "Hi.",
        "hello there": "Hi.",
        "hey there": "Hey.",
        "howdy": "Hey.",
        "good morning": "Good morning.",
        "good afternoon": "Good afternoon.",
        "good evening": "Good evening.",
        "thanks": "You're welcome.",
        "thank you": "You're welcome.",
        "thank you very much": "You're welcome.",
        "thanks a lot": "You're welcome.",
        "much appreciated": "You're welcome.",
        "bye": "Bye.",
        "goodbye": "Bye.",
        "see you": "Bye.",
        "see you later": "Bye.",
        "good night": "Good night.",
        "who are you": "I'm Jev, the voice layer on this Mac.",
        "what are you": "I'm Jev, the voice layer on this Mac.",
        "whats your name": "Jev.",
        "what is your name": "Jev.",
        "how are you": "Running fine. What do you need.",
        "how are you doing": "Running fine. What do you need.",
        "hows it going": "Running fine. What do you need.",
        "how is it going": "Running fine. What do you need.",
        "are you there": "Still here.",
        "you there": "Still here.",
        "are you awake": "Still here.",
        "are you listening": "I hear you.",
        "can you hear me": "I hear you.",
        "testing": "I hear you.",
        "test": "I hear you.",
        "help": "Ask me to work an app, look something up, or just talk.",
        "what can you do": "Ask me to work an app, look something up, or just talk.",
        "what do you do": "I work apps on your Mac, answer questions, and talk."
    ]

    /// Per-call formatter: injected calendars carry their own timezone, and
    /// a shared static DateFormatter is not thread-safe to reconfigure. The
    /// POSIX locale pins English "PM"/weekday output to match the canned
    /// table's voice regardless of the host locale.
    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
