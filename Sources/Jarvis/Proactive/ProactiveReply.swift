import Foundation

/// The person's answer to a spoken alert, recognised on the Mac. Only
/// `.other` may open a conversation.
enum ProactiveReply: Equatable, Sendable {
    case yes, no, notNow
    case other(String)

    private static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "yes please", "do it",
        "go ahead", "sure thing", "of course", "please do",
    ]
    private static let noWords: Set<String> = ["no", "nope", "no thanks", "no thank you", "nah", "don't", "dont"]
    private static let notNowWords: Set<String> = [
        "not now", "later", "not right now", "maybe later", "remind me later", "snooze",
        "not now thanks", "not now thank you", "be quiet", "quiet", "shh", "hush",
    ]

    static func classify(_ text: String) -> ProactiveReply {
        let words = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == " " ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
        let phrase = words.joined(separator: " ")
        if notNowWords.contains(phrase) { return .notNow }
        if noWords.contains(phrase) { return .no }
        if yesWords.contains(phrase) { return .yes }
        return .other(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
