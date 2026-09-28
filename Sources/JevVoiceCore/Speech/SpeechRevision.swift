import Foundation

/// Audio positions identify hypotheses independently of their changing wording.
public struct SpeechRevision: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let isFinal: Bool

    public init(start: TimeInterval, end: TimeInterval, text: String, isFinal: Bool) {
        self.start = start; self.end = end; self.text = text; self.isFinal = isFinal
    }
}

public struct RangedTranscript: Sendable {
    public private(set) var segments: [SpeechRevision] = []
    public private(set) var revision = 0
    public init() {}

    /// Final ranges cannot be rewritten. A conflicting hypothesis fails rather
    /// than silently changing speech that may already have caused an action.
    @discardableResult
    public mutating func apply(_ incoming: SpeechRevision) throws -> Bool {
        guard incoming.start.isFinite, incoming.end.isFinite,
              incoming.start >= 0, incoming.end > incoming.start else { throw Failure.invalidRange }
        let overlapping = segments.filter { $0.start < incoming.end && incoming.start < $0.end }
        if overlapping == [incoming] { return false }
        guard !overlapping.contains(where: { $0.isFinal }) else { throw Failure.finalizedRange }
        segments.removeAll { $0.start < incoming.end && incoming.start < $0.end }
        segments.append(incoming)
        segments.sort { $0.start < $1.start }
        revision += 1
        return true
    }

    public var text: String {
        // SpeechTranscriber supplies language-specific separators and paragraphs.
        segments.map(\.text).joined()
    }
    /// Conservative segment-level coverage; no invented word-level audio times.
    public func isFinal(throughWord count: Int) -> Bool {
        let source = text
        let words = source.split(whereSeparator: \.isWhitespace)
        guard count > 0, count <= words.count else { return false }
        let requiredCharacters = source.distance(from: source.startIndex, to: words[count - 1].endIndex)
        var covered = 0
        for segment in segments {
            guard segment.isFinal else { return false }
            covered += segment.text.count
            if covered >= requiredCharacters { return true }
        }
        return false
    }
    public enum Failure: Error { case invalidRange, finalizedRange }
}

/// Decision provenance. Ranges identify the audio hypotheses seen by the model;
/// word offsets identify the submitted span within that capture's transcript.
public struct SpeechProvenance: Sendable, Equatable {
    public let captureID: UUID
    public let revision: Int
    public let wordStart: Int
    public let wordEnd: Int
    public let audioRanges: [SpeechRevision]
    public init(captureID: UUID, revision: Int, wordStart: Int, wordEnd: Int, audioRanges: [SpeechRevision]) {
        self.captureID = captureID; self.revision = revision; self.wordStart = wordStart; self.wordEnd = wordEnd; self.audioRanges = audioRanges
    }
}
