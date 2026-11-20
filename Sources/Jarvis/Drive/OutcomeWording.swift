import Foundation

/// The one place an internal outcome becomes words a person reads or
/// hears. Executors keep their machine reasons for logs and history; the
/// indicator, spoken replies and consent questions take their wording from
/// here, in Jarvis's casual voice.
enum OutcomeWording {
    /// Machine reasons whose executor line isn't fit to say out loud.
    private static let byReason: [String: String] = [
        "transport failure": lostTouch,
        DriveLoop.sessionRestartedReason: "I had to reconnect to your Mac's controls. Try that again.",
        DriveLoop.scrollUnverifiedReason: "I scrolled, but I couldn't check that the page moved.",
        "scroll_unverified": "I couldn't check that the scroll worked, so I stopped scrolling.",
        "target_changed": "The window changed under me, so I stopped scrolling.",
        "scroll target changed": "The window changed under me, so I stopped scrolling.",
        "pinned window closed": "That window closed, so I stopped.",
        "app identity changed": "A different app came to the front, so I stopped.",
        "low_confidence": "I'm not sure which one you mean. Say “show names”, then “click” and the name.",
        "no_candidate": "I couldn't find that on screen. Say “show names” to see what's there.",
        "no_interactive_elements": "I can't see anything to click in that window.",
        "untrusted_answer": "I'm not sure what to do next there. Can you say it another way?",
        "needs_choice": "There's more than one way to do that. Can you be more specific?",
    ]

    static let missingVoiceKey = "Jarvis needs its OpenAI key before it can hear you. Add it in Settings, under Advanced."
    static let missingUnderstandingKey = "Jarvis needs its TypeSafe key before it can understand that. Add it in Settings, under Advanced."

    private static let lostTouch = "I lost touch with your Mac's controls for a moment. Try that again."
    private static let generic = "That didn't work, sorry. Try saying it another way."

    /// What to say when a task stops short. `why` is the executor's own line,
    /// `reason` its machine reason when it has one.
    static func blocked(_ why: String, reason: String? = nil) -> String {
        let line = why.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty, byReason[line] == nil, !isInternal(line) { return line }
        if let reason, let sentence = byReason[reason] { return sentence }
        return readable(line)
    }

    static func handedBack(_ reason: DriveStatus.HandBackReason) -> String {
        byReason[reason.rawValue] ?? generic
    }

    /// The executor's line when it already reads like something a person
    /// would say; otherwise a plain sentence for the kind of failure.
    static func readable(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return generic }
        if let sentence = byReason[trimmed] { return sentence }
        let lower = trimmed.lowercased()
        if lower.contains("protected list") {
            return "That one's yours to press. I leave things like sending, replying and deleting to you."
        }
        if lower.contains("shell-shaped") {
            return "That text looks like a command, so I won't type it for you."
        }
        if lower.contains("standing grant") {
            return "I need your OK before I click or type. Say yes when I ask, or turn on “Don't ask before changing things” in Settings."
        }
        guard isInternal(trimmed) else { return trimmed }
        if ["connection", "reached", "socket", "timed out", "dropped", "closed"].contains(where: lower.contains) {
            return lostTouch
        }
        if lower.contains("refused") || lower.contains("denied") {
            return "Your Mac didn't let me do that."
        }
        return generic
    }

    /// Text that names the machinery instead of the task: driver and
    /// session words, raw error domains, code-shaped tokens.
    static func isInternal(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(driver|cua|mcp|pid|daemon|socket|json|nil|session)\b|Error Domain=|\bAX[A-Z]\w*|\b[a-z]+_[a-z_]+\b|\(code"#,
                   options: .regularExpression) != nil
    }

    /// The spoken half of a capture failure, by category. The failure
    /// text itself is never spoken: it can carry paths or account details.
    static func spokenFailure(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("editable field") || m.contains("focused for dictation") || m.contains("insert") {
            return "I couldn't type that in. Click where you want it and try again."
        }
        if m.contains("window server") { return "Your Mac didn't let me do that. Try again in a moment." }
        if m.contains("microphone") || m.contains("permission") || m.contains("access is needed") {
            return "I can't hear you, the mic's switched off for me. It's under Privacy & Security, then Microphone."
        }
        if m.contains("under advanced") {
            return "I need my key set up first. It's in Settings, under Advanced."
        }
        if m.contains("speech") || m.contains("try again") || m.contains("catch") {
            return "Sorry, I didn't catch that."
        }
        if m.contains("session") || m.contains("server") || m.contains("connect")
            || m.contains("unavailable") || m.contains("api key") || m.contains("realtime") {
            return "I can't connect right now. Give it a second and try again."
        }
        return "That didn't work, sorry."
    }

    /// The consent question for an action — the verb in words, never a
    /// tool id.
    static func consentQuestion(tool: String, target: String) -> String {
        let verbs: [String: (named: String, alone: String)] = [
            "click": ("click", "click there"), "double_click": ("double-click", "double-click there"),
            "right_click": ("right-click", "right-click there"), "type_text": ("type in", "type that"),
            "set_value": ("change", "change that"), "press_key": ("press keys in", "press those keys"),
            "hotkey": ("press keys in", "press those keys"), "scroll": ("scroll", "scroll"),
            "drag": ("drag", "drag that"), "launch_app": ("open", "open that"),
            "invoke_menu": ("use the menu in", "use that menu"), "perform_secondary_action": ("use", "do that"),
        ]
        let verb = verbs[tool] ?? ("do that in", "do that")
        let name = String(target.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        return name.isEmpty ? "Can I \(verb.alone) for you?" : "Can I \(verb.named) “\(name)”?"
    }
}
