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
        /// Exact text at the live insertion point — the deictic "type X
        /// here" destination, resolved by focus rather than by window.
        case deicticType(String)
        /// Pages of window-scoped scroll — direction is the driver's
        /// vocabulary ("up"/"down"/"left"/"right").
        case scroll(direction: String, pages: Int)
        /// A verb applied to the resolved app itself, independent of which
        /// window is in front (hide Calculator, minimize Notes' window).
        case appControl(AppVerb)
        /// A global system key posted to the HID tap — no app, no window.
        case mediaKey(MediaKeys.Key)
        /// A URL handed to a bound browser window or LaunchServices.
        case navigateURL(String)
        /// Element-scoped text into the app's unique search field plus a
        /// Return — "search <app> for X"; `playTopHit` is the "play X"
        /// variant, which additionally starts the top result on Spotify.
        case appSearch(query: String, playTopHit: Bool)
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
        // System media keys are global — the whole utterance must be exactly
        // the phrase, so they match before the app-qualifier split. A peeled
        // qualifier ("mute in zoom") can't scope system volume, so it drops
        // to the loop rather than pretending otherwise.
        if let media = mediaTable[normalized] { return (media, nil) }
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
        guard let action = table[command] else {
            if let lane = parseQueryLane(command, qualifier: qualifier) { return lane }
            if let scroll = parseScrollReps(command) { return (scroll, qualifier) }
            return nil
        }
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
        // Apostrophes bind to their word: "Marvin's" → "marvins" keeps the
        // title searchable ("marvin s" matches nothing), and "don't" →
        // "dont" still hits the negator head list. Contractions that keep
        // the following letter are also covered by the head list.
        s = s.replacingOccurrences(of: #"[''’‘]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[.,!?;:"“”]+"#, with: " ", options: .regularExpression)
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
        // "bring up" must precede "bring" — both share the prefix, and the
        // longer verb keeps its distinct phrasing ("bring up Notes").
        for verb in ["open", "launch", "start", "show", "switch to", "bring up",
                     "focus", "go to", "bring", "foreground", "pull up", "raise"] {
            guard normalized.hasPrefix(verb + " ") else { continue }
            var rest = normalized.dropFirst(verb.count + 1).trimmingCharacters(in: .whitespaces)
            // Foreground phrasing puts the target inside the verb frame —
            // "bring messages to the front" — so the front-words are the
            // verb's own tail, not part of the app name.
            if verb == "bring" {
                for suffix in [" to the front", " up front", " to front",
                               " forward", " front", " up"] {
                    if rest.hasSuffix(suffix) {
                        rest = String(rest.dropLast(suffix.count))
                            .trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
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
        return ["show", "switch to", "bring up", "focus", "go to",
                "bring", "foreground", "pull up", "raise"].contains(parsed.verb)
    }

    /// Resolve an open-command query: a uniquely named installed app, or a
    /// generic "browser" word routed to the implicit browser. Spoken
    /// articles and the trailing "app" word are packaging, not the name —
    /// "open the notes app" names Notes.
    static func resolveOpenApp(query: String, apps: [JSONValue],
                               frontmostBundle: String?) -> (name: String, bundle: String)? {
        var q = normalize(query)
        for prefix in ["the ", "my "] {
            if q.hasPrefix(prefix) { q = String(q.dropFirst(prefix.count)) }
        }
        for suffix in [" app", " application"] {
            if q.hasSuffix(suffix) { q = String(q.dropLast(suffix.count)) }
        }
        guard !q.isEmpty else { return nil }
        // Pronouns name what the user is looking at — "bring it to the
        // front" — which is the captured frontmost app, not a text match.
        if ["it", "this", "that", "this one", "that one"].contains(q),
           let frontmostBundle,
           let app = apps.first(where: { $0["bundle_id"]?.string == frontmostBundle }) {
            return (app["name"]?.string ?? frontmostBundle, frontmostBundle)
        }
        if genericBrowserQualifiers.contains(q) {
            return implicitBrowser(apps: apps, frontmostBundle: frontmostBundle)
        }
        return namedApp(q, in: apps)
    }

    /// The named-app match shared by qualifier and open-query resolution.
    /// Exact-name matches outrank substring hits, which outrank bundle
    /// hits — an exact "music" answers Music even when an unrelated bundle
    /// also contains the word. A trailing 's' that survived normalization
    /// is also tried as a fallback, covering flattened possessives
    /// ("spotifys windows" → "spotifys" → "spotify") without mangling
    /// non-possessive plural forms into a weaker substring tier.
    private static func namedApp(_ q: String, in apps: [JSONValue]) -> (name: String, bundle: String)? {
        guard !q.isEmpty else { return nil }
        let collapsed = q.replacingOccurrences(of: " ", with: "")
        func tier(_ app: JSONValue, query: String) -> Int? {
            let name = normalize(app["name"]?.string ?? "")
            let bundle = (app["bundle_id"]?.string ?? "").lowercased()
            if name == query { return 0 }
            if name.contains(query) { return 1 }
            if bundle.contains(collapsed) { return 2 }
            return nil
        }
        let queries: [String]
        if q.hasSuffix("s"), !q.hasSuffix("ss") {
            queries = [q, String(q.dropLast())]
        } else {
            queries = [q]
        }
        // The strongest non-empty tier decides — an ambiguous exact-name
        // set can't be resolved by a weaker substring or bundle match on
        // a different app. Primary query ranks before fallback.
        for query in queries {
            for level in 0...2 {
                let tierMatches = apps.filter { tier($0, query: query) == level }
                guard !tierMatches.isEmpty else { continue }
                guard tierMatches.count == 1, let app = tierMatches.first,
                      let bundle = app["bundle_id"]?.string, !bundle.isEmpty else { return nil }
                return (app["name"]?.string ?? bundle, bundle)
            }
        }
        return nil
    }

    /// `hide|unhide|minimize|quit <app>` — the verb leads and the remainder
    /// names the app ("hide calculator", "minimize the notes window"). The
    /// remainder is returned as the qualifier for `resolveApp`/`namedApp`;
    /// empty remainders fall through to the whole-phrase table so "hide the
    /// app" and "minimize the window" keep their frontmost ⌘H/⌘M meaning.
    private static func parseAppControl(_ normalized: String) -> (action: CuaFastAction, appQualifier: String?)? {
        let verbs: [(String, AppVerb)] = [("hide", .hide), ("unhide", .unhide),
                                          ("minimize", .minimize), ("minimise", .minimize),
                                          ("close", .quit), ("exit", .quit),
                                          ("quit", .quit)]
        for (verb, kind) in verbs {
            guard normalized.hasPrefix(verb + " ") else { continue }
            var rest = String(normalized.dropFirst(verb.count + 1))
            if rest.hasPrefix("the ") { rest = String(rest.dropFirst(4)) }
            var hadWindowSuffix = false
            // " window*" and " app" packaging only; possessive flattening
            // ("spotify's windows" → "spotifys windows") is recovered by
            // namedApp's trailing-'s' fallback so "notes window" isn't
            // mangled into a substring that can turn ambiguous.
            for suffix in [" windows", " window", " app"] {
                if rest.hasSuffix(suffix) {
                    hadWindowSuffix = suffix.contains("window")
                    rest = String(rest.dropLast(suffix.count)); break
                }
            }
            // "close Spotify's window" means ⌘W, not ⌘Q — a window-suffixed
            // close must not lane as an app quit. "exit full screen" is
            // likewise a window/fullscreen toggle, never an app quit.
            if hadWindowSuffix, verb == "close" { continue }
            if verb == "exit", ["fullscreen", "full screen", "full-screen"].contains(rest) { continue }
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

    /// Query-bearing lanes: "play X" is a media-app search plus top-hit play;
    /// "search <app> for X" splits the app words from the query. Whether the
    /// middle words name an installed app or an engine is the resolver's
    /// call, never the parser's. A qualifier peeled upstream ("search X in
    /// notes", "play X in spotify") supplies the app instead.
    private static func parseQueryLane(_ command: String, qualifier: String?)
        -> (action: CuaFastAction, appQualifier: String?)? {
        if command.hasPrefix("play ") {
            let query = command.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return nil }
            return (queryAction(query, playTopHit: true), qualifier)
        }
        if command.hasPrefix("search and play ") {
            let query = command.dropFirst(16).trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return nil }
            return (queryAction(query, playTopHit: true), qualifier)
        }
        if let qualifier {
            // "search [for] X in <app>" — the peeled qualifier is the app.
            guard let query = searchQueryTail(command) else { return nil }
            return (queryAction(query, playTopHit: false), qualifier)
        }
        // "search <app> for <query>" — the lazy middle is the app candidate;
        // app resolution downstream decides whether it's an app, an engine,
        // or nobody's lane.
        guard let expression = try? NSRegularExpression(pattern: #"^search\s+(.+?)\s+for\s+(.+)$"#),
              let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let appRange = Range(match.range(at: 1), in: command),
              let queryRange = Range(match.range(at: 2), in: command) else { return nil }
        let app = String(command[appRange]).trimmingCharacters(in: .whitespaces)
        let query = String(command[queryRange]).trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty, !query.isEmpty else { return nil }
        return (queryAction(query, playTopHit: false), app)
    }

    /// `search [for] <query>` — the query tail of a command whose app came
    /// from the qualifier split. A bare "search"/"search for" has no lane.
    private static func searchQueryTail(_ command: String) -> String? {
        guard command.hasPrefix("search ") else { return nil }
        var tail = String(command.dropFirst(7))
        if tail.hasPrefix("for ") { tail = String(tail.dropFirst(4)) }
        tail = tail.trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : tail
    }

    private static func queryAction(_ query: String, playTopHit: Bool) -> CuaFastAction {
        CuaFastAction(body: .appSearch(query: query, playTopHit: playTopHit), generic: true,
                      description: playTopHit ? "Playing “\(query)”" : "Searching for “\(query)”",
                      result: playTopHit ? "Dispatched play for “\(query)”" : "Searched for “\(query)”",
                      effect: .delivered)
    }

    /// `scroll <dir> [the page] <N> times` — a counted repetition the static
    /// phrases can't enumerate. Pages are capped; beyond ten the drive loop
    /// decides what "a lot" means in the window.
    private static func parseScrollReps(_ command: String) -> CuaFastAction? {
        guard let expression = try? NSRegularExpression(
                pattern: #"^scroll (up|down|left|right)(?: (?:the page|a little|a bit))? (\d+|two|three|four|five|six|seven|eight|nine|ten) times?$"#),
              let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let dirRange = Range(match.range(at: 1), in: command),
              let numRange = Range(match.range(at: 2), in: command) else { return nil }
        let words = ["two": 2, "three": 3, "four": 4, "five": 5,
                     "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        let token = String(command[numRange])
        guard let count = Int(token) ?? words[token], count > 0 else { return nil }
        let direction = String(command[dirRange])
        return CuaFastAction(body: .scroll(direction: direction, pages: min(count, 10)), generic: true,
                             description: "Scrolling \(direction)", result: "Scrolled \(direction)",
                             effect: .delivered)
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
        var deictic = false
        if let quoted = fullyQuoted(rest) {
            rest = quoted
        } else {
            // A deictic destination names the live insertion point, not an
            // app — strip it from the payload so "type X here" types X, not
            // "X here". It runs before the qualifier peel: "into this" is a
            // destination, never an app name. Longest suffixes win so
            // "right here" beats "here".
            if let strippedDeictic = stripDeicticSuffix(rest) {
                rest = strippedDeictic
                deictic = true
            }
            if !deictic {
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
                // "type X here in notes" — a qualifier AND a deictic suffix
                // is a contradiction the resolver arbitrates, not the parser.
                if let strippedDeictic = stripDeicticSuffix(rest) {
                    rest = strippedDeictic
                    deictic = true
                }
            }
            // A destination preposition inside the payload ("into this
            // document", "in the notes field") is a targeting decision —
            // the literal path resolves it with Jev's app/field choice. It
            // runs for deictic payloads too: "type X in notes here" must not
            // type "X in notes" verbatim.
            let destinations: Set<String> = ["in", "on", "inside", "with", "using", "into",
                                             "onto", "at", "to", "toward", "towards", "within", "through"]
            let payloadWords = rest.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
            for (index, word) in payloadWords.enumerated() where index < payloadWords.count - 1 {
                if destinations.contains(word) { return nil }
            }
        }
        let payload = unquote(rest.trimmingCharacters(in: .whitespaces))
        guard !payload.isEmpty else { return nil }
        let shown = payload.count > 40 ? String(payload.prefix(40)) + "…" : payload
        return (CuaFastAction(body: deictic ? .deicticType(payload) : .type(payload), generic: true,
                              description: "Typing “\(shown)”\(deictic ? " at the insertion point" : "")",
                              result: "Typed the text", effect: deictic ? .delivered : .typedText),
                qualifier)
    }

    /// The payload with a trailing deictic destination stripped, or nil when
    /// none is present. The suffix must follow a whitespace boundary so
    /// "sphere" never loses its tail; longest suffixes win so "right here"
    /// beats "here".
    private static func stripDeicticSuffix(_ text: String) -> String? {
        let suffixes = ["right here", "over here", "at the insertion point", "at my cursor",
                        "at the cursor", "into this field", "into the field",
                        "into this document", "in this field", "into this", "here"]
        /// Words that complete "here" as payload rather than point at a
        /// destination — "type come here" means the text, not the cursor.
        let herePartners: Set<String> = ["come", "go", "get", "meet", "stay", "wait",
                                          "live", "sit", "stand", "be", "me", "you",
                                          "us", "them", "mine", "yours"]
        let working = text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        for suffix in suffixes {
            guard working.count > suffix.count,
                  working.suffix(suffix.count).lowercased() == suffix,
                  working[working.index(working.endIndex, offsetBy: -(suffix.count + 1))].isWhitespace
            else { continue }
            let payload = String(working.dropLast(suffix.count + 1)).trimmingCharacters(in: .whitespaces)
            if suffix == "here", let last = payload.split(separator: " ").last,
               herePartners.contains(last.lowercased()) { continue }
            return payload
        }
        return nil
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
        // Negation only counts where it can negate — the command head. A
        // negator inside a query is content ("play never gonna give you up"
        // must not dead-end). `without` stays global: "quit without saving"
        // qualifies the command no matter where it sits. `normalize` maps
        // apostrophes to spaces — "don't" arrives as "don t".
        let head = ["never", "don't", "dont", "don t", "won't", "wont", "won t",
                    "do not", "no new", "stop", "avoid"]
        if head.contains(where: { words == $0 || words.hasPrefix($0 + " ") }) { return true }
        return words.range(of: #"\bwithout\b"#, options: .regularExpression) != nil
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
             "create a new window", "open another window", "another window",
             "new document", "open a new document", "create a new document",
             "new file", "open a new file", "create a new file"],
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
        /// Window-scoped scroll is the single most common pointer
        /// replacement a voice user asks for — the driver's delivery receipt
        /// is the honest effect; scroll position is not reliably AX-readable.
        func addScroll(_ phrases: [String], _ direction: String, _ label: String, pages: Int = 1) {
            let action = CuaFastAction(body: .scroll(direction: direction, pages: pages), generic: true,
                                       description: "Scrolling \(label)",
                                       result: "Scrolled \(label)", effect: .delivered)
            for phrase in phrases { t[phrase] = action }
        }
        addScroll(["scroll down", "scroll the page down", "scroll down the page",
                   "scroll down a bit", "scroll down a little"], "down", "down")
        addScroll(["scroll up", "scroll the page up", "scroll up the page",
                   "scroll up a bit", "scroll up a little"], "up", "up")
        addScroll(["scroll left", "scroll to the left"], "left", "left")
        addScroll(["scroll right", "scroll to the right"], "right", "right")
        addScroll(["scroll down a lot", "scroll way down", "scroll down a bunch",
                   "scroll down a few pages"], "down", "down", pages: 3)
        addScroll(["scroll up a lot", "scroll way up", "scroll up a bunch",
                   "scroll up a few pages"], "up", "up", pages: 3)
        // Document-new is ⌘N everywhere, but in Notes/Mail/Messages it makes
        // an item, not a window — the delivery receipt is the honest effect,
        // never a window delta.
        add(["new note", "new email", "new e-mail", "new message", "new mail",
             "new reminder", "new event", "compose", "compose an email",
             "compose a message", "compose a new email", "write a new email",
             "create a note", "create a new note", "make a note", "make a new note"],
            ["cmd", "n"], "⌘N", "Creating a new item", "Created a new item", .delivered,
            generic: true)
        // ⌘↑/⌘↓ jump to the document edges — same honesty as other scrolls.
        add(["scroll to top", "scroll to the top", "scroll to the top of the page",
             "go to the top", "go to the top of the page", "back to the top",
             "scroll all the way up", "jump to the top"],
            ["cmd", "up"], "⌘↑", "Scrolling to the top", "Scrolled to the top", .delivered,
            generic: true)
        add(["scroll to bottom", "scroll to the bottom", "scroll to the bottom of the page",
             "go to the bottom", "go to the bottom of the page", "scroll all the way down",
             "jump to the bottom"],
            ["cmd", "down"], "⌘↓", "Scrolling to the bottom", "Scrolled to the bottom", .delivered,
            generic: true)
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
        // ⌘` cycles this app's windows — z-order isn't cleanly AX-observable,
        // so the driver's delivery receipt is the honest effect.
        add(["next window", "switch to next window", "switch to the next window",
             "cycle windows", "next app window", "switch between windows"],
            ["cmd", "`"], "⌘`", "Switching to the next window", "Switched to the next window",
            .delivered, generic: true)
        // System chords — the effect is a global UI, not a window delta.
        add(["open spotlight", "spotlight", "spotlight search", "open spotlight search",
             "open search", "bring up spotlight"],
            ["cmd", "space"], "⌘Space", "Opening Spotlight", "Opened Spotlight",
            .delivered, generic: true)
        add(["mission control", "show all windows", "see all windows",
             "show me all windows", "all windows"],
            ["ctrl", "up"], "⌃↑", "Opening Mission Control", "Opened Mission Control",
            .delivered, generic: true)
        add(["app windows", "show app windows", "show this app's windows", "app expose"],
            ["ctrl", "down"], "⌃↓", "Showing the app's windows", "Showed the app's windows",
            .delivered, generic: true)
        // ⌘L is deliberately absent (same policy as the loop's hotkey
        // chords): delivered to a backgrounded browser the omnibox-focus
        // semantic still activates the app — the fast lane resolves a
        // uniquely-running tabbable app that need not be frontmost.
        return t
    }()

    /// Whole-utterance system-key phrases — NX_SYSDEFINED media/system keys
    /// posted to the HID tap, no app or window involved. They live outside
    /// `table` so a peeled qualifier can never pretend to scope a global
    /// key, and they match before the qualifier split for the same reason.
    /// "stop" is deliberately absent: the play/pause key toggles, so a stop
    /// request on a paused player would resume it — the opposite effect.
    private static let mediaTable: [String: CuaFastAction] = {
        var t: [String: CuaFastAction] = [:]
        func add(_ phrases: [String], _ key: MediaKeys.Key, _ description: String, _ result: String) {
            let action = CuaFastAction(body: .mediaKey(key), generic: true,
                                       description: description, result: result, effect: .delivered)
            for phrase in phrases { t[phrase] = action }
        }
        // Pronoun/empty referents after "play" mean resume, not a search —
        // "play it" unpauses; only "play <named thing>" is the play lane.
        add(["play", "pause", "resume", "unpause", "play pause", "play/pause",
             "play music", "play the music", "play some music", "play something",
             "pause music", "pause the music", "resume music", "resume the music",
             "resume playback", "toggle play", "play it", "play that", "play this",
             "play the track", "play the song", "play that song", "play this song",
             "play that track", "play the one"],
            .playPause, "Toggling play/pause", "Toggled play/pause")
        add(["next track", "next song", "skip", "skip track", "skip this track",
             "skip song", "skip this song", "play the next track", "play next track",
             "play the next song", "play next song", "forward a track"],
            .nextTrack, "Skipping to the next track", "Skipped to the next track")
        add(["previous track", "previous song", "last track", "last song",
             "play the previous track", "play previous track", "play the last track",
             "go back a track", "back a track", "restart the track"],
            .previousTrack, "Going to the previous track", "Went to the previous track")
        add(["mute", "unmute", "mute the volume", "mute volume", "mute audio",
             "mute the audio", "unmute the volume", "toggle mute"],
            .mute, "Toggling mute", "Toggled mute")
        add(["volume up", "turn the volume up", "turn it up", "louder",
             "raise the volume", "increase the volume", "increase volume",
             "make it louder", "turn up the volume", "volume higher"],
            .volumeUp, "Turning the volume up", "Turned the volume up")
        add(["volume down", "turn the volume down", "turn it down", "quieter",
             "lower the volume", "decrease the volume", "decrease volume",
             "make it quieter", "turn down the volume"],
            .volumeDown, "Turning the volume down", "Turned the volume down")
        add(["brightness up", "brighter", "increase the brightness", "increase brightness",
             "turn the brightness up", "make the screen brighter", "screen brighter",
             "brighten the screen"],
            .brightnessUp, "Turning the brightness up", "Turned the brightness up")
        add(["brightness down", "dimmer", "dim the screen", "decrease the brightness",
             "decrease brightness", "turn the brightness down", "make the screen dimmer",
             "screen dimmer", "darken the screen", "make the screen darker"],
            .brightnessDown, "Turning the brightness down", "Turned the brightness down")
        return t
    }()
}
