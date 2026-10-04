import Foundation
import JevVoiceCore

/// Request-phrase parsing shared by the fast lane and the agent loop:
/// explicit navigation URLs, named-engine search URLs, and negated keyboard
/// requests. Action candidate construction lives with the loop itself.
enum CuaActionCatalog {
    static func explicitBrowserNavigationURL(in goal: String) -> String? {
        if let quoted = quotedSpan(in: goal),
           onlyTrailingPunctuation(goal[goal.index(after: quoted.range.upperBound)...]),
           let url = explicitHTTPURL(in: goal), hasExplicitNavigationVerb(in: goal) {
            return url
        }
        // Spoken form has no quotes: "go to apple.com", "navigate to
        // example.org/docs". The address is the trailing token after the
        // request's last navigation verb.
        return trailingNavigationURL(in: goal)
    }

    /// A DOM-navigable results URL for a request that names its engine
    /// ("search google for the weather", "bing for flights"). Only a bound
    /// payload becomes the query — an unnamed search stays on the omnibox,
    /// which uses the user's own default engine rather than hardcoding one.
    static func searchNavigationURL(in goal: String, payload: String?) -> String? {
        guard let payload, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let encoded = payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let g = goal.lowercased()
        if g.contains("google") { return "https://www.google.com/search?q=\(encoded)" }
        if g.contains("duckduckgo") { return "https://duckduckgo.com/?q=\(encoded)" }
        if g.contains("bing") { return "https://www.bing.com/search?q=\(encoded)" }
        return nil
    }

    static func isExplicitlyNegatedKeyboardRequest(in goal: String) -> Bool {
        explicitKeyboardClause(in: goal)?.negated == true
    }

    private static func explicitKeyboardClause(in goal: String) -> (text: String, negated: Bool)? {
        guard let quoted = quotedSpan(in: goal),
              let command = goal[..<quoted.opening].range(
                of: #"(?i)\b(?:press|hit|type)\s+(?:the\s+)?(?:key|shortcut|hotkey)\s*$"#,
                options: .regularExpression
              ) else { return nil }
        let beforeCommand = goal[..<command.lowerBound]
        let clauseStart = beforeCommand.lastIndex(where: { ";.!?\n".contains($0) })
            .map { goal.index(after: $0) } ?? goal.startIndex
        return (quoted.text, containsExplicitNegation(in: goal[clauseStart..<command.lowerBound]))
    }

    private static func containsExplicitNegation(in text: Substring) -> Bool {
        text.range(of: #"(?i)\b(?:do\s+not|don't|never|avoid)\b"#, options: .regularExpression) != nil
    }

    private static func onlyTrailingPunctuation(_ text: Substring) -> Bool {
        text.allSatisfy { $0.isWhitespace || ".!?".contains($0) }
    }

    private static func explicitHTTPURL(in goal: String) -> String? {
        guard let text = quotedSpan(in: goal)?.text,
              let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return text
    }

    private static func trailingNavigationURL(in goal: String) -> String? {
        guard goal.range(of: #"(?i)\b(?:do\s+not|don't|didn't|never|avoid)\b"#, options: .regularExpression) == nil else { return nil }
        var tailStart: String.Index?
        var cursor = goal.startIndex
        while let verb = goal.range(of: #"(?i)\b(?:navigate\s+to|visit|go\s+to|open)\s+"#, options: .regularExpression, range: cursor..<goal.endIndex) {
            tailStart = verb.upperBound
            cursor = verb.upperBound
        }
        guard let tailStart else { return nil }
        let tail = goal[tailStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        // The tail must be the address alone — a trailing clause the tool
        // cannot honor ("in a new tab") or another request ("and search…")
        // means the match is ambiguous and the normal path stays.
        guard let first = tail.split(separator: " ").first,
              tail[first.endIndex...].allSatisfy({ ".!?".contains($0) || $0.isWhitespace }) else { return nil }
        let candidate = String(first).trimmingCharacters(in: CharacterSet(charactersIn: ".!,?;\"'"))
        if candidate.lowercased().hasPrefix("http://") || candidate.lowercased().hasPrefix("https://") {
            return candidate
        }
        // Bare domain (optionally with a path): "apple.com", "developer.apple.com/xcode".
        // Anything without a dot ("google", "the") stays an app or search request.
        guard candidate.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?$"#, options: .regularExpression) != nil else { return nil }
        return "https://" + candidate
    }

    private static func hasExplicitNavigationVerb(in goal: String) -> Bool {
        guard let quoted = quotedSpan(in: goal) else { return false }
        let prefix = goal[..<quoted.opening]
        guard prefix.range(of: #"(?i)\b(?:do\s+not|don't|didn't|never|avoid)\b"#, options: .regularExpression) == nil else { return false }
        return prefix.range(of: #"(?i)\b(?:navigate\s+to|visit|go\s+to|open)\s*$"#, options: .regularExpression) != nil
    }

    private static func quotedSpan(in source: String) -> (text: String, range: Range<String.Index>, opening: String.Index)? {
        var spans: [(String, Range<String.Index>, String.Index)] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let opening = source[cursor]
            let closing: Character
            switch opening {
            case "\"": closing = "\""
            case "“": closing = "”"
            default:
                cursor = source.index(after: cursor)
                continue
            }
            let start = source.index(after: cursor)
            var end = start
            while end < source.endIndex, source[end] != closing { end = source.index(after: end) }
            guard end < source.endIndex else { return nil }
            spans.append((String(source[start..<end]), start..<end, cursor))
            cursor = source.index(after: end)
        }
        guard spans.count == 1, let (text, range, opening) = spans.first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, range, opening)
    }
}
