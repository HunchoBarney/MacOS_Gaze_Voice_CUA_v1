import Foundation

/// Reconciles Apple's revisable hypothesis with completed speech phrases.
/// On-device recognition can publish a timed phrase, then restart its untimed
/// partial text at the next phrase without ending the recognition task.
public struct SpeechTranscriptAccumulator {
    private var earlier = ""
    private var current = ""
    private var confirmed: (start: TimeInterval, end: TimeInterval)?

    public init() {}

    public mutating func update(_ text: String, start: TimeInterval? = nil,
                                end: TimeInterval? = nil, final: Bool = false) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return transcript }
        let timing: (start: TimeInterval, end: TimeInterval)?
        if let start, let end, end > start { timing = (start, end) } else { timing = nil }
        let incoming = Self.key(text), assembled = Self.key(transcript)
        // Some recognizer versions return cumulative text. Reconcile that with
        // the entire assembled hypothesis instead of appending it a second time.
        if !assembled.isEmpty, incoming.hasPrefix(assembled), incoming.count > Self.key(current).count {
            earlier = ""
        } else if let confirmed,
                  timing.map({ $0.start >= confirmed.end - 0.01 }) ?? !final {
            earlier = transcript
        }
        current = text
        confirmed = timing
        return transcript
    }

    public var transcript: String {
        guard !earlier.isEmpty else { return current }
        guard !current.isEmpty else { return earlier }
        // A literal payload keeps its wording across pauses; a new phrase must
        // not inject a command separator into text that the user is dictating.
        let literal = ClauseSplitter.split(earlier).contains { SlotExtractor.literalDictationSuffix(from: $0) != nil }
        return earlier + (literal ? " " : "\n") + current
    }

    private static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
