import Foundation

/// Decodes and bounds-checks a structured Jev choice against the options sent.
public enum JevSelection {
    public struct Distribution: Sendable {
        public var id: String
        public var confidence: Double
        public var probabilities: [String: Double]
        public var selectedProbability: Double { probabilities[id] ?? 0 }
        public var runnerUpProbability: Double {
            probabilities.filter { $0.key != id }.values.max() ?? 0
        }
    }

    public static func readDistribution(_ answer: Answer?, allowed: Set<String>,
                                        requireUniqueWinner: Bool = true) throws -> Distribution {
        let selected = try readDetailed(answer, allowed: allowed)
        guard case .choice(_, _, let probabilities) = answer,
              Set(probabilities.keys) == allowed,
              let probability = probabilities[selected.id],
              abs(probabilities.values.reduce(0, +) - 1) <= 0.001,
              probabilities.values.allSatisfy({ $0 <= probability }),
              !requireUniqueWinner || probabilities.filter({ $0.key != selected.id })
                .values.allSatisfy({ $0 < probability }) else {
            throw Failure.invalidAnswer
        }
        return Distribution(id: selected.id, confidence: selected.confidence,
                            probabilities: probabilities)
    }

    public enum Failure: Error, LocalizedError {
        case invalidAnswer
        public var errorDescription: String? { "Jev returned an invalid decision. Nothing was replayed." }
    }

    public static func read(_ answer: Answer?, allowed: Set<String>) throws -> String {
        try readDetailed(answer, allowed: allowed).id
    }

    /// Same bounds-checking as `read`, plus the model's own confidence —
    /// the value the chooser's caller gates on (low confidence means look
    /// again or hand back, never click through a guess).
    public static func readDetailed(_ answer: Answer?, allowed: Set<String>) throws
        -> (id: String, confidence: Double) {
        guard case let .choice(value, confidence, probabilities) = answer,
              allowed.contains(value), confidence.isFinite, (0...1).contains(confidence),
              probabilities.allSatisfy({ allowed.contains($0.key) && $0.value.isFinite && (0...1).contains($0.value) }) else {
            throw Failure.invalidAnswer
        }
        return (value, confidence)
    }
}
