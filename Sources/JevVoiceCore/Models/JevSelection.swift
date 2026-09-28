import Foundation

/// Decodes and bounds-checks a structured Jev choice against the options sent.
public enum JevSelection {
    public enum Failure: Error, LocalizedError {
        case invalidAnswer
        public var errorDescription: String? { "Jev returned an invalid decision. Nothing was replayed." }
    }

    public static func read(_ answer: Answer?, allowed: Set<String>) throws -> String {
        guard case let .choice(value, confidence, probabilities) = answer,
              allowed.contains(value), confidence.isFinite, (0...1).contains(confidence),
              probabilities.allSatisfy({ allowed.contains($0.key) && $0.value.isFinite && (0...1).contains($0.value) }) else {
            throw Failure.invalidAnswer
        }
        return value
    }
}
