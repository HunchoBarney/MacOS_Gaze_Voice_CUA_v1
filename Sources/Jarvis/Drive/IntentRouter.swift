import Foundation

// MARK: - Intent Router (Lane D)

/// The layer above the intent scorer: (utterance verb × gaze referent ×
/// explicit modifiers) → which lane does the work. Deterministic for the
/// common verbs — the realtime model only chooses when no rule fires.
///
/// Lanes mirror the tools in RealtimeVoiceClient: instant = fast-lane
/// action on the scored element; answer = web_lookup/send_to_higher_model
/// with the referent as context (fastest path to knowledge — a DOM link's
/// href beats opening anything); screenAgent = computer_command visible
/// on screen (the DEFAULT for real multi-step work); backgroundAgent =
/// delegate_to_agent only when explicitly asked; meta = stop/answer a
/// parked ask.
///
/// Authority: the verdict is ADVISORY for every lane except `.meta`+`.cancel`
/// — VoiceTaskCoordinator writes the routed lane onto the task's context
/// line and the model still decides how to run it. `.cancel` is the one
/// enforced verdict: "stop"/"cancel"/"never mind" routes straight into the
/// real cancel path, because a stop request must never spawn work.
enum IntentLane: String, Sendable, Equatable {
    case instant, answer, screenAgent, backgroundAgent, meta
}

/// One routing decision — deterministic, explainable, testable.
struct RoutedIntent: Sendable, Equatable {
    var lane: IntentLane
    /// The referent the decision rode on — nil for referent-free tasks
    /// ("research flights" with no gaze target still routes fine).
    var referent: GazeReferent?
    /// Why this lane — feeds the ≤5-word provenance echo.
    var reason: String
}

struct IntentRouter: Sendable {

    /// Modifiers the user can speak to override the default lane.
    enum Modifier {
        /// "in the background", "have an agent do it", "while I work" —
        /// the ONLY way work goes headless. Never inferred.
        case background
        /// "on my screen", "visibly", "show me" — the default anyway.
        case foreground
        /// "have an agent…", "keep an eye on…" — persistent-agent phrasing.
        case agent
    }

    /// Coarse verb classes — FastLane's parser already resolves the fine
    /// taxonomy; the router only needs enough to pick a lane.
    enum Verb {
        case actuate      // click/open/press/tap — element verbs
        case scroll
        case dictate      // type/dictate text into a field
        case query        // what is / explain / summarize / tell me about
        case lookup       // latest / look up / search the web
        case work         // fill/download/install/book/multi-step
        case cancel       // stop/cancel/never mind
        case address      // talking AT a referent — "what are you doing"
        case unknown
    }

    /// Whole-utterance classification — keyword-matched, conservative: a
    /// phrase that fits no class returns `.unknown`, and modifiers only
    /// register on explicit phrasing (never inferred). The text is
    /// normalized to bare words first — ASR transcripts end in periods
    /// and commas, and "Click." must classify exactly like "click".
    static func classify(_ text: String) -> (verb: Verb, modifiers: Set<Modifier>) {
        let t = " " + normalized(text) + " "
        var modifiers: Set<Modifier> = []
        // Phrases are space-bounded on the already-padded string — "an
        // agent" must not match "human agents", "delegate" must not match
        // "delegated".
        let backgroundPhrases = ["in the background", "in background",
            "while i work", "while i do", "have an agent", "an agent",
            "get an agent", "delegate", "without interrupting", "quietly"]
        if backgroundPhrases.contains(where: { t.contains(" \($0) ") }) {
            modifiers.insert(.background); modifiers.insert(.agent)
        }
        let foregroundPhrases = ["on my screen", "on screen", "on-screen",
            "visibly", "show me", "in front", "watch it", "watch this"]
        if foregroundPhrases.contains(where: { t.contains(" \($0) ") }) {
            modifiers.insert(.foreground)
        }

        func any(_ words: [String], atStart: Bool = false) -> Bool {
            words.contains { atStart ? t.hasPrefix(" \($0) ") : t.contains(" \($0) ") }
        }
        // A leading command verb makes the whole utterance a command —
        // "click cancel" clicks the thing named Cancel; "type the word
        // stop" types it. Cancel/status words appearing later are
        // operands, not the intent, so they only fire with nothing
        // leading.
        let leadingCommand: Verb? =
            any(["type", "dictate", "enter", "write in", "fill in the field"], atStart: true) ? .dictate
            : any(["click", "press", "tap", "open", "launch", "hit", "choose",
                   "select", "dismiss", "close", "minimize", "expand"], atStart: true) ? .actuate
            : any(["scroll"], atStart: true) ? .scroll
            : any(["latest", "look up", "search the web", "news about",
                   "find out"], atStart: true) ? .lookup
            : any(["fill", "download", "install", "book", "order", "sign up",
                   "register", "check out", "purchase", "set up", "configure",
                   "organize", "clean up", "rename", "move all", "find all",
                   "reply to", "respond to", "send", "post", "schedule",
                   "remind", "draft", "compose", "research", "watch for",
                   "monitor", "keep an eye", "write"], atStart: true) ? .work
            : nil
        let verb: Verb
        if let leadingCommand {
            verb = leadingCommand
        } else if any(["what are you doing", "what is your status",
                       "are you done", "are you working",
                       "status report", "status update"])
                    || any(["report"], atStart: true) {
            // Talking AT a referent — specific phrasing only, and
            // "report"/status words can't fire mid-command ("write a
            // report" is work, not an address).
            verb = .address
        } else if any(["what", "who", "why", "how", "when", "where",
                       "explain", "summarize", "summarise", "tell me about",
                       "describe", "read this", "translate"], atStart: true) {
            // A question is never a cancel — "what's the cancel button
            // for" asks about it, it doesn't press it. Normalization
            // strips apostrophes ("what's" → "what s"), so the bare
            // interrogatives match every possessive/question form.
            verb = .query
        } else if any(["cancel", "stop", "never mind", "nevermind", "abort"]),
                  !t.contains(" dictat") {
            // "stop dictating"/"cancel dictation" are mode controls, not
            // work-stoppers — FastLane's dictation table owns them; a
            // cancel verdict here would kill every task instead of
            // ending the capture lane.
            verb = .cancel
        } else {
            verb = .unknown
        }
        return (verb, modifiers)
    }

    /// Punctuation-blind normalization — every non-alphanumeric becomes a
    /// space ("don't" → "don t", an acceptable loss for keyword routing)
    /// and runs collapse to single spaces, so padded word matching sees
    /// clean boundaries on raw ASR output.
    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }.reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// The deterministic table. Returns nil when nothing fires — the model
    /// chooses then (router never guesses past its competence).
    static func route(
        verb: Verb,
        referent: GazeReferent?,
        modifiers: Set<Modifier>
    ) -> RoutedIntent? {
        // Meta verbs short-circuit — "stop" at a chip, "cancel" anywhere.
        if verb == .cancel {
            return RoutedIntent(lane: .meta, referent: referent, reason: "stop")
        }
        if verb == .address, let ref = referent,
           ref.kind == .agentCursor || ref.kind == .chip {
            return RoutedIntent(lane: .meta, referent: referent,
                                reason: "addressing \(truncate(ref.label, to: 3))")
        }

        // Modifiers: an explicit "on my screen" beats an explicit
        // "in the background" — when they conflict, visible is the
        // honest default.
        let wantsBackground = (modifiers.contains(.background) || modifiers.contains(.agent))
            && !modifiers.contains(.foreground)

        switch verb {
        case .actuate, .scroll:
            // Element verbs need a referent; without one the model decides
            // (probably asks which thing).
            guard referent != nil else { return nil }
            return RoutedIntent(lane: .instant, referent: referent, reason: "on it")

        case .dictate:
            guard let ref = referent else { return nil }
            // A text field/area referent → insert. Anything else: the
            // model resolves where the text goes.
            let r = ref.role.lowercased()
            let textish = r.contains("text") || r.contains("field") || r.contains("area")
                || r.contains("input") || r.contains("textarea") || r.contains("search")
            guard textish else { return nil }
            return RoutedIntent(lane: .instant, referent: referent, reason: "typing")

        case .query:
            // Confident referent → answer directly, never navigate. The
            // referent's url rides so "explain this video" fetches the
            // transcript instead of opening it.
            guard let ref = referent else { return nil }
            return RoutedIntent(lane: .answer, referent: ref,
                                reason: "summarizing \(truncate(ref.label, to: 2))")

        case .lookup:
            return RoutedIntent(lane: .answer, referent: referent, reason: "looking it up")

        case .work:
            // Real multi-step work: ON SCREEN by default — the user watches
            // it happen. Only explicit background phrasing delegates.
            if wantsBackground {
                return RoutedIntent(lane: .backgroundAgent, referent: referent, reason: "in the background")
            }
            return RoutedIntent(lane: .screenAgent, referent: referent, reason: "on your screen")

        case .cancel, .address:
            return nil // handled above — unreachable after the early outs
        case .unknown:
            return nil
        }
    }

    /// A ≤5-word provenance echo — the user's half-second to catch a
    /// misread before anything runs. Fewest words that carry it.
    static func provenanceEcho(_ intent: RoutedIntent) -> String {
        switch intent.lane {
        case .instant:
            if let ref = intent.referent { return "\(intent.reason) \(truncate(ref.label, to: 2))" }
            return intent.reason
        case .answer:
            return intent.reason
        case .screenAgent:
            return "On it — on screen"
        case .backgroundAgent:
            return "On it — background"
        case .meta:
            return intent.reason
        }
    }

    private static func truncate(_ s: String, to count: Int) -> String {
        let words = s.split(separator: " ")
        guard words.count > count else { return s }
        return words.prefix(count).joined(separator: " ") + "…"
    }
}
