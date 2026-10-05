import Foundation

public enum Question: Encodable {
    case noul(instructions: String)
    case choice(instructions: String, criteria: [String: String?])
    case score(instructions: String, levels: [String])

    enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noul(let instructions):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        case .choice(let instructions, let criteria):
            try container.encode("choice", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(criteria, forKey: .criteria)
        case .score(let instructions, let levels):
            try container.encode("score", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(levels, forKey: .criteria)
        }
    }
}

public enum Answer: Decodable {
    case noul(Double)
    case choice(choice: String, confidence: Double, probabilities: [String: Double])
    /// A "choice" answer carrying no readable confidence AND no probability
    /// mass — nothing to trust. `JevSelection.read` refuses it; a real 0.0
    /// still decodes as `.choice` and abstains as low-confidence downstream.
    /// When the model renames or drops `confidence` but ships
    /// `probabilities`, the picked option's own mass stands in instead.
    case untrustedChoice(choice: String, probabilities: [String: Double])
    case score(score: Double, confidence: Double, probabilities: [String: Double], legend: [String: String])

    enum CodingKeys: String, CodingKey {
        case type, noul, choice, confidence, probabilities, legend, score
        /// Drifted key spellings observed from the model.
        case confidenceScore = "confidence_score"
        case conf, probability, probs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        // A present-but-wrong-typed field reads as absent — one malformed
        // scalar must not poison an otherwise-decodable answer.
        func firstDouble(_ keys: CodingKeys...) -> Double? {
            for key in keys {
                guard let value = try? container.decodeIfPresent(Double.self, forKey: key)
                else { continue }
                return value
            }
            return nil
        }
        func probabilityMap() -> [String: Double] {
            for key in [CodingKeys.probabilities, .probs] {
                if let map = try? container.decode([String: Double].self, forKey: key) {
                    return map
                }
            }
            return [:]
        }
        switch type {
        case "noul":
            self = .noul(try container.decode(Double.self, forKey: .noul))
        case "choice":
            let choice = try container.decode(String.self, forKey: .choice)
            let probabilities = probabilityMap()
            if let confidence = firstDouble(.confidence, .confidenceScore, .conf, .probability) {
                self = .choice(choice: choice, confidence: confidence, probabilities: probabilities)
            } else if !probabilities.isEmpty {
                // A shipped distribution is the confidence: the pick's own
                // recorded mass, zero when it carries none — never the old
                // missing-field death nor a fabricated top-lane value.
                self = .choice(choice: choice,
                               confidence: probabilities[choice] ?? 0,
                               probabilities: probabilities)
            } else {
                self = .untrustedChoice(choice: choice, probabilities: probabilities)
            }
        case "score":
            self = .score(
                score: try container.decode(Double.self, forKey: .score),
                confidence: firstDouble(.confidence, .confidenceScore, .conf, .probability) ?? 0,
                probabilities: probabilityMap(),
                legend: (try? container.decode([String: String].self, forKey: .legend)) ?? [:]
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown answer type: \(type)"
            )
        }
    }
}

public struct Usage: Decodable {
    public let inputTokens: Int
    public let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct SystemOneResponse: Decodable {
    public let model: String
    public let answers: [String: Answer]
    public let usage: Usage?
}

struct SystemOneRequest<State: Encodable>: Encodable {
    let model: String
    let state: State
    let questions: [String: Question]
}
