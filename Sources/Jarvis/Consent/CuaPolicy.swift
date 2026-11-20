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
///   3. **The deny-list scan** runs twice, once per shape: the phrase
///      corpus over element label/value + url-ish args, then the
///      command-shaped corpus (`deniedInTypedPayload`) over every string
///      arg — `type_text`'s payload included. Both refuse before the
///      grant, so a standing "always allow" never rubber-stamps
///      "empty trash" or a typed `rm -rf`.
///   4. **Everything else needs the standing grant, a scoped
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

    /// Phrase-level denies: a model can always pick a *labelled* element
    /// whose action is consequential (the tool is just "click"), so the
    /// deny list lives in the visible vocabulary — the thing the user can
    /// verify on the card. Matching is normalized-substring, so the bare
    /// entries deliberately catch their inflections: "delete" also
    /// refuses "Delete Draft"/"deleted", "send" catches "resend", and an
    /// "Allow" button on a consent dialog denies like every other
    /// privilege prompt — consequential effects require the user's hands.
    /// More-specific phrases sit above the bare words so the reported
    /// hit names the fuller intent ("send payment" over "send").
    ///
    /// This list is the canonical copy — `DwellPolicy.deniedTokens`
    /// (Gaze/DwellClick.swift) mirrors a broader word-level variant for
    /// the always-on dwell lane. Keep them in sync when the protected
    /// vocabulary changes.
    static let deniedPatterns: [String] = [
        "empty trash", "move to trash", "erase all content", "erase disk",
        "erase this mac", "delete permanently", "permanently delete",
        "format disk", "factory reset", "reset all settings",
        "transfer money", "wire transfer", "send payment",
        "purchase now", "buy now", "place order", "place your order",
        "confirm purchase", "pay now", "reply all", "delete account",
        "close account", "remove device", "allow remote access",
        "share my screen", "sign out", "log out", "turn off filevault",
        "disable sip", "enter recovery", "checkout", "submit",
        "delete", "send", "reply", "allow", "erase", "format", "reset",
        "rm -rf", "mkfs", ":(){",
    ]

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
                       scopedGrant: Bool = false) -> Decision {
        if observationTools.contains(tool) { return .allow }
        if deniedTools.contains(tool) {
            return .deny("'\(tool)' changes driver or session state — it is never dispatched through the policy path")
        }
        // Deny-list before the grant: consent answers "may the model
        // act", the deny list answers "may anyone do this".
        var corpus = elementText?.lowercased() ?? ""
        for key in ["url", "urls", "button"] {
            if case .string(let v)? = args[key] { corpus += " \(v.lowercased())" }
        }
        if let hit = deniedPhrase(in: corpus) {
            return .deny("Refused: '\(hit)' is on the protected list — it requires the user's hands, not ours")
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
        if standingGrant || scopedGrant { return .allow }
        let target = elementText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .needsConfirm(OutcomeWording.consentQuestion(tool: tool, target: target))
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
