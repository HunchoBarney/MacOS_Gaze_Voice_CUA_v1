import Foundation
import JevVoiceCore

/// Deterministic dispatch for unambiguous one-shot commands.
///
/// The open-source computer-use systems (browser-use `initial_actions`,
/// macos-use direct tools, cua-agent's plain tool calls) share one shape: a
/// request that IS a known primitive executes as a single tool call, and the
/// tool's post-state is the evidence. They never spend a model call choosing
/// between candidates for "open a new tab". This table is that idea scoped to
/// commands whose target shortcut is unambiguous on macOS.
///
/// Matching is deliberately strict: the normalized request must be *only* the
/// command plus an optional trailing app qualifier. Anything conversational,
/// negated, multi-step, or unknown falls through to the agent loop.
struct CuaFastAction: Equatable {

    /// How the dispatched keystroke's effect is proven. Where no readable AX
    /// delta exists the driver's delivery confirmation is reported honestly
    /// as delivery, not as an outcome claim.
    enum Effect: Equatable {
        /// The window's tab strip gains exactly N tabs (AXRadioButton children
        /// of AXTabGroup). Falls back to a window-title change when no tab
        /// strip is observable.
        case tabsDelta(Int)
        /// The selected tab/page identity changes (window title or selected
        /// tab label).
        case tabSelectionDelta
        /// The process gains exactly N top-level windows.
        case windowDelta(Int)
        /// The target element's readable value gains the typed payload.
        case typedText
        /// The pinned window leaves the on-screen set (minimize).
        case windowOffScreen
        /// Every window of the app leaves the screen (hide).
        case appOffScreen
        /// The window's bounds grow to cover a screen (enter full screen).
        case boundsToScreen
        /// The window's bounds shrink from screen-covering (exit full screen).
        case boundsFromScreen
        /// The process terminates (quit).
        case processGone
        /// Every window of the app returns to the screen (unhide).
        case appOnScreen
        /// Delivery confirmed by the driver; no AX-observable delta exists.
        case delivered
    }

    /// What the fast lane dispatches.
    enum Body: Equatable {
        /// A chorded shortcut scoped to one window.
        case hotkey(keys: [String], shortcut: String)
        /// Exact text into the window's single unambiguous editable element.
        case type(String)
        /// A verb applied to the resolved app itself, independent of which
        /// window is in front (hide Calculator, minimize Notes' window).
        case appControl(AppVerb)
    }

    /// Whole-app verbs dispatched without a model call. Their effect is
    /// verified from the live window/process state, not a keystroke receipt.
    enum AppVerb: String, Equatable {
        case hide, unhide, minimize, quit
        var effect: Effect {
            switch self {
            case .hide: return .appOffScreen
            case .unhide: return .appOnScreen
            case .minimize: return .windowOffScreen
            case .quit: return .processGone
            }
        }
    }

    let body: Body
    /// True when the chord means the same thing in every app (⌘N new window,
    /// ⌘M minimize, ⌘H hide, ⌃⌘F full screen, single-key presses). Only
    /// browser-chrome chords stay limited to `tabbableBundles`.
    let generic: Bool
    /// Human-facing shortcut label, e.g. "⌘T" — nil for text entry.
    var shortcut: String? {
        if case let .hotkey(_, shortcut) = body { return shortcut }
        return nil
    }
    /// Browser-chrome chords only work on tab/window-cognizant apps; generic
    /// window chords, app verbs and text entry are app-agnostic.
    var needsTabbableApp: Bool {
        if case .hotkey = body { return !generic }
        return false
    }
    /// The lane asks for explicit approval itself before dispatching — used
    /// for quit, whose goal text always trips the consequential-keyword gate.
    /// The approval replaces the model's per-action judgment, so these never
    /// reach the loop unapproved.
    var selfApproves: Bool {
        if case .appControl(.quit) = body { return true }
        return false
    }
    /// Present progressive description, e.g. "Opening a new tab".
    let description: String
    /// Past-tense result phrase, e.g. "Opened a new tab".
    let result: String
    let effect: Effect

    /// Bundles whose windows accept the chorded shortcuts below for tab,
    /// window and navigation work. Chrome is the primary target; Safari and
    /// Finder share the same standard chords. Other browsers keep to the
    /// agent loop rather than guess at non-standard behavior.
    static let tabbableBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.apple.Finder",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.duckduckgo.macos.browser",
        "com.chromium.Chromium"
    ]

    /// Spoken app qualifier suffixes that resolve to "whichever browser is in
    /// front / the only running browser" rather than a named app.
    private static let genericBrowserQualifiers: Set<String> = [
        "browser", "the browser", "my browser", "web browser", "the web browser"
    ]

    /// Parse a request span into a fast action plus the optional trailing app
    /// qualifier ("in chrome"). Returns nil for anything that is not exactly
    /// one known command — the agent loop is the correct fallback, not a
    /// fuzzy match.
    static func parse(_ text: String) -> (action: CuaFastAction, appQualifier: String?)? {
        let normalized = normalize(text)
        guard !normalized.isEmpty, !isNegated(normalized) else { return nil }
        // Typed payloads are case/punctuation-exact, so they parse on the raw
        // text — the normalized command would corrupt "Hello, World".
        if let typed = parseType(text) { return typed }
        var command = normalized
        var qualifier: String?
        if let split = splitAppQualifier(normalized) {
            command = split.command
            qualifier = split.qualifier
        }
        // Verb-first app control parses the post-peel command so "minimize the
        // window in notes" keeps its ⌘M+qualifier meaning; a phrase that peels
        // a qualifier AND leaves a verb-first tail is ambiguous — the loop owns it.
        if qualifier == nil, let control = parseAppControl(command) { return control }
        guard let action = table[command] else { return nil }
        return (action, qualifier)
    }

    /// Resolve an app qualifier (or its absence) to an installed app.
    /// Keystroke lanes resolve through the frontmost tabbable app or a
    /// uniquely running tabbable app; text entry with no qualifier means the
    /// app the user is looking at — the frontmost one. Ambiguity returns nil
    /// so the caller falls back to the ordinary decision path.
    static func resolveApp(qualifier: String?, action: CuaFastAction, apps: [JSONValue],
                           frontmostBundle: String?) -> (name: String, bundle: String)? {
        if let qualifier {
            let q = normalize(qualifier)
            if genericBrowserQualifiers.contains(q) {
                return implicitBrowser(apps: apps, frontmostBundle: frontmostBundle)
            }
            return namedApp(q, in: apps)
        }
        if !action.needsTabbableApp {
            // Text and generic window chords ("minimize", "press enter") aim
            // at what the user is looking at — the frontmost app. A stray
            // background app is never inferred as the target.
            guard let frontmostBundle,
                  let app = apps.first(where: { $0["bundle_id"]?.string == frontmostBundle }) else { return nil }
            return (app["name"]?.string ?? frontmostBundle, frontmostBundle)
        }
        return implicitBrowser(apps: apps, frontmostBundle: frontmostBundle)
    }

    /// Frontmost tabbable app first; otherwise a uniquely-running tabbable
    /// app. More than one running candidate is ambiguous — nil.
    private static func implicitBrowser(apps: [JSONValue], frontmostBundle: String?) -> (name: String, bundle: String)? {
        if let frontmostBundle, tabbableBundles.contains(frontmostBundle),
           let app = apps.first(where: { $0["bundle_id"]?.string == frontmostBundle }) {
            return (app["name"]?.string ?? frontmostBundle, frontmostBundle)
        }
        let running = apps.filter {
            tabbableBundles.contains($0["bundle_id"]?.string ?? "")
                && ($0["pid"]?.integer ?? 0) > 0
        }
        guard running.count == 1, let app = running.first,
              let bundle = app["bundle_id"]?.string else { return nil }
        return (app["name"]?.string ?? bundle, bundle)
    }

    private static let fillers = ["hey jarvis", "jarvis", "please", "can you", "could you",
                                  "would you", "go ahead and", "just"]

    private static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: #"[.,!?;:'"’‘“”]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        for filler in fillers {
            if s == filler { s = ""; break }
            if s.hasPrefix(filler + " ") { s.removeFirst(filler.count + 1) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// `open|launch|start|show|switch to|bring up|focus|go to <app>` —
    /// returns the matched verb plus the trailing app-name query in
    /// normalized form; resolution to a uniquely installed app is the
    /// caller's job. Anything else is nil. The whole-phrase table runs
    /// first in `parse`, so "open a new tab" is a keystroke command,
    /// never an app launch.
    static func parseOpen(_ text: String) -> (verb: String, query: String)? {
        let normalized = normalize(text)
        guard !normalized.isEmpty, !isNegated(normalized) else { return nil }
        for verb in ["open", "launch", "start", "show", "switch to", "bring up", "focus", "go to"] {
            guard normalized.hasPrefix(verb + " ") else { continue }
            let rest = normalized.dropFirst(verb.count + 1).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return (verb, rest) }
        }
        return nil
    }

    /// Verbs whose entire request is bringing the app forward — for these an
    /// unverified raise is an honest failure, never a caveated success. The
    /// launch verbs (`open`, `launch`, `start`) are satisfied by an observed
    /// running process; the foreground raise is best-effort evidence on top.
    static func openRequiresRaise(goal: String) -> Bool {
        guard let parsed = parseOpen(goal) else { return false }
        return ["show", "switch to", "bring up", "focus", "go to"].contains(parsed.verb)
    }

    /// Resolve an open-command query: a uniquely named installed app, or a
    /// generic "browser" word routed to the implicit browser.
    static func resolveOpenApp(query: String, apps: [JSONValue],
                               frontmostBundle: String?) -> (name: String, bundle: String)? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        if genericBrowserQualifiers.contains(q) {
            return implicitBrowser(apps: apps, frontmostBundle: frontmostBundle)
        }
        return namedApp(q, in: apps)
    }

    /// The named-app match shared by qualifier and open-query resolution.
    private static func namedApp(_ q: String, in apps: [JSONValue]) -> (name: String, bundle: String)? {
        let matches = apps.filter { app in
            let name = normalize(app["name"]?.string ?? "")
            let bundle = (app["bundle_id"]?.string ?? "").lowercased()
            return name == q || (!q.isEmpty && (name.contains(q) || bundle.contains(q.replacingOccurrences(of: " ", with: ""))))
        }
        guard matches.count == 1, let app = matches.first,
              let bundle = app["bundle_id"]?.string, !bundle.isEmpty else { return nil }
        return (app["name"]?.string ?? bundle, bundle)
    }

    /// `hide|unhide|minimize|quit <app>` — the verb leads and the remainder
    /// names the app ("hide calculator", "minimize the notes window"). The
    /// remainder is returned as the qualifier for `resolveApp`/`namedApp`;
    /// empty remainders fall through to the whole-phrase table so "hide the
    /// app" and "minimize the window" keep their frontmost ⌘H/⌘M meaning.
    private static func parseAppControl(_ normalized: String) -> (action: CuaFastAction, appQualifier: String?)? {
        let verbs: [(String, AppVerb)] = [("hide", .hide), ("unhide", .unhide),
                                          ("minimize", .minimize), ("minimise", .minimize),
                                          ("quit", .quit)]
        for (verb, kind) in verbs {
            guard normalized.hasPrefix(verb + " ") else { continue }
            var rest = String(normalized.dropFirst(verb.count + 1))
            if rest.hasPrefix("the ") { rest = String(rest.dropFirst(4)) }
            for suffix in ["'s windows", "'s window", " windows", " window", " app"] {
                if rest.hasSuffix(suffix) { rest = String(rest.dropLast(suffix.count)); break }
            }
            rest = rest.trimmingCharacters(in: .whitespaces)
            // "minimize window", "hide the app" and vague referents keep their
            // frontmost table meaning; only a resolvable app name may lane.
            guard !rest.isEmpty,
                  !["window", "windows", "app", "it", "this", "that", "current"].contains(rest) else { continue }
            let description: String
            let result: String
            switch kind {
            case .hide: description = "Hiding the app"; result = "Hid the app"
            case .unhide: description = "Unhiding the app"; result = "Unhid the app"
            case .minimize: description = "Minimizing the window"; result = "Minimized the window"
            case .quit: description = "Quitting the app"; result = "Quit the app"
            }
            return (CuaFastAction(body: .appControl(kind), generic: true,
                                  description: description, result: result, effect: kind.effect),
                    rest)
        }
        return nil
    }

    /// The same leading-filler strip on raw text (case-insensitive), so a
    /// payload keeps its original casing and punctuation.
    private static func stripFillers(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        for filler in fillers {
            if s.caseInsensitiveCompare(filler) == .orderedSame { return "" }
            if s.count > filler.count + 1,
               s.prefix(filler.count).caseInsensitiveCompare(filler) == .orderedSame,
               s[s.index(s.startIndex, offsetBy: filler.count)].isWhitespace {
                s = String(s.dropFirst(filler.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    /// `type [out|exactly|the word|…] <payload> [in <app>]` — the payload is
    /// the literal remainder in its original casing. A trailing app qualifier
    /// is peeled only when the rightmost trailing preposition is present; a
    /// qualifier that resolves to nothing downstream makes the whole parse
    /// nil (fall through to the literal path), so "type sign in hello" keeps
    /// its payload intact.
    /// `type [out|exactly|the word|…] <payload> [in <app>]` — the payload is
    /// the literal remainder in its original casing. A fully-quoted payload is
    /// verbatim. Otherwise a trailing app qualifier is peeled only at the
    /// rightmost trailing preposition, and any *interior* destination
    /// preposition ("type X into this document") returns nil: deciding where
    /// the text lands is the literal-insertion path's job, not a guess. A
    /// qualifier that resolves to no app also fails the whole parse, so
    /// "type sign in hello" keeps its payload intact for the agent loop.
    private static func parseType(_ text: String) -> (action: CuaFastAction, appQualifier: String?)? {
        let stripped = stripFillers(text)
        let pattern = #"^type(?:\s+(?:out|exactly|the\s+(?:word|phrase|text|string)))?\s+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let prefix = Range(match.range, in: stripped) else { return nil }
        var rest = String(stripped[prefix.upperBound...])
        var qualifier: String?
        if let quoted = fullyQuoted(rest) {
            rest = quoted
        } else {
            var words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
            let prepositions: Set<String> = ["in", "on", "inside", "with", "using", "into", "onto"]
            outer: for k in stride(from: min(6, words.count - 1), through: 2, by: -1) {
                guard prepositions.contains(normalize(words[words.count - k])) else { continue }
                let candidate = normalize(words.suffix(k - 1).joined(separator: " "))
                guard !candidate.isEmpty else { continue }
                words.removeLast(k)
                rest = words.joined(separator: " ")
                qualifier = candidate
                break outer
            }
            // A destination preposition inside the payload ("into this
            // document", "in the notes field") is a targeting decision — the
            // literal path resolves it with Jev's app/field choice.
            let destinations = prepositions.union(["at", "to", "toward", "towards", "within", "through"])
            let payloadWords = rest.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
            for (index, word) in payloadWords.enumerated() where index < payloadWords.count - 1 {
                if destinations.contains(word) { return nil }
            }
        }
        let payload = unquote(rest.trimmingCharacters(in: .whitespaces))
        guard !payload.isEmpty else { return nil }
        return (CuaFastAction(body: .type(payload), generic: true,
                              description: "Typing “\(payload.count > 40 ? String(payload.prefix(40)) + "…" : payload)”",
                              result: "Typed the text", effect: .typedText),
                qualifier)
    }

    /// Returns the inner text only when the whole string is wrapped in one
    /// pair of matching quotes; nil otherwise.
    private static func fullyQuoted(_ text: String) -> String? {
        for pair in [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("`", "`")] {
            if text.hasPrefix(pair.0), text.hasSuffix(pair.1),
               text.count > pair.0.count + pair.1.count {
                return String(text.dropFirst(pair.0.count).dropLast(pair.1.count))
            }
        }
        return nil
    }

    private static func unquote(_ text: String) -> String {
        fullyQuoted(text) ?? text
    }

    private static func isNegated(_ words: String) -> Bool {
        words.range(of: #"\b(?:do not|don't|dont|never|without|stop|avoid|no new)\b"#, options: .regularExpression) != nil
    }

    /// Peel a trailing "in/on/with/using <app>" qualifier. Only peels when the
    /// remainder is non-empty, so "tab in" never degrades to a bare command.
    private static func splitAppQualifier(_ words: String) -> (command: String, qualifier: String)? {
        guard let range = words.range(
            of: #"\s(?:in|on|inside|with|using)\s+([a-z0-9][a-z0-9 ]*)$"#,
            options: .regularExpression),
              let expression = try? NSRegularExpression(pattern: #"\s(?:in|on|inside|with|using)\s+([a-z0-9][a-z0-9 ]*)$"#),
              let match = expression.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
              let qualifierRange = Range(match.range(at: 1), in: words) else { return nil }
        let command = String(words[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let qualifier = String(words[qualifierRange]).trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !qualifier.isEmpty else { return nil }
        return (command, qualifier)
    }

    /// Whole-phrase table. Every entry must be unambiguous as a complete
    /// request — "close tab", "close window", "quit" and other destructive
    /// or focus-dependent chords stay in the agent loop where risk judgment
    /// applies, as do content mutations like save/paste/undo. `press delete`
    /// is deliberately absent: its label carries a risk keyword that must be
    /// judged, not shortcut.
    private static let table: [String: CuaFastAction] = {
        var t: [String: CuaFastAction] = [:]
        func add(_ phrases: [String], _ keys: [String], _ shortcut: String,
                 _ description: String, _ result: String, _ effect: Effect,
                 generic: Bool = false) {
            let action = CuaFastAction(body: .hotkey(keys: keys, shortcut: shortcut), generic: generic,
                                       description: description, result: result, effect: effect)
            for phrase in phrases { t[phrase] = action }
        }
        /// Single-key presses — the driver's delivery confirmation is the
        /// honest postcondition; no app-observable delta exists. Delete and
        /// other risk-keyword keys stay in the agent loop.
        func addKey(_ phrases: [String], _ key: String, _ label: String) {
            add(phrases, [key], label, "Pressing \(label)", "Pressed \(label)", .delivered, generic: true)
        }
        add(["new tab", "open a new tab", "open new tab", "make a new tab", "create a new tab",
             "open another tab", "another tab", "add a tab", "add a new tab", "open a tab",
             "make a tab", "get me a new tab", "give me a new tab"],
            ["cmd", "t"], "⌘T", "Opening a new tab", "Opened a new tab", .tabsDelta(1))
        add(["reopen closed tab", "reopen the closed tab", "reopen last closed tab",
             "reopen the last closed tab", "undo close tab", "undo closed tab",
             "reopen last tab", "reopen the last tab", "reopen my last tab"],
            ["cmd", "shift", "t"], "⌘⇧T", "Reopening the closed tab", "Reopened the closed tab", .tabsDelta(1))
        // ⌘N is the generic new-window/new-document chord — works in Finder,
        // TextEdit, Notes, Mail and every browser; the window delta is the
        // same observable evidence everywhere.
        add(["new window", "open a new window", "open new window", "make a new window",
             "create a new window", "open another window", "another window"],
            ["cmd", "n"], "⌘N", "Opening a new window", "Opened a new window", .windowDelta(1),
            generic: true)
        add(["minimize window", "minimize the window", "minimize this window",
             "minimise window", "minimise the window", "minimise this window"],
            ["cmd", "m"], "⌘M", "Minimizing the window", "Minimized the window", .windowOffScreen,
            generic: true)
        add(["hide", "hide this app", "hide the app"],
            ["cmd", "h"], "⌘H", "Hiding the app", "Hid the app", .appOffScreen,
            generic: true)
        add(["enter full screen", "enter fullscreen", "full screen", "fullscreen",
             "go full screen", "go fullscreen", "make it full screen"],
            ["ctrl", "cmd", "f"], "⌃⌘F", "Entering full screen", "Entered full screen", .boundsToScreen,
            generic: true)
        add(["exit full screen", "exit fullscreen", "leave full screen", "leave fullscreen",
             "leave full-screen", "exit full-screen"],
            ["ctrl", "cmd", "f"], "⌃⌘F", "Exiting full screen", "Exited full screen", .boundsFromScreen,
            generic: true)
        addKey(["press enter", "press return", "hit enter", "hit return",
                "press the enter key", "press the return key"], "return", "Return")
        addKey(["press escape", "press esc", "hit escape", "press the escape key"], "escape", "Escape")
        addKey(["press tab", "hit tab", "press the tab key"], "tab", "Tab")
        addKey(["press space", "press spacebar", "hit space", "press the space bar",
                "press the spacebar"], "space", "Space")
        addKey(["press up", "press the up arrow", "press up arrow", "press arrow up",
                "press the up key"], "up", "Up")
        addKey(["press down", "press the down arrow", "press down arrow", "press arrow down",
                "press the down key"], "down", "Down")
        addKey(["press left", "press the left arrow", "press left arrow", "press arrow left",
                "press the left key"], "left", "Left")
        addKey(["press right", "press the right arrow", "press right arrow", "press arrow right",
                "press the right key"], "right", "Right")
        addKey(["press home", "press the home key"], "home", "Home")
        addKey(["press end", "press the end key"], "end", "End")
        addKey(["press page up", "press pageup", "hit page up"], "pageup", "Page Up")
        addKey(["press page down", "press pagedown", "hit page down"], "pagedown", "Page Down")
        add(["next tab", "go to next tab", "go to the next tab", "switch to next tab",
             "switch to the next tab", "move to next tab", "move to the next tab",
             "tab over", "cycle tabs forward"],
            ["ctrl", "tab"], "⌃⇥", "Switching to the next tab", "Switched to the next tab", .tabSelectionDelta)
        add(["previous tab", "prev tab", "last tab", "go to previous tab", "go to the previous tab",
             "switch to previous tab", "switch to the previous tab", "go back a tab",
             "back a tab", "move to previous tab", "move to the previous tab", "cycle tabs back"],
            ["ctrl", "shift", "tab"], "⌃⇧⇥", "Switching to the previous tab", "Switched to the previous tab", .tabSelectionDelta)
        add(["go back", "go back a page", "go back one page", "navigate back", "browser back",
             "back a page", "previous page", "go to the previous page"],
            ["cmd", "["], "⌘[", "Going back a page", "Went back a page", .tabSelectionDelta)
        add(["go forward", "forward a page", "go forward a page", "navigate forward",
             "browser forward", "forward one page"],
            ["cmd", "]"], "⌘]", "Going forward a page", "Went forward a page", .tabSelectionDelta)
        add(["reload", "refresh", "reload the page", "refresh the page", "reload page",
             "refresh page", "reload this page", "refresh this page", "reload the tab",
             "refresh the tab", "reload this tab", "refresh this tab", "refresh it"],
            ["cmd", "r"], "⌘R", "Reloading the page", "Reloaded the page", .delivered)
        add(["hard reload", "hard refresh", "force reload", "force refresh",
             "hard reload the page", "hard refresh the page", "force refresh the page"],
            ["cmd", "shift", "r"], "⌘⇧R", "Hard-reloading the page", "Hard-reloaded the page", .delivered)
        add(["zoom in", "zoom in the page", "zoom the page in", "increase zoom",
             "zoom in on the page", "make the page bigger"],
            ["cmd", "="], "⌘+", "Zooming in", "Zoomed in", .delivered)
        add(["zoom out", "zoom out the page", "zoom the page out", "decrease zoom",
             "zoom out of the page", "make the page smaller"],
            ["cmd", "-"], "⌘-", "Zooming out", "Zoomed out", .delivered)
        add(["reset zoom", "reset the zoom", "actual size", "normal zoom", "reset page zoom"],
            ["cmd", "0"], "⌘0", "Resetting zoom", "Reset zoom", .delivered)
        add(["focus the address bar", "focus address bar", "go to the address bar",
             "open the address bar", "jump to the address bar", "focus the url bar",
             "focus url bar", "go to the url bar", "focus the omnibox", "focus omnibox"],
            ["cmd", "l"], "⌘L", "Focusing the address bar", "Focused the address bar", .delivered)
        return t
    }()
}
