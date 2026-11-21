import Foundation

/// The spoken memory intents: "remember X", "who's X?" and "forget that".
enum MemoryIntent: Equatable {
    case remember(String)
    /// `explicit` is "what do you remember about X": it answers even when
    /// nothing matches. A bare "who's X?" reads only remembered facts, never
    /// past requests, and falls through to the rest of Jarvis when there are
    /// none, so "who's the CEO of Apple?" still works.
    case recall(String, explicit: Bool)
    case forgetLast

    static func parse(_ utterance: String) -> MemoryIntent? {
        var text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".?!,".contains(last) { text.removeLast() }
        let lead = ["hey, jarvis", "hey jarvis", "please", "can you", "could you", "would you", "jarvis"]
        while let polite = lead.first(where: {
            text.lowercased().hasPrefix($0) && text.dropFirst($0.count).first.map { " ,.!".contains($0) } == true
        }) {
            text = String(text.dropFirst(polite.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!"))
        }
        let lower = text.lowercased()
        if ["forget that", "forget it", "forget this", "forget what i just said",
            "don't remember that", "don't remember this", "do not remember that",
            "do not remember this"].contains(lower) {
            return .forgetLast
        }
        for prefix in ["remember that ", "remember "] where lower.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            let restLower = rest.lowercased()
            guard !rest.isEmpty, !["that", "this", "it"].contains(restLower), !restLower.hasPrefix("to "), !restLower.hasPrefix("when "),
                  !restLower.hasPrefix("what "), !restLower.hasPrefix("how ") else { return nil }
            return .remember(rest)
        }
        for (prefix, explicit) in [("what do you remember about ", true), ("what do you know about ", true),
                                   ("who's ", false), ("who is ", false)] where lower.hasPrefix(prefix) {
            var subject = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if subject.lowercased().hasPrefix("my ") { subject = String(subject.dropFirst(3)) }
            guard explicit || MemoryStore.anyWordPattern(subject) != nil else { return nil }
            return subject.isEmpty ? nil : .recall(subject, explicit: explicit)
        }
        return nil
    }
}

/// Answers the memory intents against `MemoryStore`. "Forget that" deletes
/// what the last answer remembered or recalled, but only for two minutes:
/// after that the words go on to the rest of Jarvis.
@MainActor
final class MemoryCommands {
    static let forgetWindow: TimeInterval = 120

    private let store: () -> MemoryStore
    private let now: () -> Date
    private var lastTouched: (ids: [Int64], at: Date)?

    init(store: @escaping () -> MemoryStore = { .shared }, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Whether `handle` would answer `utterance`, without remembering,
    /// recalling or forgetting anything. Admission asks this first, so a
    /// memory intent is answered on the Mac instead of reaching the model.
    func answers(_ utterance: String) -> Bool {
        switch MemoryIntent.parse(utterance) {
        case nil: return false
        case .remember, .recall(_, explicit: true): return true
        case .recall(let subject, explicit: false):
            return (try? store().recall(subject, includeRequests: false).isEmpty == false) ?? false
        case .forgetLast: return lastTouched.map { now().timeIntervalSince($0.at) <= Self.forgetWindow } ?? false
        }
    }

    /// The spoken reply when `utterance` is a memory intent, or nil when
    /// it isn't one and should be handled as an ordinary request.
    func handle(_ utterance: String) -> String? {
        guard let intent = MemoryIntent.parse(utterance) else { return nil }
        do {
            switch intent {
            case .remember(let words):
                let memory = try store().remember(words)
                lastTouched = memory.id.map { ([$0], now()) }
                return "Okay, I'll remember that."
            case .recall(let subject, let explicit):
                let found = try store().recall(subject, includeRequests: explicit)
                guard !found.isEmpty else {
                    return explicit ? "I don't remember anything about \(subject)." : nil
                }
                lastTouched = (found.compactMap(\.id), now())
                return found.map { Self.spoken($0.text) }.joined(separator: " ")
            case .forgetLast:
                guard let last = lastTouched, now().timeIntervalSince(last.at) <= Self.forgetWindow else {
                    return nil
                }
                try store().delete(last.ids)
                lastTouched = nil
                return "Okay, I've forgotten that."
            }
        } catch MemoryError.empty {
            return "What should I remember?"
        } catch {
            return "I can't reach my memory right now."
        }
    }

    /// The user's words read back to them: "Dana is my manager" becomes
    /// "Dana is your manager.".
    static func spoken(_ text: String) -> String {
        let swaps = ["i": "you", "i'm": "you're", "me": "you", "my": "your", "mine": "yours",
                     "myself": "yourself", "am": "are", "i've": "you've", "i'd": "you'd",
                     "i'll": "you'll", "our": "your", "ours": "yours", "we": "you", "us": "you"]
        let kept = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’"))
        var words = text.split(separator: " ").map(String.init)
        for index in words.indices {
            let word = words[index]
            let core = word.trimmingCharacters(in: kept)
            let key = core.lowercased().replacingOccurrences(of: "’", with: "'")
            guard var swap = swaps[key] else { continue }
            if key == "am", index == 0 || words[index - 1].lowercased() != "you" { continue }
            if index == 0 { swap = swap.prefix(1).uppercased() + swap.dropFirst() }
            words[index] = word.replacingOccurrences(of: core, with: swap)
        }
        var sentence = words.joined(separator: " ")
        if let last = sentence.last, !".?!".contains(last) { sentence += "." }
        return sentence
    }
}
