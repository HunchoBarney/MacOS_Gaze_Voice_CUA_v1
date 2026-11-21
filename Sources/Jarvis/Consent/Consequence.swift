import Foundation

/// Consequential controls: presses that reach other people, money or
/// accounts, or can't easily be taken back. The owner's rule:
///
/// - **The person's words name the press.** "click Send", "send it",
///   "reply to Mom saying I'm on my way and send it", "delete that email":
///   Jarvis presses straight away and the button glows as it does. The
///   words cover that one control (its own label phrase or a clear
///   synonym), once, and not when a refusal attaches to its verb ("don't
///   send", "send it later"). A dictated message is not an instruction.
/// - **Jarvis chose the press itself**: a step it picked mid-task that the
///   words didn't name, a keyboard send, a button with no name or a click
///   at a spot on screen. Where the app can take it back (`UndoRegistry`:
///   Move to Trash in Finder, Delete and Archive in Mail, Send in Mail
///   inside its Undo Send delay, Delete in a document app) Jarvis presses
///   and offers undo for 10 seconds, once per task. Otherwise it asks one
///   short question first, and only a clear yes within 30 seconds presses
///   that one control. Update Now, Restart and Shut Down (`.restart`)
///   always ask: nothing takes back a restart.
/// - **The never list** (`CuaPolicy.neverReason`) refuses either way:
///   wiping the Mac, remote-access tools, gift cards, wire transfers, scam
///   links and numbers from warning popups.
enum Consequence: String, CaseIterable, Sendable {
    case pay, account, send, delete, call, permission, restart, unnamed

    private static let phrases: [(Consequence, [String])] = [
        (.pay, ["send payment", "pay now", "buy now", "purchase now", "place order", "place your order",
                "confirm purchase", "checkout", "check out", "purchase", "subscribe", "donate", "pay"]),
        (.account, ["sign out", "log out", "sign in", "log in", "change password", "remove device"]),
        (.restart, ["update now", "upgrade now", "restart now", "install and restart", "restart", "shut down"]),
        (.send, ["reply all", "send", "reply", "post", "share", "forward", "submit"]),
        (.delete, ["move to trash", "delete", "remove", "erase", "reset"]),
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
        "check out", "remove", "reset", "erase", "allow", "install", "open anyway", "grant",
    ]
    /// Other names for the same control.
    private static let sameControl: [String: [String]] = [
        "move to trash": ["delete", "trash"], "delete": ["trash"], "facetime": ["video call"],
    ]

    /// Refusals that sit just before the control's own verb in the same
    /// clause: "don't send", "without sending", "rather than deleting".
    /// The bare "t" is every n't contraction ("don't", "shouldn't",
    /// "can't"); "I'll", "let me" and "myself" mean the person will press
    /// it themselves.
    private static let refusalsBefore = ["t", "dont", "do not", "not", "never", "no", "without",
                                         "instead of", "rather than", "stop", "hold off", "skip", "avoid",
                                         "i ll", "i will", "let me"]
    /// Words that put the control's verb off or redirect it when they
    /// follow it closely: "send it later", "send it to Dad instead",
    /// "send it but not yet", "delete everything except the photos".
    private static let refusalsAfter = ["later", "not", "yet", "instead", "tomorrow", "never", "wait", "except",
                                        "myself"]
    private static let clauseBreaks: Set<String> = ["and", "then", "but", "so", "or"]
    /// "go ahead and send", "try and send": that "and" joins one request,
    /// so a refusal before it still reaches the verb.
    private static let joinedByAnd: Set<String> = ["ahead", "try", "just", "go"]
    /// A refusal right before the verb counts even inside what looks like
    /// a dictated message: "saying hi but don't send it yet".
    private static let closeRefusals: Set<String> = ["t", "dont", "not", "never", "no"]
    /// Where a dictated message starts. It runs to the last "and" or
    /// "then" after it, or to the end: "reply to Mom saying I'm not
    /// coming and send it" dictates "I'm not coming".
    private static let messageMarkers = ["that says", "which says", "saying", "says", "to say",
                                         "telling him", "telling her", "telling them",
                                         "tell him", "tell her", "tell them"]
    /// "show me how to send Linda a photo" asks to be taught, so it names
    /// no press: if Jarvis does a step after all, a consequential one asks.
    /// They count anywhere in the instructions ("can you show me how…"),
    /// not inside quoted or dictated text.
    private static let learningOpeners = ["show me how", "how do i", "how do you", "how can i",
                                          "walk me through", "teach me"]
    /// "the button that says Send" names a control, not a message.
    private static let controlNouns: Set<String> = ["button", "link", "one", "option", "icon", "box"]
    private static let irregularForms = ["send": ["sent"], "pay": ["paid"]]

    /// The person's instructions: their words without quoted text or a
    /// dictated message, which are what to write, not what to press.
    static func instructionWords(_ goal: String) -> [String] {
        let unquoted = goal.replacingOccurrences(of: "[\"\u{201C}\u{201D}\u{00AB}\u{00BB}][^\"\u{201C}\u{201D}\u{00AB}\u{00BB}]*[\"\u{201C}\u{201D}\u{00AB}\u{00BB}]",
                                                 with: " ", options: .regularExpression)
        var words = CuaPolicy.normalize(unquoted.lowercased()).split(separator: " ").map(String.init)
        for marker in messageMarkers.map({ $0.split(separator: " ").map(String.init) }) {
            guard let start = words.indices.first(where: {
                words[$0...].starts(with: marker)
                    && !controlNouns.contains(words[..<$0].last { $0 != "that" && $0 != "which" } ?? "")
            }) else { continue }
            let end = words[(start + marker.count)...].lastIndex { $0 == "and" || $0 == "then" } ?? words.endIndex
            words.removeSubrange(start..<end)
        }
        return words
    }

    /// The control name and its inflections as word runs: "send",
    /// "sending", "sent"; "move to trash", "moving to trash".
    private static func forms(of name: String) -> [[String]] {
        var words = name.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let head = words.removeFirst()
        let stem = head.hasSuffix("e") ? String(head.dropLast()) : head
        let heads = Set([head, head + "s", head + "d", stem + "ing", stem + "ed"] + (irregularForms[head] ?? []))
        return heads.map { [$0] + words }
    }

    /// Whether a refusal attaches to the control's verb at this spot.
    private static func refused(_ words: [String], at start: Int, length: Int) -> Bool {
        var from = start
        while from > 0, !clauseBreaks.contains(words[from - 1])
                || (words[from - 1] == "and" && from >= 2 && joinedByAnd.contains(words[from - 2])) {
            from -= 1
        }
        let after = words[(start + length)..<min(words.count, start + length + 4)]
            .prefix { $0 != "and" && $0 != "then" }
        let before = " " + words[from..<start].joined(separator: " ") + " "
        let following = " " + after.joined(separator: " ") + " "
        return refusalsBefore.contains { before.contains(" \($0) ") }
            || refusalsAfter.contains { following.contains(" \($0) ") }
    }

    /// Whether the person's words name this control. Coverage is per
    /// control: "reply to Mom" covers Reply, not Reply All, Forward or
    /// Submit. Permission and restart buttons need the exact control after
    /// a press verb ("click Allow", "click Restart"), and a "show me how"
    /// goal covers nothing. A refusal attached to the control's own verb
    /// ("don't send", "send it later", "without sending") covers nothing;
    /// words elsewhere, or inside a dictated message ("saying I'm not
    /// coming"), don't count against it.
    static func covers(goal: String, control label: String) -> Bool {
        guard let (consequence, phrase) = match(control: label) else { return false }
        let names = ([phrase] + (sameControl[phrase] ?? [])).map { CuaPolicy.normalize($0) }
        let spoken = CuaPolicy.normalize(goal.lowercased()).split(separator: " ").map(String.init)
        let tokens = instructionWords(goal)
        let instruction = " " + tokens.joined(separator: " ") + " "
        if learningOpeners.contains(where: { instruction.contains(" \($0) ") }) { return false }
        let refusal = names.flatMap(forms).contains { form in
            spoken.indices.contains {
                spoken[$0...].starts(with: form) && !closeRefusals.isDisjoint(with: spoken[max(0, $0 - 2)..<$0])
            } || tokens.indices.contains { tokens[$0...].starts(with: form) && refused(tokens, at: $0, length: form.count) }
        }
        if refusal { return false }
        let words = " " + tokens.joined(separator: " ") + " "
        let pressed = names.contains { name in
            pressVerbs.contains { verb in
                ["", "the ", "on "].contains { words.contains(" \(verb) \($0)\(name) ") }
            }
        }
        if pressed { return true }
        if [.permission, .restart].contains(consequence) || pressVerbOnly.contains(phrase) { return false }
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
        case .restart: return "Pressing \(name) restarts or shuts down your Mac, and anything you haven't saved could be lost. Do you want me to press it? Say \u{201C}yes\u{201D}, or \u{201C}not yet\u{201D}."
        case .unnamed:
            let near = target.isEmpty ? "" : ", near \(name)"
            return "I'm about to press something on screen I can't name for sure\(near). Do you want me to press it? Say \u{201C}yes\u{201D}, or \u{201C}not yet\u{201D}."
        }
    }

    private static let negations = ["no", "not", "don t", "dont", "do not", "wait", "stop", "cancel",
                                    "hold on", "hang on", "later", "never", "nope", "nah",
                                    "without", "instead", "but", "except", "rather"]

    /// Any word of doubt, refusal or redirection anywhere in a reply:
    /// "yes, but not yet", "okay, wait" and "send it to Dad instead" are
    /// not a yes.
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
        case .account, .permission, .restart, .unnamed: return []
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
