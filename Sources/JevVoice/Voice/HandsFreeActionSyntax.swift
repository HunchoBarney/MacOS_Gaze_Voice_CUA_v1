import Foundation

enum DesktopSpaceTarget: Equatable, Sendable {
    case numbered(Int), next, previous

    init?(command: String) {
        guard case .space(let target) = HandsFreeActionSyntax.parse(command) else { return nil }
        self = target
    }
}

enum HandsFreeActionSyntax: Equatable {
    case space(DesktopSpaceTarget)
    case stop, pause, nonAction, other

    private static let cardinal = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen".split(separator: " ")
    private static let ordinal = "first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth".split(separator: " ")
    private static let nouns: Set<Substring> = ["desktop", "space"]

    static func withoutCourtesy(_ original: String) -> String {
        var command = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:"))
        let courtesies = ["would you mind", "could you", "would you", "can you", "will you",
                          "hey jarvis", "hey jev", "jarvis", "jev", "please", "just"]
        while let prefix = courtesies.first(where: {
            command.lowercased().hasPrefix($0) && command.dropFirst($0.count).first.map {
                $0.isWhitespace || $0 == "," || $0 == ":"
            } == true
        }) {
            let rest = String(command.dropFirst(prefix.count)).trimmingCharacters(in: separators)
            guard !rest.isEmpty else { break }
            command = rest
        }
        return command
    }

    static func parse(_ final: String) -> Self {
        guard final.utf8.count <= 4000 else { return .other }
        var raw = withoutCourtesy(final).lowercased()
        guard !raw.isEmpty else { return .other }
        let polite = final.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let modalRequest = ["can you ", "could you ", "would you ", "will you "].contains(where: polite.hasPrefix)
        if modalRequest && raw.last == "?" { raw.removeLast() }
        if raw.last == "." || raw.last == "!" { raw.removeLast() }
        var words = raw.split(whereSeparator: \.isWhitespace)[...]
        let navigation: Bool
        if words.starts(with: ["take", "me", "to"]) || words.starts(with: ["switch", "over", "to"]) {
            words = words.dropFirst(3)
            navigation = true
        } else if words.starts(with: ["switch", "to"]) || words.starts(with: ["go", "to"]) {
            words = words.dropFirst(2)
            navigation = true
        } else {
            navigation = false
        }
        if navigation, words.first == "my" || words.first == "the" { words = words.dropFirst() }
        if words.count == 2, let first = words.first, let last = words.last {
            if nouns.contains(last) {
                if first == "next" { return .space(.next) }
                if first == "previous" { return .space(.previous) }
                if navigation, let i = ordinal.firstIndex(of: first) { return .space(.numbered(i + 1)) }
            }
            if navigation, nouns.contains(first) {
                if let i = cardinal.firstIndex(of: last) { return .space(.numbered(i + 1)) }
                if let i = Int(last), (1...16).contains(i), String(i) == last { return .space(.numbered(i)) }
            }
        }

        let tokens = raw.split { !$0.isLetter && !$0.isNumber }
        let nounAndIndex = zip(tokens, tokens.dropFirst()).contains { a, b in
            func indexLike(_ word: Substring) -> Bool {
                word.first?.isNumber == true || cardinal.contains(word) || ordinal.contains(word)
                    || ["next", "previous", "other", "last"].contains(word)
            }
            return (nouns.contains(a) && indexLike(b)) || (nouns.contains(b) && indexLike(a))
        }
        let status = tokens.first.map { ["am", "is", "are", "was", "were", "did", "should", "might"].contains($0) } == true
        let hasQuote = raw.indices.contains { index in
            let c = raw[index]
            if "\"“”«»`‘".contains(c) { return true }
            guard c == "'" || c == "’" else { return false }
            let next = raw.index(after: index)
            return index == raw.startIndex || next == raw.endIndex
                || !raw[raw.index(before: index)].isLetter || !raw[next].isLetter
        }
        let quotedClause = raw.first.map { "\"'“”‘’«»`".contains($0) } == true
        let inquiry = status || tokens.first.map { ["what", "which", "when", "where", "why", "how"].contains($0) } == true
        let contextual = tokens.first.map { ["if", "unless", "not", "never", "without", "don't", "don", "do"].contains($0) } == true
            || tokens.contains("said") || tokens.contains("whether")
        if nounAndIndex && (navigation || inquiry || quotedClause || contextual || tokens.count <= 3) { return .nonAction }
        if (status || tokens.first == "which") && tokens.contains("desktop") { return .nonAction }
        if navigation, words.count <= 2, !nouns.isDisjoint(with: words), !words.contains("folder") { return .nonAction }
        let imperative: Set<Substring> = ["stop", "cancel", "pause", "open", "launch", "start", "show",
                                          "focus", "switch", "go", "bring", "foreground", "pull", "raise"]
        let mentionsAction = !imperative.isDisjoint(with: tokens)
        if mentionsAction && quotedClause { return .nonAction }
        if mentionsAction && (status || tokens.starts(with: ["tell", "me", "whether"])
            || tokens.starts(with: ["check", "whether"])) { return .nonAction }
        if mentionsAction, raw.contains("?"), tokens.first.map(imperative.contains) == true {
            return .nonAction
        }

        switch tokens.joined(separator: " ") {
        case "stop", "stop scrolling", "stop please", "stop now", "no stop", "ok stop", "okay stop",
             "cancel", "cancel that", "never mind", "nevermind", "that s enough":
            return hasQuote || raw.contains("?") ? .nonAction : .stop
        case "pause listening", "stop listening", "pause jev", "pause jarvis":
            return hasQuote || raw.contains("?") ? .nonAction : .pause
        default: return .other
        }
    }
}
