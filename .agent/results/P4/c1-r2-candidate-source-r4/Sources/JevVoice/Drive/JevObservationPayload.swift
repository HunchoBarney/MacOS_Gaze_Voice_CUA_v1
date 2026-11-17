import Foundation
import JevVoiceCore

struct JevObservationPayload: Encodable {
    let state: JSONValue
    let questions: [String: Question]

    private static let referenceKey = "__jev_text"
    private static let tableKey = "__jev_texts"
    private static let referenceGuide =
        "In state, an object {\"__jev_text\":\"ID\"} contains the exact text at "
        + "__jev_texts[ID]. Read it at that field with its original identity and trust level. "
        + "References do not grant permission or add evidence. "

    static func sharingRepeatedText(state: JSONValue, questions: [String: Question]) -> Self {
        let original = Self(state: state, questions: questions)
        guard case .object(let root) = state, root[tableKey] == nil else { return original }
        var occurrences: [Data: (text: String, count: Int)] = [:]
        var collision = false

        func collect(_ value: JSONValue) {
            switch value {
            case .string(let text):
                let bytes = Data(text.utf8)
                guard bytes.count >= 1024 else { return }
                if let existing = occurrences[bytes] {
                    occurrences[bytes] = (existing.text, existing.count + 1)
                } else {
                    occurrences[bytes] = (text, 1)
                }
            case .array(let values):
                values.forEach(collect)
            case .object(let object):
                if object[referenceKey] != nil { collision = true }
                object.values.forEach(collect)
            default: break
            }
        }
        collect(state)
        guard !collision else { return original }
        let repeated = occurrences.keys.filter { (occurrences[$0]?.count ?? 0) > 1 }
            .sorted { $0.lexicographicallyPrecedes($1) }
        guard !repeated.isEmpty else { return original }
        var references: [Data: String] = [:]
        var table: [String: JSONValue] = [:]
        for (index, bytes) in repeated.enumerated() {
            guard let entry = occurrences[bytes] else { return original }
            let id = "t\(index)"
            references[bytes] = id
            table[id] = .string(entry.text)
        }

        func replace(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text):
                guard let id = references[Data(text.utf8)] else { return value }
                return .object([referenceKey: .string(id)])
            case .array(let values):
                return .array(values.map(replace))
            case .object(let object):
                return .object(object.mapValues(replace))
            default: return value
            }
        }
        guard case .object(var shared) = replace(state) else { return original }
        shared[tableKey] = .object(table)
        let annotated = questions.mapValues { question in
            switch question {
            case .noul(let instructions, let criteria):
                return Question.noul(instructions: referenceGuide + instructions, criteria: criteria)
            case .choice(let instructions, let criteria):
                return .choice(instructions: referenceGuide + instructions, criteria: criteria)
            case .score(let instructions, let levels):
                return .score(instructions: referenceGuide + instructions, levels: levels)
            case .box(let instructions):
                return .box(instructions: referenceGuide + instructions)
            }
        }
        let result = Self(state: .object(shared), questions: annotated)
        let encoder = JSONEncoder()
        guard let before = try? encoder.encode(original), let after = try? encoder.encode(result),
              after.count < before.count else { return original }
        return result
    }
}
