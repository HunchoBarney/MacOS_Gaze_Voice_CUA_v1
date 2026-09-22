import Foundation
import JevVoiceCore

// Frozen d756cf3 interpretation for opt-in matched-workload comparison only.
final class BaselineSpeechIntent {
    public typealias Evaluate = (JSONValue, [String: Question]) async throws -> [String: Answer]
    private let evaluate: Evaluate
    public init(client: JevClient) { self.evaluate = { state, questions in try await client.systemOne(state: state, questions: questions).response.answers } }
    public init(evaluate: @escaping Evaluate) { self.evaluate = evaluate }

    public func next(words: [String], final: Bool, context: JSONValue) async throws -> SpeechIntent? {
        guard !words.isEmpty else { return nil }
        guard words.count <= 128 else {
            throw DriverConnectionError.refused("Too much uncommitted speech. Release Fn and give a shorter request.")
        }
        var boundaries: [String: String?] = ["wait": "No complete first request yet; or the intended action is conditional, negated, or ambiguous."]
        for end in 1...words.count {
            boundaries[String(end)] = words.prefix(end).joined(separator: " ")
        }
        let state: JSONValue = .object(["pending_speech": .string(words.joined(separator: " ")),
            "released": .bool(final), "context": context])
        let kinds: [String: String?] = [
            "command": "A request to operate the computer or generate text, excluding text entry.",
            "textEntry": "Request to type or insert supplied literal content into an application.",
            "dictate": "Explicit request for a literal dictation mode for the rest of this hold.",
            "stop": "Cancel one existing task, with its name or current contextual reference.",
            "stopAll": "Cancel all agent tasks.",
            "correction": "Revise or retract a previous computer request. A topic change with actually is not necessarily a correction.",
            "ignore": "Filler or ordinary conversation without a computer request."
        ]
        let chosen = try await evaluate(state, [
            "boundary": .choice(instructions: "Select the shortest prefix containing the FIRST complete actionable request or complete conversational filler. Include every argument belonging to that request, such as the whole search query or dictated content. Do not detach 'open browser' from its same-request search. Speech may continue: missing arguments or a trailing condition mean wait. Later independent requests are excluded. Released speech is not automatically complete. If unclear choose wait.", criteria: boundaries),
            "kind": .choice(instructions: "Classify only the FIRST complete request in pending_speech. Content quoted or dictated for insertion stays literal, never a stop/correction to the assistant. Ignore subsequent requests when classifying this first one.", criteria: kinds)
        ])
        let id = try JevSelection.read(chosen["boundary"], allowed: Set(boundaries.keys))
        guard id != "wait", let count = Int(id) else { return nil }
        let text = try SpeechSpan.copy(words: words, start: 0, end: count)
        let kind = try JevSelection.read(chosen["kind"], allowed: Set(kinds.keys))
        guard let value = SpeechIntent.Kind(rawValue: kind) else { throw DriverConnectionError.malformed }
        return SpeechIntent(kind: value, count: count, text: text)
    }

}
