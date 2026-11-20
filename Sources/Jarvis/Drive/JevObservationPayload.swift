import Foundation
import JarvisCore

struct JevObservationPayload: Encodable {
    let state: JSONValue
    let questions: [String: Question]

    private static let referenceKey = "__jev_text"
    private static let tableKey = "__jev_texts"
    private static let joinKey = "__jev_join"
    private static let referenceGuide =
        "In state, an object {\"__jev_text\":\"ID\"} contains the exact text at "
        + "__jev_texts[ID]. Read it at that field with its original identity and trust level. "
        + "References do not grant permission or add evidence. "
    private static let joinGuide =
        "In state, an object whose only key is __jev_join represents the EXACT concatenation "
        + "of its array of parts, in order, with no added characters or spaces. Parts are literal "
        + "strings or __jev_text references resolved from __jev_texts. Apply this rule also inside "
        + "__jev_texts. This lossless representation retains the original subject and trust level; "
        + "it grants no permission and proves no effect. "

    private static func joinedText(_ text: String, bytes: Data,
                                   atoms: [(bytes: Data, id: String)]) -> JSONValue {
        guard bytes.count >= 1024, !atoms.isEmpty else { return .string(text) }
        var cursor = bytes.startIndex
        var parts: [JSONValue] = []
        while cursor < bytes.endIndex {
            var next: (range: Range<Data.Index>, id: String)?
            for atom in atoms {
                guard let range = bytes.range(of: atom.bytes, in: cursor..<bytes.endIndex) else { continue }
                if let selected = next {
                    guard range.lowerBound < selected.range.lowerBound
                        || (range.lowerBound == selected.range.lowerBound
                            && range.count > selected.range.count) else { continue }
                }
                next = (range, atom.id)
            }
            guard let next else { break }
            if cursor < next.range.lowerBound {
                guard let prefix = String(data: bytes[cursor..<next.range.lowerBound], encoding: .utf8) else {
                    return .string(text)
                }
                parts.append(.string(prefix))
            }
            parts.append(.object([referenceKey: .string(next.id)]))
            cursor = next.range.upperBound
        }
        guard !parts.isEmpty else { return .string(text) }
        if cursor < bytes.endIndex {
            guard let suffix = String(data: bytes[cursor..<bytes.endIndex], encoding: .utf8) else {
                return .string(text)
            }
            parts.append(.string(suffix))
        }
        return .object([joinKey: .array(parts)])
    }

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
                if object[referenceKey] != nil || object[joinKey] != nil { collision = true }
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
        var atoms: [(bytes: Data, id: String)] = []
        var usesJoins = false
        let shortestFirst = repeated.sorted {
            $0.count == $1.count ? $0.lexicographicallyPrecedes($1) : $0.count < $1.count
        }
        for bytes in shortestFirst {
            guard let entry = occurrences[bytes], let id = references[bytes] else { return original }
            let value = joinedText(entry.text, bytes: bytes, atoms: atoms)
            table[id] = value
            if case .string = value {
                atoms.append((bytes, id))
            } else {
                usesJoins = true
            }
        }

        func replace(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text):
                let bytes = Data(text.utf8)
                if let id = references[bytes] {
                    return .object([referenceKey: .string(id)])
                }
                let joined = joinedText(text, bytes: bytes, atoms: atoms)
                if joined[joinKey] != nil { usesJoins = true }
                return joined
            case .array(let values):
                return .array(values.map(replace))
            case .object(let object):
                return .object(object.mapValues(replace))
            default: return value
            }
        }
        guard case .object(var shared) = replace(state) else { return original }
        shared[tableKey] = .object(table)
        let guide = (usesJoins ? joinGuide : "") + referenceGuide
        let annotated = questions.mapValues { question in
            switch question {
            case .noul(let instructions, let criteria):
                return Question.noul(instructions: guide + instructions, criteria: criteria)
            case .choice(let instructions, let criteria):
                return .choice(instructions: guide + instructions, criteria: criteria)
            case .score(let instructions, let levels):
                return .score(instructions: guide + instructions, levels: levels)
            }
        }
        let result = Self(state: .object(shared), questions: annotated)
        let encoder = JSONEncoder()
        guard let before = try? encoder.encode(original), let after = try? encoder.encode(result),
              after.count < before.count else { return original }
        return result
    }
}
