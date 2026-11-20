import Foundation
import JarvisCore
import os

/// The computer-use policy. Two distinct consent classes gate mutations:
///
/// - **User-explicit**: the spoken command itself is the consent — the
///   fast lane's named verbs, a gaze "click this" on a committed
///   referent, the overlay/dwell pick lane. Those paths don't need the
///   standing grant or a confirm card, but they still run the deny-list
///   scan (`deniedPhrase(in:)`) over whatever they'd touch: the element
///   label, the URL, the menu path, the window/dialog title. A deny
///   match refuses no matter who asked.
/// - **Autonomous**: every mutation a model picks — `DriveLoop`
///   candidates and an agent's `drive_until` — flows through `decide`
///   below, which still requires the standing grant or a per-task
///   approval.
///
/// `decide` never decides "the goal is destructive" — a goal can name a
/// benign effect (a goal about trash IS the user's goal). It decides in
/// a fixed order:
///   1. **Observation tools are always allowed** (they're the evidence;
///      gating them would blind the loop and let a model claim what it
///      can't check).
///   2. **Denied tools always refuse**, no matter the grant. They write
///      driver state — allow-list, installs — which is a consent bypass
///      vector. Nothing calls them today; the table stands so the
///      contract is honest, not aspirational.
///   3. **The never list** (`neverReason`) refuses first: wipes, remote-access
///      tools, gift cards, scam links and popup phone numbers, over
///      element label/value + url-ish args. Typing into a password box
///      refuses next, then the command-shaped scan
///      (`deniedInTypedPayload`) over every string arg — `type_text`'s
///      payload included. All refuse before the grant, so a standing
///      "always allow" never rubber-stamps "empty trash" or a typed `rm -rf`.
///   4. **A consequential press asks first** (`askFirst`): Send, Delete,
///      Pay, Call, Sign out or Allow, a keyboard send, or a press with no
///      name (`consequentialPress`), unless the caller passes
///      `consequenceConfirmed`: the person's words named that control, or
///      they said yes to it.
///   5. **Everything else needs the standing grant, a scoped
///      "Always for this app" grant (`scopedGrant:`), or a per-task
///      approval.** A request that is none of the above lands here too —
///      unknown tool names fail safe.
/// Raw desktop scope is handled by the (a)/(b) split rather than a rule
/// here: spoken deictic clicks carry their own consent and are
/// deny-scanned, while no autonomous candidate addresses bare pixels —
/// so a scoped dispatch in the model loop would still need the grant.
enum CuaPolicy {

    enum Decision: Equatable {
        case allow
        case deny(String)
        case needsConfirm(String)
        /// A consequential press the person's words didn't name: ask the
        /// `Consequence` question for this one control, then decide again
        /// with `consequenceConfirmed: true`.
        case askFirst(Consequence)
    }

    /// Read-only by contract — they return state without a side effect.
    /// `describe_element` and `list_*` carry a small privacy cost (the
    /// user sees a card anyway), never a mutation.
    static let observationTools: Set<String> = [
        "list_apps", "list_windows", "get_window_state",
        "describe_element", "get_active_element",
        "health_check", "list_sessions", "get_performance_stats",
        "clipboard_read", "get_state_summary", "get_driver_info",
        "list_visual_artifacts",
    ]

    /// Session/driver-state mutations the deny-list is about, not the
    /// grant: a granted user never meant "install whatever". `click` is
    /// NOT denied — it's the loop's whole job. Denied patterns in labels
    /// are handled by the text scan below, not this table.
    static let deniedTools: Set<String> = [
        "allow_app", "deny_app", "install_extension",
        "stop_driver", "restart_driver", "set_driver_config",
        "execute_script", "run_applescript", "shell_command",
    ]

    /// The never list: what no grant, spoken command or yes unlocks.
    /// Wiping the Mac or its data, closing accounts, money moved where it
    /// can't come back, and the tools and payment shapes tech-support
    /// scams use. Matching is normalized-substring over the element label
    /// and value, the URL, the menu path and the window or dialog title.
    ///
    /// Ordinary consequential controls (Send, Delete, Pay, Sign out,
    /// Allow) are not here: the person's own words press them, and a
    /// press Jarvis chose itself asks first (`Consequence`).
    ///
    /// This list is the canonical copy. `DwellPolicy.deniedTokens`
    /// (Gaze/DwellClick.swift) carries it plus a broader word list, since
    /// a dwell click has no words behind it. Keep them in sync.
    static let deniedPatterns: [String] = [
        "empty trash", "erase all content", "erase disk", "erase this mac",
        "delete permanently", "permanently delete", "format disk", "factory reset",
        "reset all settings", "transfer money", "wire transfer", "delete account",
        "close account", "allow remote access", "share my screen", "turn off filevault",
        "disable sip", "enter recovery", "anydesk", "teamviewer", "screenconnect",
        "connectwise control", "quick assist", "logmein", "gotoassist", "ultraviewer",
        "rustdesk", "request remote control", "give control", "gift card", "bitcoin atm",
        "crypto atm", "western union", "rm -rf", "mkfs", ":(){",
    ]

    /// Why a dispatch is refused no matter who agreed, or nil: a never-list
    /// phrase, a link whose words name a different site than it opens, or
    /// a call to a number shown on a scare popup. `text` is what the
    /// control shows; `url` is where it goes, when the caller knows.
    static func neverReason(text: String, url: String? = nil) -> String? {
        let corpus = text + " " + (url ?? "")
        if let hit = deniedPhrase(in: corpus) {
            return "Refused: '\(hit)' is never done for you, even with a yes"
        }
        if let link = ScamSignals.linkMismatch(text: text, url: url) {
            return "Refused: this link says \(link.shown) but opens \(link.actual). That's a common trick, so I won't open it."
        }
        let dials = Consequence.classify(text) == .call
            || ["tel:", "facetime:", "facetime-audio:"].contains { url?.lowercased().hasPrefix($0) == true }
        if dials, let number = ScamSignals.alarmPhoneNumber(in: corpus) {
            return "Refused: \(number) is on a warning popup. Real companies don't ask you to call from a popup. I can close it instead."
        }
        return nil
    }

    /// Tools that press a control.
    static let pressTools: Set<String> = ["click", "double_click", "browser_click", "invoke_menu"]

    private static let composeWords = ["message", "reply", "compose", "chat", "comment", "post",
                                       "email", "mail", "subject", "imessage", "tweet"]

    /// The consequential press a dispatch makes, or nil: a labelled
    /// consequential control; a press with no label (`.unnamed`); or a
    /// keyboard send, which is ⌘Return anywhere and Return in a compose or
    /// reply field. A click at a spot on screen is judged by the label of
    /// what it targets like any other press: the model loop never picks
    /// bare pixels, and the no-op ladder's pixel retry re-presses an
    /// element that was already identified. `coverage` is the control name
    /// the person's words must use to cover it.
    static func consequentialPress(tool: String, args: [String: JSONValue], elementText: String?)
        -> (consequence: Consequence, label: String, coverage: String)? {
        let label = elementText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if pressTools.contains(tool) {
            if let consequence = Consequence.of(control: label) { return (consequence, label, label) }
            return label.isEmpty ? (.unnamed, label, "") : nil
        }
        guard tool == "press_key" || tool == "hotkey" else { return nil }
        let raw = [args["key"]?.string].compactMap { $0 } + (args["keys"]?.array ?? []).compactMap(\.string)
        let keys = raw.flatMap { $0.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }).map(String.init) }
        let returns: Set<String> = ["return", "enter", "kp_enter"]
        guard keys.contains(where: returns.contains) else { return nil }
        let modifiers = Set(keys).subtracting(returns)
        let command = !modifiers.isDisjoint(with: ["cmd", "command", "meta"])
        let field = " " + normalize(label.lowercased()) + " "
        guard command || (modifiers.isEmpty && composeWords.contains { field.contains(" \($0) ") }) else { return nil }
        return (.send, command ? "\u{2318}Return" : "Return", "send")
    }

    /// Typing tools never touch a password box: Jarvis doesn't type,
    /// read or remember passwords, and says so instead.
    static let typingTools: Set<String> = ["type_text", "set_value", "browser_type"]

    /// Separator-normalized text matching: "force-quit" and "force quit"
    /// are the same word. Non-alphanumeric becomes a single space.
    /// Internal so the typed-payload corpus (TypedPayloadDeny.swift)
    /// tokenizes identically.
    ///
    /// `Character` is deliberate: mapping to `Unicode.Scalar` and feeding
    /// the slices to `String.init` resolves to `init(describing:)`, which
    /// yields `["r", "m"]`-style output — every pattern self-matched but
    /// command heads and inflections ("resend") silently never did.
    static func normalize(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(cleaned)
            .split(separator: " ").map(String.init).joined(separator: " ")
    }

    /// (normalized match, display) pairs computed once per process — the
    /// per-dispatch scan normalizes only the corpus, not all ~40 patterns.
    /// Order is preserved so the first hit reports the same phrase the
    /// raw list would have scanned.
    private static let normalizedDeniedPatterns: [(match: String, display: String)] =
        deniedPatterns.compactMap { raw in
            let match = normalize(raw)
            return match.isEmpty ? nil : (match: match, display: raw)
        }

    /// The deny-scan half of `decide`, exposed for lanes that carry their
    /// own consent (user-explicit verbs: fast-lane picks, gaze commits,
    /// radial/overlay/dwell actuations). Callers compose the corpus —
    /// element label and value, URL, menu path, dialog title — and get
    /// back the matched pattern for the refusal message, or nil when the
    /// text is clean. It never reads grants and never asks: a deny hit is
    /// a refusal on every path.
    static func deniedPhrase(in text: String) -> String? {
        let normalized = normalize(text.lowercased())
        for p in normalizedDeniedPatterns where normalized.contains(p.match) {
            return p.display
        }
        return nil
    }

    /// Corpus variant: scans each entry in order, first hit wins. Lanes
    /// holding an `IntentCandidate` pass its full safety corpus —
    /// `[label, role, url, appName, windowTitle]` — so the check sees the
    /// same five fields a dwell/gaze commit does.
    static func deniedPhrase(in corpus: [String]) -> String? {
        for entry in corpus {
            if let hit = deniedPhrase(in: entry) { return hit }
        }
        return nil
    }

    /// `scopedGrant` is the narrower grant class — a persisted
    /// "(actionKind, appBundleID)" answer from `grantAlways`. It allows
    /// exactly what the standing grant would, but only when the caller
    /// resolved the dispatch's target app and matched it through
    /// `scopedGrantAllows` — a "click always in Safari" never authorizes
    /// a click in Mail. Same ordering either way: deny scans still run
    /// first, so no grant rubber-stamps a protected phrase.
    static func decide(tool: String, args: [String: JSONValue],
                       elementText: String?, standingGrant: Bool,
                       scopedGrant: Bool = false, consequenceConfirmed: Bool = false) -> Decision {
        if observationTools.contains(tool) { return .allow }
        if deniedTools.contains(tool) {
            return .deny("'\(tool)' changes driver or session state — it is never dispatched through the policy path")
        }
        // Deny-list before the grant: consent answers "may the model
        // act", the deny list answers "may anyone do this".
        let corpus = scanCorpus(args: args, elementText: elementText)
        if let why = neverReason(text: elementText ?? "", url: args["url"]?.string) ?? neverReason(text: corpus) {
            return .deny(why)
        }
        if typingTools.contains(tool), let elementText,
           DriveCandidates.isSecure(role: "", label: elementText) {
            return .deny("Refused: I never type passwords. Type it yourself; I don't read what goes in that box.")
        }
        // Typed payloads were the audit's worst hole: `type_text` +
        // `press_key: return` ran a shell line under the standing grant
        // with no scan at all. Every string arg (`text`, `value`, a key
        // name, a `keys` chord) now runs the command-shaped deny scan —
        // a corpus of *commands*, not the label phrase list, so prose
        // about `rm -rf` stays a confirm while an actual `rm -rf` typed
        // payload refuses outright even under the grant.
        for value in args.values {
            for text in Self.argStrings(value) {
                if let hit = deniedInTypedPayload(text) {
                    return .deny("Refused: the payload runs '\(hit)' — shell-shaped input is the user's own hands, not ours")
                }
            }
        }
        if !consequenceConfirmed,
           let press = consequentialPress(tool: tool, args: args, elementText: elementText) {
            return .askFirst(press.consequence)
        }
        if standingGrant || scopedGrant { return .allow }
        let target = elementText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .needsConfirm(OutcomeWording.consentQuestion(tool: tool, target: target))
    }

    /// The text the deny scans read: the element's label and value plus
    /// the url-ish args. Typed text stays out; the typed-payload scan
    /// reads it separately.
    static func scanCorpus(args: [String: JSONValue], elementText: String?) -> String {
        var corpus = elementText?.lowercased() ?? ""
        for key in ["url", "urls", "button"] {
            if case .string(let v)? = args[key] { corpus += " \(v.lowercased())" }
        }
        return corpus
    }

    /// Every string payload an arg carries — `.string` itself, or the
    /// members of a `.array` of strings (a `hotkey` chord). The typed-
    /// payload scan reads all of them.
    private static func argStrings(_ value: JSONValue) -> [String] {
        switch value {
        case .string(let s): return [s]
        case .array(let items): return items.compactMap(\.string)
        default: return []
        }
    }

    /// The shared Jarvis directory — sibling files land next to the
    /// driver's own data.
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis", isDirectory: true)
    }

    /// Where the daemon-facing consent state lives. Agent cua children
    /// read it each call — no out-of-band sync.
    ///
    /// Honesty about what this file is: a SOFT store, user-writable and
    /// process-writable — anything running as the user (including a
    /// hostile agent child) can write `standingGrant: true` or a scoped
    /// grant row into it. It's consent-state plumbing for our own
    /// dispatches, not a security boundary; the compiled deny lists in
    /// this file are the hard floor because they never yield to it.
    static var policyFile: URL {
        policyFileOverride ?? supportDirectory.appendingPathComponent("policy.json")
    }

    /// Settable for tests — production reads the shared support dir.
    static var policyFileOverride: URL?

    /// The consent file the agent children read — written when the
    /// grant is on; when it's revoked the file is REMOVED (never left
    /// saying `true`), except that persisted scoped "Always for this
    /// app" grants keep a `standingGrant: false` file on disk. Removing
    /// before any rewrite means a failed write can never resurrect a
    /// revocation: `CuaDriveServer.standingGrant()` already reads a
    /// missing or malformed file as "no grant", so absence is the honest
    /// off-state. Write/remove failures log rather than swallow — the
    /// alternative is a settings toggle that silently did nothing.
    static func publishStateFile(standingGrant: Bool) {
        writePolicyFile(standingGrant: standingGrant,
                        scopedGrants: readPolicyState().scopedGrants)
    }

    static let log = Logger(subsystem: "com.karanvirkang.jarvis",
                            category: "CuaPolicy")
}
