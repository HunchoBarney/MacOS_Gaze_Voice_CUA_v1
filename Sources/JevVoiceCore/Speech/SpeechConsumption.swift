import Foundation

/// Records speech already submitted to an executor separately from mutable hypotheses.
/// A revision to committed wording fails closed; it never becomes another command.
public struct SpeechConsumption {
    public struct Submission: Identifiable, Equatable {
        public let id: UUID
        public let text: String
    }
    private var words: [String] = []
    private var transcript = ""
    private var ranges: [Range<String.Index>] = []
    private var consumed: [String] = []
    public private(set) var submissions: [Submission] = []
    public init() {}
    public var consumedWordCount: Int { consumed.count }
    public var pending: String {
        guard consumed.count < ranges.count, let end = ranges.last?.upperBound else { return "" }
        return String(transcript[ranges[consumed.count].lowerBound..<end])
    }
    public var pendingWords: [String] { Array(words.dropFirst(consumed.count)) }

    public mutating func update(_ text: String) throws {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let next = tokens.map(String.init)
        guard next.count >= consumed.count,
              Array(next.prefix(consumed.count)).map(Self.normalized) == consumed else {
            throw Failure.committedRevision
        }
        words = next; transcript = text; ranges = tokens.map { $0.startIndex..<$0.endIndex }
    }
    public mutating func commit(wordCount: Int) throws -> Submission {
        guard wordCount > 0, wordCount <= pendingWords.count else { throw Failure.invalidBoundary }
        let selected = Array(pendingWords.prefix(wordCount))
        let span = ranges[consumed.count].lowerBound..<ranges[consumed.count + wordCount - 1].upperBound
        let submission = Submission(id: UUID(), text: String(transcript[span]))
        consumed += selected.map(Self.normalized)
        submissions.append(submission)
        return submission
    }
    private static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
    public enum Failure: Error, LocalizedError {
        case committedRevision, invalidBoundary
        public var errorDescription: String? {
            switch self {
            case .committedRevision: return "Speech revised an already submitted command. No action was repeated; release Fn and clarify your correction."
            case .invalidBoundary: return "The speech boundary was invalid. Nothing was submitted."
            }
        }
    }
}
