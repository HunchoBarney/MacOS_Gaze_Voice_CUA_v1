import Foundation

/// Consequential actions: things a person must agree to out loud before
/// Jarvis does them, because they can't be taken back or they reach other
/// people, money or accounts. `CuaPolicy.deniedPatterns` splits in two:
///
/// - **Never** (`CuaPolicy.neverReason`): erasing the Mac, emptying the
///   Trash, remote-access tools, gift cards, wire transfers, closing
///   accounts, scam links and numbers from warning popups. No answer
///   unlocks them.
/// - **Ask first** (this type): sending, deleting, paying, calling,
///   signing out, granting a permission. A clear spoken yes, within 30
///   seconds, allows that one dispatch and nothing after it.
enum Consequence: String, CaseIterable, Sendable {
    case pay, account, send, delete, call, permission

    private static let phrases: [(Consequence, [String])] = [
        (.pay, ["send payment", "pay now", "buy now", "purchase now", "place order", "place your order",
                "confirm purchase", "checkout", "check out", "purchase", "subscribe", "donate", "pay"]),
        (.account, ["sign out", "log out", "sign in", "log in", "change password", "remove device"]),
        (.send, ["reply all", "send", "reply", "post", "share", "forward", "submit"]),
        (.delete, ["move to trash", "delete", "remove", "erase", "format", "reset"]),
        (.call, ["facetime", "call", "start video", "join call"]),
        (.permission, ["allow", "install", "open anyway", "grant"]),
    ]

    /// The first consequence the text names, or nil.
    static func classify(_ text: String) -> Consequence? {
        let words = " " + CuaPolicy.normalize(text.lowercased()) + " "
        for (consequence, list) in phrases {
            for phrase in list where words.contains(" " + CuaPolicy.normalize(phrase) + " ") {
                return consequence
            }
        }
        return nil
    }

    /// What Jarvis says before acting, naming the control in its own words.
    func question(target: String) -> String {
        let name = "\u{201C}\(target)\u{201D}"
        switch self {
        case .pay: return "Pressing \(name) spends money. Do you want me to press it? Say \u{201C}yes\u{201D}, or \u{201C}not yet\u{201D}."
        case .account: return "Pressing \(name) changes your account. Do you want me to press it? Say \u{201C}yes\u{201D}, or \u{201C}not yet\u{201D}."
        case .send: return "Pressing \(name) sends this to other people. Send it? Say \u{201C}yes, send it\u{201D}, or \u{201C}not yet\u{201D}."
        case .delete: return "Pressing \(name) deletes or erases something. Do you want me to press it? Say \u{201C}yes\u{201D}, or \u{201C}not yet\u{201D}."
        case .call: return "Pressing \(name) starts a call. Call now? Say \u{201C}yes, call\u{201D}, or \u{201C}not yet\u{201D}."
        case .permission: return "Pressing \(name) gives an app new access to your Mac. Do you want me to press it? Say \u{201C}yes\u{201D}, or \u{201C}not yet\u{201D}."
        }
    }

    private static let negations = ["no", "not", "don t", "dont", "do not", "wait", "stop", "cancel",
                                    "hold on", "hang on", "later", "never", "nope", "nah"]

    /// Any word of doubt or refusal anywhere in the reply: "yes, but not
    /// yet" and "okay, wait" are not a yes.
    static func hasNegation(_ reply: String) -> Bool {
        let words = " " + CuaPolicy.normalize(reply.lowercased()) + " "
        return negations.contains { words.contains(" \($0) ") }
    }

    private var verbs: [String] {
        switch self {
        case .pay: return ["pay", "buy it", "place the order"]
        case .send: return ["send it", "send", "post it", "share it"]
        case .delete: return ["delete it", "trash it", "remove it"]
        case .call: return ["call"]
        case .account, .permission: return []
        }
    }

    /// A clear yes for this consequence: a plain affirmation or the
    /// action's own verb first, and no negation anywhere.
    func isClearYes(_ reply: String) -> Bool {
        guard !Self.hasNegation(reply) else { return false }
        let words = CuaPolicy.normalize(reply.lowercased()) + " "
        return DriveLoop.affirmative(words) || verbs.contains { words.hasPrefix($0 + " ") }
    }
}

/// One ask-first question for one dispatch. It exists only when the
/// dispatch's text names a consequence and nothing on the never list.
struct ConsequenceConfirmation: Sendable, Equatable {
    static let lifetime: TimeInterval = 30

    let consequence: Consequence
    let label: String
    let question: String
    let expiresAt: Date

    init?(corpus: String, label: String?, now: Date = Date()) {
        guard CuaPolicy.neverReason(text: corpus) == nil,
              let hit = CuaPolicy.deniedPhrase(in: corpus),
              let consequence = Consequence.classify(hit) ?? Consequence.classify(corpus)
        else { return nil }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.consequence = consequence
        self.label = trimmed.isEmpty ? hit : String(trimmed.prefix(60))
        self.question = consequence.question(target: self.label)
        self.expiresAt = now.addingTimeInterval(Self.lifetime)
    }

    /// True when the reply is a clear yes that came back in time.
    func accepts(_ reply: String?, now: Date = Date()) -> Bool {
        guard let reply, now < expiresAt else { return false }
        return consequence.isClearYes(reply)
    }
}
