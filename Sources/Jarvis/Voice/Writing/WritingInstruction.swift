import Foundation

/// What a spoken writing instruction asks for (plan §8, L7).
enum WritingIntent: Sendable, Equatable {
    /// "Type this 'see you at five'": the exact words, case and punctuation kept.
    case type(literal: String)
    /// "Come up with a reply for this".
    case draftReply
    /// "Send it". It only means something while a draft is waiting.
    case sendDraft
}

/// What the caller knows about the utterance beyond its words. Every field
/// has a default, so today's `beginVoiceTask` callers pass nothing.
struct WritingInput: Sendable, Equatable {
    /// Uptime of "this" when it was said, from `DelegationBridge.deicticStartMs`.
    var deicticTime: TimeInterval?
    /// An independent local transcription of the same audio. When nil,
    /// `WritingByInstruction` asks its own local transcriber.
    var localTranscript: String?
    /// False when anyone in the room could have said it (D3): "send it"
    /// then asks before pressing Send.
    var speakerVerified = true

    init(deicticTime: TimeInterval? = nil, localTranscript: String? = nil) {
        self.deicticTime = deicticTime
        self.localTranscript = localTranscript
    }
}

/// The pure half of L7: which writing instruction an utterance is, the
/// verbatim span it carries, and whether two transcriptions of it agree.
enum WritingInstruction {
    /// A verbatim span wins over a reply request, so the words of
    /// "type this 'write a reply to that'" are typed, not drafted from.
    static func intent(_ utterance: String) -> WritingIntent? {
        if isSend(utterance) { return .sendDraft }
        if let literal = literal(in: utterance) { return .type(literal: literal) }
        return asksForReply(utterance) ? .draftReply : nil
    }

    /// Lead-ins that mark a verbatim span on their own. A bare "type" or
    /// "write" counts only before a quote, so "type hello in notes" keeps
    /// the fast lane's app qualifier and "write an email to Dana" stays a task.
    private static let leadIns = ["type the following", "type this out", "type this", "type out",
                                  "write the following", "write this down", "write this", "write down"]
    private static let quoteOnlyLeadIns = ["type", "write", "enter"]
    private static let fillers = ["hey jarvis", "jarvis", "please", "can you", "could you", "would you",
                                  "now", "ok", "okay"]
    private static let openQuotes: [Character: Set<Character>] = [
        "\"": ["\""], "“": ["”", "\""], "'": ["'"], "‘": ["’", "'"], "«": ["»"], "„": ["“", "”"],
    ]
    private static let spokenEnds = ["end of quote", "end quote", "close quote", "unquote"]

    /// The exact words after a writing lead-in, up to a closing quote, a
    /// spoken "end quote" or the end of the utterance. Unquoted spans lose
    /// the sentence mark ASR adds at the end; quoted spans stay verbatim.
    static func literal(in utterance: String) -> String? {
        var rest = Substring(utterance.trimmingCharacters(in: .whitespacesAndNewlines))
        while let filler = fillers.first(where: { startsWithWord(rest, $0) }) {
            rest = trimmedLead(rest.dropFirst(filler.count))
        }
        var quoteOnly = false
        if let lead = leadIns.first(where: { startsWithWord(rest, $0) }) {
            rest = rest.dropFirst(lead.count)
        } else if let lead = quoteOnlyLeadIns.first(where: { startsWithWord(rest, $0) }) {
            rest = rest.dropFirst(lead.count)
            quoteOnly = true
        } else {
            return nil
        }
        rest = trimmedLead(rest)
        var spokenQuote = false
        if startsWithWord(rest, "quote") {
            rest = trimmedLead(rest.dropFirst("quote".count))
            spokenQuote = true
        }
        if let open = rest.first, let closers = openQuotes[open] {
            let inner = rest.dropFirst()
            guard let close = inner.lastIndex(where: { closers.contains($0) }) else {
                return quoteOnly ? nil : span(inner, stripTerminal: true)
            }
            return span(inner[..<close], stripTerminal: false)
        }
        if let end = spokenEnd(in: rest) {
            return span(rest[..<end], stripTerminal: true)
        }
        guard !quoteOnly || spokenQuote else { return nil }
        return span(rest, stripTerminal: !spokenQuote)
    }

    /// Every span a longer transcript holds: the literal after each lead-in
    /// in it, oldest first. The local transcript covers the last 20 seconds
    /// of speech, so earlier words must not hide the request just made.
    static func literals(within transcript: String) -> [String] {
        var found: [String] = []
        var index = transcript.startIndex
        var atWordStart = true
        while index < transcript.endIndex {
            let character = transcript[index]
            if atWordStart, character.isLetter, let span = literal(in: String(transcript[index...])) {
                found.append(span)
            }
            atWordStart = !(character.isLetter || character.isNumber || character == "'" || character == "’")
            index = transcript.index(after: index)
        }
        return found
    }

    /// Two transcriptions agree when they differ only in case, punctuation
    /// and spacing. A changed letter, digit or accent is a disagreement.
    static func agrees(_ a: String, _ b: String) -> Bool {
        let fold = { (text: String) -> String in
            var scalars = String.UnicodeScalarView()
            for scalar in text.lowercased().unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                    scalars.append(scalar)
                } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    scalars.append(" ")
                }
            }
            return String(scalars).split(separator: " ").joined(separator: " ")
        }
        let left = fold(a.precomposedStringWithCanonicalMapping)
        return !left.isEmpty && left == fold(b.precomposedStringWithCanonicalMapping)
    }

    /// "Send it", "yes, send it", "send the reply" and close variants.
    static func isSend(_ utterance: String) -> Bool {
        var words = tokens(utterance)
        let leading: Set<String> = ["yes", "yeah", "yep", "ok", "okay", "jarvis", "please", "now", "go", "ahead", "and", "sure"]
        while let first = words.first, leading.contains(first) { words.removeFirst() }
        while let last = words.last, ["please", "now"].contains(last) { words.removeLast() }
        return [["send", "it"], ["send", "that"], ["send", "this"], ["send", "the", "reply"],
                ["send", "the", "draft"], ["send", "the", "message"]].contains(words)
    }

    /// Yes or no to a pending "type this?" or an unplaced draft; nil when
    /// the words are neither.
    static func confirmation(_ utterance: String) -> Bool? {
        let phrase = tokens(utterance).joined(separator: " ")
        if ["yes", "yeah", "yep", "yes please", "sure", "ok", "okay", "go ahead", "do it", "correct",
            "that s right", "type it", "yes type it", "type that", "yes type that", "put it in"].contains(phrase) {
            return true
        }
        if ["no", "nope", "don t", "dont", "do not", "don t type it", "do not type it", "no thanks",
            "never mind", "nevermind", "forget it"].contains(phrase) {
            return false
        }
        return nil
    }

    /// "Come up with a reply for this", "draft a response to that email",
    /// "write a reply to this": a composing verb, a reply noun, and a
    /// pointer at what to reply to.
    static func asksForReply(_ utterance: String) -> Bool {
        let words = tokens(utterance)
        let text = " " + words.joined(separator: " ") + " "
        let composes = [" come up with ", " draft ", " write ", " compose ", " suggest ", " think of ",
                        " give me "].contains { text.contains($0) }
        let reply = !Set(words).isDisjoint(with: ["reply", "response", "answer"])
        let pointed = !Set(words).isDisjoint(with: ["this", "that", "it", "these"])
        return composes && reply && pointed
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func startsWithWord(_ text: Substring, _ phrase: String) -> Bool {
        guard text.count >= phrase.count,
              text.prefix(phrase.count).lowercased() == phrase else { return false }
        guard let next = text.dropFirst(phrase.count).first else { return true }
        return !next.isLetter && !next.isNumber
    }

    private static func trimmedLead(_ text: Substring) -> Substring {
        text.drop { $0.isWhitespace || ":,-—–".contains($0) }
    }

    private static func spokenEnd(in text: Substring) -> Substring.Index? {
        var best: Substring.Index?
        for phrase in spokenEnds {
            var search = text.startIndex
            while let found = text.range(of: phrase, options: .caseInsensitive, range: search..<text.endIndex) {
                let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
                let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
                if before.map({ !$0.isLetter && !$0.isNumber }) ?? true,
                   after.map({ !$0.isLetter && !$0.isNumber }) ?? true {
                    if best.map({ found.lowerBound < $0 }) ?? true { best = found.lowerBound }
                    break
                }
                search = found.upperBound
            }
        }
        return best
    }

    private static func span(_ text: Substring, stripTerminal: Bool) -> String? {
        var span = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripTerminal {
            while let last = span.last, ".!?…,;:".contains(last) { span.removeLast() }
            span = span.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return span.isEmpty ? nil : span
    }
}
