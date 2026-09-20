import Foundation

/// Tracks the recognized prefix already handed to execution. Recognition may revise
/// pending words, but a changed dispatched prefix is never silently replayed.
public struct IncrementalCommandCoordinator {
    public enum Kind: Equatable { case command, stop, undo, replace }
    public struct Candidate: Equatable {
        public let text: String
        public let endWord: Int
        public let kind: Kind
    }
    public enum StreamError: LocalizedError {
        case revisedCommittedSpeech
        public var errorDescription: String? {
            "Speech changed words for an action already dispatched. Release Fn and start a new command; completed actions will not be repeated."
        }
    }
    private var consumed = ""
    public init() {}
    public var hasCommitted: Bool { !consumed.isEmpty }

    public mutating func commit(_ candidate: Candidate, transcript: String) {
        consumed = Self.words(transcript).prefix(candidate.endWord).map(\.value).joined()
    }

    public func remainder(in transcript: String) throws -> String {
        let words = Self.words(transcript)
        let count = try consumedWordCount(in: transcript)
        guard words.count > count else { return "" }
        return String(transcript[words[count].range.lowerBound...])
    }

    private func consumedWordCount(in transcript: String) throws -> Int {
        guard !consumed.isEmpty else { return 0 }
        var prefix = ""
        for (index, word) in Self.words(transcript).enumerated() {
            prefix += word.value
            if prefix == consumed { return index + 1 }
            if prefix.count >= consumed.count { break }
        }
        throw StreamError.revisedCommittedSpeech
    }

    public func control(in transcript: String, installedApps: [String] = []) -> Candidate? {
        guard let rest = try? remainder(in: transcript), let consumedCount = try? consumedWordCount(in: transcript) else { return nil }
        let pieces = Self.pieces(rest, installedApps: installedApps)
        for piece in pieces {
            if SlotExtractor.literalDictationSuffix(from: piece.text) != nil { return nil }
            if let kind = Self.controlKind(piece.text) {
                return Candidate(text: piece.text, endWord: consumedCount + piece.endWord, kind: kind)
            }
        }
        return nil
    }

    public func next(in transcript: String, final: Bool, installedApps: [String]) throws -> Candidate? {
        let rest = try remainder(in: transcript)
        let consumedCount = try consumedWordCount(in: transcript)
        guard !rest.isEmpty else { return nil }
        // Never split a conditional into locally executable fragments.
        if !final && Self.hasCondition(rest) { return nil }
        let pieces = Self.pieces(rest, installedApps: installedApps)
        guard let first = pieces.first else { return nil }
        let kind = Self.controlKind(first.text) ?? .command
        if kind != .command { return Candidate(text: first.text, endWord: consumedCount + first.endWord, kind: kind) }
        if final {
            // Keep final compound navigation on the existing planner path, which
            // merges a homepage/browser opening with its search destination.
            return Candidate(text: Self.clean(rest), endWord: Self.words(transcript).count, kind: .command)
        }
        if SlotExtractor.literalDictationSuffix(from: first.text) != nil { return nil }
        let local = LocalCommandParser.parse(first.text, installedApps: installedApps, context: nil)
        // Free-form payloads require an explicit subsequent command boundary or
        // final text. Complete finite native commands may run after stabilization.
        let finite = local != nil && local?.action != .dictate
        let bounded = pieces.count > 1 && !Self.hasCondition(first.text)
        // Defer website preparation to preserve merged search navigation.
        guard SlotExtractor.namedWebsiteURL(from: first.text) == nil,
              finite || (bounded && first.text.split(separator: " ").count >= 2) else { return nil }
        return Candidate(text: first.text, endWord: consumedCount + first.endWord, kind: .command)
    }

    /// Literal text stays a single revisable insertion until release; it is never
    /// split into further commands, even when its payload contains command words.
    public func dictation(in transcript: String) throws -> Candidate? {
        let rest = Self.clean(try remainder(in: transcript))
        guard SlotExtractor.literalDictationSuffix(from: rest) != nil else { return nil }
        return Candidate(text: rest, endWord: Self.words(transcript).count, kind: .command)
    }

    public static func replacement(from text: String) -> String {
        text.replacingOccurrences(of: #"^actually\s*,?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+instead[.!?]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    public static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:(?:and|then|also|okay|ok|great|nice|alright|now)\b[\s,.;!?]*)+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func controlKind(_ text: String) -> Kind? {
        let s = clean(text).trimmingCharacters(in: CharacterSet(charactersIn: ",.;!?")).lowercased().replacingOccurrences(of: "’", with: "'")
        if s.range(of: #"^(?:please )?(?:stop|cancel)(?: that| please)?$"#, options: .regularExpression) != nil { return .stop }
        if s.range(of: #"^(?:actually[ ,]+)?(?:don't|do not|never mind|nevermind|undo that|cancel that)(?: do that)?$"#, options: .regularExpression) != nil { return .undo }
        if s.hasPrefix("actually ") && s.contains("instead") { return .replace }
        return nil
    }

    private static func hasCondition(_ text: String) -> Bool {
        text.range(of: #"\b(if|unless|until|when|tomorrow|later|don't|do not|not yet)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private struct Word { let value: String; let range: Range<String.Index> }
    private static func words(_ text: String) -> [Word] {
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return Word(value: text[range].lowercased().replacingOccurrences(of: "’", with: "'"), range: range)
        }
    }

    private static func pieces(_ text: String, installedApps: [String]) -> [(text: String, endWord: Int)] {
        // Split only before a new command, not at arbitrary punctuation in URLs or content.
        let verbs = "(?:" + SlotExtractor.literalPrefixPattern + "|" + #"(?:(?:can|could|would|will) you\s+)?(?:please\s+)?(?:open|launch|switch|focus|activate|create|make|type|write|dictate|say|search|google|scroll|go|bring|minimize|minimise|hide|close|quit|show|set|turn|stop|cancel)\b)"#
        let pattern = #"(?:\b(?:and then|and also|then|and|also)\s+|[.!?;,]\s+|\n+)(?="# + verbs + #")|\s+(?=actually\b)|\s+(?=stop(?:\s+(?:then|and)\b|[.!?]*$))"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        var result: [(String, Int)] = []
        var start = text.startIndex
        let quotes = ClauseSplitter.quotedRanges(in: text)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  !quotes.contains(where: { $0.contains(range.lowerBound) }) else { continue }
            let current = clean(String(text[start..<range.lowerBound]))
            if SlotExtractor.literalDictationSuffix(from: current) != nil { break }
            // A bare trailing stop is a control only after a complete finite
            // command. Search/content payloads can contain the same word.
            if text[range].allSatisfy({ $0.isWhitespace }),
               text[range.upperBound...].lowercased().hasPrefix("stop"),
               LocalCommandParser.parse(current, installedApps: installedApps, context: nil) == nil { continue }
            if !current.isEmpty {
                result.append((current, words(String(text[..<range.lowerBound])).count))
            }
            start = range.upperBound
        }
        let last = clean(String(text[start...]))
        if !last.isEmpty { result.append((last, words(text).count)) }
        return result
    }
}
