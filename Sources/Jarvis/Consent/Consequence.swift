import Foundation

/// Consequential controls: presses that reach other people, money or
/// accounts, or can't easily be taken back. The owner's rule:
///
/// - **The person's words name the press.** "click Send", "send it",
///   "reply to Mom saying I'm on my way and send it", "delete that email":
///   Jarvis presses straight away and the button glows as it does. The
///   words cover that one control (its own label phrase or a clear
///   synonym), once, and only when they carry no "don't", "without" or
///   "instead".
/// - **Jarvis chose the press itself**: a step it picked mid-task that the
///   words didn't name, a keyboard send, a button with no name or a click
///   at a spot on screen. It asks one short question first, and only a
///   clear yes within 30 seconds presses that one control.
/// - **The never list** (`CuaPolicy.neverReason`) refuses either way:
///   wiping the Mac, remote-access tools, gift cards, wire transfers, scam
///   links and numbers from warning popups.
enum Consequence: String, CaseIterable, Sendable {
    case pay, account, send, delete, call, permission, unnamed

    private static let phrases: [(Consequence, [String])] = [
        (.pay, ["send payment", "pay now", "buy now", "purchase now", "place order", "place your order",
                "confirm purchase", "checkout", "check out", "purchase", "subscribe", "donate", "pay"]),
        (.account, ["sign out", "log out", "sign in", "log in", "change password", "remove device"]),
        (.send, ["reply all", "send", "reply", "post", "share", "forward", "submit"]),
        (.delete, ["move to trash", "delete", "remove", "erase", "format", "reset"]),
        (.call, ["facetime", "call", "start video", "join call"]),
        (.permission, ["allow", "install", "open anyway", "grant"]),
    ]

    /// The consequence of pressing a control with this label and the
    /// phrase in the label that names it, or nil. A browser ref's `href=`
    /// is where the link goes, not what it says, so it's left out.
    static func match(control label: String) -> (consequence: Consequence, phrase: String)? {
        let text = label.replacingOccurrences(of: #"(?i)\bhref=\S+"#, with: " ", options: .regularExpression)
        let words = " " + CuaPolicy.normalize(text.lowercased()) + " "
        for (consequence, list) in phrases {
            for phrase in list where words.contains(" " + CuaPolicy.normalize(phrase) + " ") {
                return (consequence, phrase)
            }
        }
        return nil
    }

    static func of(control label: String) -> Consequence? { match(control: label)?.consequence }

    /// The first consequence the text names, or nil.
    static func classify(_ text: String) -> Consequence? { match(control: text)?.consequence }

    private static let pressVerbs = ["click", "press", "tap", "hit", "choose", "select", "pick"]
    /// Everyday words that only name the control after a press verb:
    /// "check out this article", "install Zoom", "format the letter" and
    /// "remove the red-eye" don't ask for Checkout, Allow, Erase or
    /// Move to Trash.
    private static let pressVerbOnly: Set<String> = [
        "check out", "format", "remove", "reset", "erase", "allow", "install", "open anyway", "grant",
    ]
    /// Other names for the same control.
    private static let sameControl: [String: [String]] = [
        "move to trash": ["delete", "trash"], "delete": ["trash"], "facetime": ["video call"],
    ]

    /// Whether the person's words name this control. Coverage is per
    /// control: "reply to Mom" covers Reply, not Reply All, Forward or
    /// Submit. Permission buttons need the exact control after a press
    /// verb ("click Allow"). Any "don't", "without" or "instead" in the
    /// words covers nothing.
    static func covers(goal: String, control label: String) -> Bool {
        guard !hasNegation(goal), let (consequence, phrase) = match(control: label) else { return false }
        let words = " " + CuaPolicy.normalize(goal.lowercased()) + " "
        let names = ([phrase] + (sameControl[phrase] ?? [])).map { CuaPolicy.normalize($0) }
        let pressed = names.contains { name in
            pressVerbs.contains { verb in
                ["", "the ", "on "].contains { words.contains(" \(verb) \($0)\(name) ") }
            }
        }
        if pressed { return true }
        if consequence == .permission || pressVerbOnly.contains(phrase) { return false }
        if phrase == "call", words.contains(" call it ") { return false }
        return names.contains { words.contains(" \($0) ") }
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
        case .unnamed:
            let near = target.isEmpty ? "" : ", near \(name)"
            return "I'm about to press something on screen I can't name for sure\(near). Do you want me to press it? Say \u{201C}yes\u{201D}, or \u{201C}not yet\u{201D}."
        }
    }

    private static let negations = ["no", "not", "don t", "dont", "do not", "wait", "stop", "cancel",
                                    "hold on", "hang on", "later", "never", "nope", "nah",
                                    "without", "instead", "but", "except", "rather"]

    /// Any word of doubt, refusal or redirection anywhere: "yes, but not
    /// yet", "okay, wait" and "send it to Dad instead" are not a yes, and
    /// a goal with "don't send it" covers nothing.
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
        case .account, .permission, .unnamed: return []
        }
    }

    /// A clear yes for this consequence: a plain affirmation, or the
    /// action's own verb as the whole reply ("send it", "send it now"),
    /// and no negation anywhere.
    func isClearYes(_ reply: String) -> Bool {
        guard !Self.hasNegation(reply) else { return false }
        let words = CuaPolicy.normalize(reply.lowercased())
        return DriveLoop.affirmative(words)
            || verbs.contains { [$0, $0 + " now", $0 + " please"].contains(words) }
    }
}

/// One ask-first question for one press Jarvis chose itself.
struct ConsequenceConfirmation: Sendable, Equatable {
    static let lifetime: TimeInterval = 30

    let consequence: Consequence
    let question: String
    let expiresAt: Date

    init(consequence: Consequence, label: String?, now: Date = Date()) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = trimmed.isEmpty && consequence != .unnamed ? consequence.rawValue : String(trimmed.prefix(60))
        self.consequence = consequence
        self.question = consequence.question(target: target)
        self.expiresAt = now.addingTimeInterval(Self.lifetime)
    }

    /// True when the reply is a clear yes that came back in time.
    func accepts(_ reply: String?, now: Date = Date()) -> Bool {
        guard let reply, now < expiresAt else { return false }
        return consequence.isClearYes(reply)
    }
}
