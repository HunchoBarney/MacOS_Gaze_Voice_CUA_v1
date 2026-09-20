import Foundation

/// Owns only the insertion made during this hold. AX ranges use UTF-16 offsets.
/// Any external text or cursor change invalidates ownership rather than guessing.
public struct DictationDraft {
    private let prefix: String
    private let suffix: String
    private let insertion: Int
    public private(set) var text = ""
    public var document: String { prefix + text + suffix }
    public var caret: Int { insertion + text.utf16.count }

    public init(document: String, insertion: Int) throws {
        guard insertion >= 0,
              let offset = document.utf16.index(document.utf16.startIndex, offsetBy: insertion, limitedBy: document.utf16.endIndex),
              let position = String.Index(offset, within: document) else {
            throw DraftError.changedDestination
        }
        prefix = String(document[..<position])
        suffix = String(document[position...])
        self.insertion = insertion
    }

    public func replacementRange(in actual: String, caret actualCaret: Int) throws -> NSRange {
        guard actual == document, actualCaret == caret else { throw DraftError.changedDestination }
        return NSRange(location: insertion, length: text.utf16.count)
    }

    public mutating func accept(_ text: String) { self.text = text }

    public enum DraftError: LocalizedError {
        case changedDestination
        public var errorDescription: String? { "The text or cursor changed. Live dictation stopped; text already inserted is kept." }
    }
}
