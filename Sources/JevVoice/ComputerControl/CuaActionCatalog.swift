import Foundation
import JevVoiceCore

/// Request-phrase parsing shared by the fast lane and the agent loop:
/// explicit navigation URLs, named-engine search URLs, and negated keyboard
/// requests. Action candidate construction lives with the loop itself.
/// Also the shared element-naming helpers lane criteria text is built from.
enum CuaActionCatalog {
    /// The name a criteria line gives the judge: label or title first, then
    /// AX description/help, then a bounded value preview. Icon-only controls
    /// (a Spotify toolbar button, an unlabeled search field) often carry
    /// their real name only in the description — a criterion reading
    /// `Click AXButton ""` gives the judge nothing to match the goal
    /// against.
    static func elementName(_ element: JSONValue) -> String {
        for key in ["label", "title", "description", "help"] {
            if let text = element[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        if let value = element["value"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return String(value.prefix(60))
        }
        return "element"
    }

    /// Supplementary identification appended to a criteria line when the
    /// primary name is thin — the first AX description/help differing from
    /// the shown name, bounded so one element can't dominate the block.
    static func elementDetail(_ element: JSONValue, name: String) -> String? {
        for key in ["description", "help"] {
            if let text = element[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text != name {
                return String(text.prefix(80))
            }
        }
        return nil
    }

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
    /// Matches "<engine> for <query>" from the end of a request, allowing a
    /// leading "search" and a multi-word engine ("you tube for X").
    private static let engineQueryExpression = try? NSRegularExpression(
        pattern: #"(?i)\b(?:search\s+)?([a-z0-9]+(?:\s+[a-z0-9]+)?)\s+for\s+(.+?)(?:\s*(?:\.|\?|!))?$"#)

    static func namedEngineSearchURL(in goal: String) -> String? {
        guard goal.range(of: #"(?i)\b(?:do\s+not|don't|didn't|never|avoid)\b"#,
                         options: .regularExpression) == nil,
              let expression = Self.engineQueryExpression,
              let match = expression.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              let engineRange = Range(match.range(at: 1), in: goal),
              let queryRange = Range(match.range(at: 2), in: goal) else { return nil }
        return namedEngineSearchURL(engine: String(goal[engineRange]), query: String(goal[queryRange]))
    }

    /// The engine word is caller-resolved context — where an installed app
    /// was expected, a mapped engine produces a deterministic results URL
    /// instead ("search google for X" where "google" is no app). Anything
    /// unmapped or query-less stays an app-search request.
    static func namedEngineSearchURL(engine: String, query: String) -> String? {
        let normalized = engine.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let templates: [String: String] = [
            "google": "https://www.google.com/search?q=",
            "bing": "https://www.bing.com/search?q=",
            "youtube": "https://www.youtube.com/results?search_query=",
            "you tube": "https://www.youtube.com/results?search_query=",
            "github": "https://github.com/search?q=",
            "git hub": "https://github.com/search?q=",
            "amazon": "https://www.amazon.com/s?k=",
            "duckduckgo": "https://duckduckgo.com/?q=",
            "duck duck go": "https://duckduckgo.com/?q="
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let base = templates[normalized], !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else { return nil }
        return base + encoded
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
        var verbStart: String.Index?
        var cursor = goal.startIndex
        while let verb = goal.range(of: #"(?i)\b(?:navigate\s+to|visit|go\s+to|open)\s+"#, options: .regularExpression, range: cursor..<goal.endIndex) {
            verbStart = verb.lowerBound
            tailStart = verb.upperBound
            cursor = verb.upperBound
        }
        guard let tailStart else { return nil }
        // A compound request must not half-execute: imperative content
        // before the matched verb ("open the doors and go to X") belongs
        // to a second clause the tool cannot honor — the loop owns it.
        let lead = goal[..<(verbStart ?? tailStart)]
        if lead.range(of: #"(?i)\b(?:open|go\s+to|navigate|visit|search|click|type|press|launch|close|quit|play|find|new\s+tab)\b"#,
                      options: .regularExpression) != nil { return nil }
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
        // A dotted tail is a domain only when its last label is not a file
        // extension — "open report.pdf" means the file, never https://report.pdf.
        // The list keeps extensions whose file meaning dominates their TLD
        // meaning (.md, .mov, .zip) and leaves domain-common labels
        // (.app, .dev, .ai, .io, .sh) navigable.
        let fileExtensions: Set<String> = [
            "pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "pages", "numbers", "key",
            "txt", "rtf", "md", "csv", "epub", "jpg", "jpeg", "png", "gif", "heic", "webp",
            "svg", "mp3", "m4a", "wav", "aac", "flac", "ogg", "mp4", "mov", "m4v", "mkv",
            "avi", "webm", "zip", "tar", "gz", "dmg", "pkg", "apk", "ipa", "py", "swift",
            "rb", "js", "ts", "tsx", "jsx", "json", "xml", "yaml", "yml", "html", "css",
            "sql", "sqlite", "db", "log", "scpt", "sketch", "fig", "psd", "indd", "eps",
            "ttf", "otf", "woff", "woff2", "ics", "vcf", "eml", "ipynb", "torrent"
        ]
        if let last = candidate.split(separator: ".").last {
            guard !fileExtensions.contains(String(last).lowercased()) else { return nil }
        }
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
