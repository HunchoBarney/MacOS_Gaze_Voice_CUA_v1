import Foundation

public enum ClauseSplitter {
    static let commandVerbs: Set<String> = [
        "open", "launch", "close", "quit", "go", "type", "write", "search",
        "google", "set", "turn", "mute", "unmute", "lock", "sleep", "take",
        "switch", "show", "hide", "play", "pause", "next", "previous",
        "minimize", "minimise", "shrink", "focus", "activate", "bring", "run",
        "start", "exit", "kill", "terminate", "shut",
    ]

    public static func split(_ transcript: String) -> [String] {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if SlotExtractor.literalDictationSuffix(from: transcript) != nil {
            return [trimmedTranscript]
        }
        let pattern = #"\b(and then|and also|then|and)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return [trimmedTranscript]
        }
        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        let matches = regex.matches(in: transcript, range: fullRange)
        let quotes = quotedRanges(in: transcript)

        var parts: [String] = []
        var last = transcript.startIndex
        for match in matches {
            guard let range = Range(match.range, in: transcript),
                  !quotes.contains(where: { $0.contains(range.lowerBound) }) else { continue }
            var resume = range.upperBound
            while resume < transcript.endIndex, !transcript[resume].isLetter {
                resume = transcript.index(after: resume)
            }
            guard resume < transcript.endIndex,
                  !quotes.contains(where: { $0.contains(resume) }) else { continue }
            let suffix = String(transcript[resume...])
            let startsDictation = SlotExtractor.literalDictationSuffix(from: suffix) != nil
            let nextWord = suffix.prefix { $0.isLetter || $0.isNumber }.lowercased()
            guard startsDictation || commandVerbs.contains(nextWord) else { continue }

            let piece = transcript[last..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { parts.append(piece) }
            last = resume
            // Dictation owns everything after its prefix, even after a closing quote.
            // A later command must arrive in a separate utterance.
            if startsDictation { break }
        }
        let tail = transcript[last...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [trimmedTranscript] : parts
    }

    private static func quotedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var opening: String.Index?
        var closingQuote: Character?
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            let previous = index > text.startIndex ? text[text.index(before: index)] : nil
            let nextIndex = text.index(after: index)
            let next = nextIndex < text.endIndex ? text[nextIndex] : nil
            let followsWord = previous.map { $0.isLetter || $0.isNumber } ?? false
            let precedesWord = next.map { $0.isLetter || $0.isNumber } ?? false
            if (character == "'" || character == "’"), followsWord && precedesWord {
                continue // Apostrophes in contractions are not quotation marks.
            }

            if let start = opening {
                if character == closingQuote {
                    ranges.append(start..<nextIndex)
                    opening = nil
                    closingQuote = nil
                }
            } else {
                switch character {
                case "\"": closingQuote = "\""
                case "“": closingQuote = "”"
                case "‘": closingQuote = "’"
                case "'" where !followsWord: closingQuote = "'"
                default: continue
                }
                opening = index
            }
        }
        if let start = opening { ranges.append(start..<text.endIndex) }
        return ranges
    }
}
