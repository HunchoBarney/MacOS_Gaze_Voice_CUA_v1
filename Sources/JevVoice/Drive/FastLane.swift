import AppKit
import Foundation
import JevVoiceCore

struct WindowScrollRequest: Sendable {
    static let smallLines = 1
    static let normalLines = 3
    let goal: String
    let application: String
    let windowID: Int
    let direction: String
    let lines: Int
    let continuation: NativeWindowObservation.ScrollViewport?

    init?(goal: String, application: String, windowID: Int, direction: String, small: Bool,
          continuation: NativeWindowObservation.ScrollViewport? = nil) {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !application.isEmpty, windowID > 0,
              ["up", "down", "left", "right"].contains(direction) else { return nil }
        if let continuation {
            guard continuation.window.windowID == windowID, continuation.supports(direction) else { return nil }
        }
        self.goal = goal
        self.application = application
        self.windowID = windowID
        self.direction = direction
        lines = small ? Self.smallLines : Self.normalLines
        self.continuation = continuation
    }

    func matches(_ task: DriveTask) -> Bool {
        Data(task.goal.utf8) == Data(goal.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            && task.application == application && task.windowID == windowID
            && task.scope == .work && task.values.isEmpty && task.successContains.isEmpty
            && task.windowName == nil
            && task.previousContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}

/// The deterministic verb layer: whole-utterance commands whose correct
/// execution is a known chord, app primitive, or URL — no model call needed.
/// The drive loop resolves these first; each carries a typed `Effect` that
/// is verified from live state after dispatch, never asserted.
///
/// Ported lean from the retired fast lane: app open/raise/control, window
/// and tab chords, media keys, counted scrolls, literal typing, engine
/// searches, explicit URL navigation, menu paths, window snaps,
/// repeat/locate, and desktop-scope system chords.
struct FastAction: Sendable {
    enum Body: Sendable {
        /// A chorded shortcut scoped to one window.
        case hotkey(keys: [String], shortcut: String)
        /// A desktop-scope chord needing no app or window — lock screen,
        /// screenshots, show desktop, app switcher, zoom toggle. Posted
        /// with `scope:"desktop"`; the delivery receipt is the honest effect.
        case systemHotkey(keys: [String], shortcut: String)
        /// Exact text into the window's single unambiguous editable element.
        case type(String)
        /// Pages of window-scoped scroll — direction is the driver's
        /// vocabulary, pages is a bounded repetition count.
        case scroll(direction: String, pages: Int)
        /// hide/unhide/minimize/quit — app verbs verified by window/process state.
        case appControl(AppVerb)
        /// A global system key posted to the HID tap — no app, no window.
        case mediaKey(MediaKeys.Key)
        /// A URL handed to a bound browser window or LaunchServices.
        case navigateURL(String)
        /// A bare "search for X" — opens a fresh tab on the default engine,
        /// never reusing the user's current tab and never guessing a field.
        case webSearch(String)
        /// "search <app> for X" — field-level search inside the named app,
        /// or "play X" (search plus top-hit play) on a media app.
        case appSearch(query: String, playTopHit: Bool)
        /// A referent verb resolved by where the user is looking — the gaze
        /// point, not an app name. Dispatch needs a live tracker sample;
        /// a dead tracker answers honestly instead of guessing a target.
        case gaze(GazeVerb)
        /// Tracker self-control — pause/resume and recalibrate ride the
        /// tracker's `/control`; enable/disable flip the host feature
        /// switch. No app and no gaze sample: they steer the tracker
        /// itself, so a dead tracker answers honestly, never a claimed
        /// toggle.
        case tracker(TrackerVerb)
        /// A native menu path — `invoke_menu` resolves the segments one
        /// level at a time. A single-segment path is an item-only request:
        /// the driver searches top-level menus or fails closed.
        case menu(path: [String])
        /// Snap/tile geometry — `set_window_frame` against the bound
        /// window's containing screen, verified by a bounds readback.
        case windowFrame(WindowSnap)
        /// Re-dispatch the most recent confirmed fast action — "do that
        /// again". The coordinator owns the replay log; the executor asks
        /// it through the injected seam and refuses honestly when empty.
        case repeatLast
        /// "Where did X go" — locate a minimized/hidden/off-Space window
        /// by app name or title fragment, report where it is, restore it.
        case locate(query: String)
        /// Dictation mode control — "start dictating" latches the literal
        /// capture lane, "stop dictating" ends it. Carries no text itself:
        /// the executor hands the bool to the coordinator's
        /// `onDictationRequest` seam, so dictated words reach
        /// DictationDelivery verbatim and never see a planner or model.
        case dictation(Bool)
    }

    /// Snap/tile verbs — fractions of the window's containing screen.
    enum WindowSnap: String, Equatable, Sendable {
        case left, right, fill
    }

    /// Gaze-referent verbs — "click", "open this", "what is this". The
    /// point comes from the tracker at dispatch time; these carry no
    /// target of their own, so an absent tracker means an honest refusal.
    enum GazeVerb: String, Equatable, Sendable {
        /// One click at the gaze point — covers "click", "tap", "open this".
        case click
        /// Right-button click pair posted host-side (driver has no
        /// desktop-scope right click — its right_click needs a pid).
        case rightClick
        /// Canonical clickState 1→2 pair posted host-side.
        case doubleClick
        /// Read the window/element under the gaze point back to the user.
        case describe
    }

    /// Tracker self-control verbs — the voice surface of `POST /control`
    /// and the `Config.gazeTracking` feature switch.
    enum TrackerVerb: String, Equatable, Sendable {
        /// Pause and resume share the tracker's single `pause_toggle` —
        /// the tracker owns the state, the phrase only flips it.
        case pauseToggle
        case recalibrate
        /// The host feature switch — `Config.gazeTracking`, whose
        /// publisher owns the tracker process lifecycle.
        case enable, disable
    }

    /// What honest success looks like — verified from the live window and
    /// process state, not a keystroke receipt.
    enum Effect: Sendable {
        /// The window's tab strip gains exactly N tabs (AXRadioButton children
        /// of AXTabGroup). Falls back to a window-title change when no tab
        /// strip exists (Finder's ⌘T makes a tab in modern macOS but reports
        /// differently).
        case tabsDelta(Int)
        /// The selected tab/page identity changes (window title or selected
        /// tab label).
        case tabSelectionDelta
        /// The process gains exactly N top-level windows.
        case windowDelta(Int)
        /// Text appears in the target's value — typed insertion.
        case typedText
        /// The pinned window leaves the on-screen set (minimize).
        case windowOffScreen
        /// Every window of the app leaves the screen (hide).
        case appOffScreen
        /// The window's bounds grow to cover a screen (enter full screen).
        case boundsToScreen
        /// The window's bounds shrink from screen-covering (exit full screen).
        case boundsFromScreen
        /// The app's process exits (quit).
        case processGone
        /// Every window of the app returns to the screen (unhide).
        case appOnScreen
        /// The driver's own effect field is the evidence — the outcome can't
        /// be read back from window state (press a key, post a media key).
        case delivered
    }

    enum AppVerb: String, Equatable, Sendable {
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
        switch body {
        case .hotkey(_, let shortcut), .systemHotkey(_, let shortcut): return shortcut
        default: return nil
        }
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
    /// The user literally named this action ("lock screen", "close this
    /// tab") — the literal request IS the consent, so the risk gate passes
    /// it. Rows that merely *match* destructive keywords stay false.
    var directlyRequested = false
    /// A gaze-derived field or window, not an independently bound target.
    var deictic = false

    /// Display-scope qualifier sentinel — "on this monitor"/"over there"
    /// peels into a qualifier carrying this marker instead of an app name;
    /// it must not resolve to an app or an active window.
    static let gazeDisplayQualifier = "__gaze_display__"

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
    static func parse(_ text: String) -> (action: FastAction, appQualifier: String?)? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        // Whole-utterance dictation mode controls must outrun the negation
        // gate — "stop dictating" IS the stop command, and the head-word
        // negator would eat it before its own table ever saw it. The
        // exact-match lookup keeps genuine negations dead-ended: "don't
        // stop dictating" is no table key.
        if let dictation = dictationTable[normalized] { return (dictation, nil) }
        guard !isNegated(normalized) else { return nil }
        // Typed payloads are case/punctuation-exact, so they parse on the raw
        // text — the normalized command would corrupt "Hello, World".
        if let typed = parseType(text) { return typed }
        // System media keys are global — the whole utterance must be exactly
        // the phrase, so they match before the app-qualifier split. A peeled
        // qualifier ("mute in zoom") can't scope system volume, so it drops
        // to the loop rather than pretending otherwise.
        if let media = mediaTable[normalized] { return (media, nil) }
        // "on this monitor"/"over there" name the screen under the user's
        // eyes, not an app — peel before the app split so the phrase can
        // never be read as a qualifier. The scope rides the qualifier slot
        // as the sentinel; an app qualifier peeled from the remainder
        // outranks it ("minimize in notes on this monitor" still names notes).
        let display = peelDisplayScope(normalized)
        var command = display.rest
        // Menu frames carry their own "in the X menu" preposition — the
        // app-qualifier split would eat the tail as an app name, so the
        // frame parses before the split.
        if let menu = parseMenu(command) {
            return (menu, display.scoped ? Self.gazeDisplayQualifier : nil)
        }
        var qualifier: String?
        if let split = splitAppQualifier(command) {
            command = split.command
            qualifier = split.qualifier
        }
        // Verb-first app control parses the post-peel command so "minimize the
        // window in notes" keeps its ⌘M+qualifier meaning; a phrase that peels
        // a qualifier AND leaves a verb-first tail is ambiguous — the loop owns it.
        if command == "hide numbers" || command == "hide the numbers" { return nil }
        if qualifier == nil, let control = parseAppControl(command) { return control }
        if qualifier == nil, display.scoped { qualifier = Self.gazeDisplayQualifier }
        guard let action = table[command] else {
            if let lane = parseQueryLane(command, qualifier: qualifier) { return lane }
            if let scroll = parseScrollReps(command) { return (scroll, qualifier) }
            if let tab = parseTabIndex(command) { return (tab, qualifier) }
            if let menu = parseMenu(command) { return (menu, qualifier) }
            if let snap = snapTable[command] { return (snap, qualifier) }
            if let system = systemTable[command] { return (system, qualifier) }
            if let again = repeatTable[command] { return (again, qualifier) }
            if let locate = parseLocate(command) { return (locate, qualifier) }
            // Whole-utterance gaze referents — "click", "open this", "what
            // is this" — resolve no app; the point arrives at dispatch.
            // Peeled qualifiers are emphasis, not targets ("click this in
            // chrome" still means the thing under your eyes).
            if let gaze = gazeTable[command] {
                return (gaze, qualifier)
            }
            // Tracker self-control — "pause tracking", "recalibrate" —
            // steers the tracker, never an app; a peeled qualifier is
            // emphasis, the same as the gaze referents above.
            if let tracker = trackerTable[command] {
                return (tracker, qualifier)
            }
            // Dictation-mode verbs — "start dictating", "stop
            // dictating" — steer the literal-capture lane, never an app
            // or a planner. Whole utterances only: "dictate <text>" is
            // the typing intent and keeps falling through to the model
            // lane, never swallowed as a mode toggle.
            if let dictation = dictationTable[command] {
                return (dictation, qualifier)
            }
            return nil
        }
        // "minimize this"/"close it"/"hide this app" — the pronoun names
        // the window under the user's eyes. Only window-level verbs take
        // the gaze binding: an editing row that happens to carry the same
        // word ("undo that", "cut this") keeps the focused target.
        var windowAction = action
        if Self.isDeicticWindowVerb(windowAction, command: command) {
            windowAction.deictic = true
        }
        return (windowAction, qualifier)
    }

    /// The matched whole-phrase command is a window-level verb whose
    /// pronoun is the window referent — a live tracker must aim the
    /// action at the gazed window, not the frontmost app's focused one.
    private static func isDeicticWindowVerb(_ action: FastAction, command: String) -> Bool {
        guard case .hotkey = action.body else { return false }
        switch action.effect {
        case .windowOffScreen, .windowDelta(-1), .appOffScreen: break
        default: return false
        }
        return command.split(separator: " ").contains { $0 == "this" || $0 == "it" }
    }

    /// Resolve an app qualifier (or its absence) to an installed app.
    /// Keystroke lanes resolve through the frontmost tabbable app or a
    /// uniquely running tabbable app; text entry with no qualifier means the
    /// app the user is looking at — the frontmost one. Ambiguity returns nil
    /// so the caller falls back to the ordinary decision path.
    static func resolveApp(qualifier: String?, action: FastAction, apps: [JSONValue],
                           frontmostBundle: String?) -> (name: String, bundle: String)? {
        if let qualifier {
            let exact = apps.filter {
                $0["bundle_id"]?.string?.caseInsensitiveCompare(qualifier) == .orderedSame
            }
            if !exact.isEmpty {
                guard exact.count == 1, let bundle = exact[0]["bundle_id"]?.string else { return nil }
                return (exact[0]["name"]?.string ?? bundle, bundle)
            }
            var q = normalize(qualifier)
            // Spoken packaging is not the name — "close my google browser"
            // names Chrome. resolveOpenApp peels the same affixes; the
            // qualifier path must too or "my google" resolves nothing.
            for prefix in ["the ", "my "] {
                if q.hasPrefix(prefix) { q = String(q.dropFirst(prefix.count)) }
            }
            for suffix in [" app", " application", " browser"] {
                if q.hasSuffix(suffix) { q = String(q.dropLast(suffix.count)) }
            }
            if genericBrowserQualifiers.contains(q) {
                return implicitBrowser(apps: apps, frontmostBundle: frontmostBundle)
            }
            if let nick = nicknameApp(q, apps: apps, frontmostBundle: frontmostBundle) {
                return nick
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

    /// Elder-novice names for the stock apps — the spoken word is never the
    /// app name, so the name/bundle matcher can't reach it. The value feeds
    /// back through `namedApp`, so a missing or ambiguous target still fails
    /// closed to nil. The resolvers strip "the "/"my " before consulting the
    /// map; the affixed spellings ride along for any caller that doesn't.
    private static let appNicknames: [String: String] = [
        "the email thing": "mail", "email thing": "mail",
        "my email": "mail", "email": "mail",
        "my letters": "pages", "letters": "pages",
        "my documents": "pages", "documents": "pages",
        "the photos": "photos", "my pictures": "photos", "pictures": "photos",
        "my messages": "messages", "my texts": "messages", "texts": "messages",
        "the calendar": "calendar",
        "the notes": "notes", "my notes": "notes",
    ]
    /// "the internet"/"the web" name no app — they mean whichever browser
    /// is in front, the same implicit route as "the browser".
    private static let browserNicknames: Set<String> = [
        "the internet", "internet", "the web", "web"
    ]

    /// Nickname resolution shared by the qualifier and open-query paths,
    /// consulted before `namedApp`. A mapped name still resolves through
    /// the real matcher — ambiguity returns nil so the resolver can name
    /// the candidates upstream.
    private static func nicknameApp(_ q: String, apps: [JSONValue],
                                    frontmostBundle: String?) -> (name: String, bundle: String)? {
        if browserNicknames.contains(q) {
            return implicitBrowser(apps: apps, frontmostBundle: frontmostBundle)
        }
        guard let target = appNicknames[q] else { return nil }
        return namedApp(target, in: apps)
    }

    /// Trailing display scopes — the screen under the user's eyes, not an
    /// app. Peeled before the qualifier split so "on this monitor" can
    /// never surface as an app name the resolver would fail on.
    private static let displayScopePhrases = [
        "on this monitor", "on this screen", "on that monitor", "on that screen",
        "over there", "on the other display", "on the other screen",
        "on the big screen"
    ]

    /// Peel a trailing display-scope phrase; `scoped` reports the peel.
    /// Accepts raw or normalized text — `parse`/`parseOpen` call it on the
    /// normalized command, the executor on the raw goal to recover the
    /// `gazeDisplayQualifier` marker for an open.
    static func peelDisplayScope(_ text: String) -> (rest: String, scoped: Bool) {
        let normalized = normalize(text)
        for phrase in displayScopePhrases {
            if normalized == phrase { return ("", true) }
            if normalized.hasSuffix(" " + phrase) {
                return (String(normalized.dropLast(phrase.count + 1)), true)
            }
        }
        return (normalized, false)
    }

    private static let fillers = ["hey jarvis", "jarvis", "please", "can you", "could you",
                                  "would you", "go ahead and", "just"]

    /// Trailing politeness/pointing tails — "minimize devin actually" names
    /// devin. Longest-first and repeated so stacked tails all strip; only a
    /// whole-word suffix goes, so "open now playing" keeps "now playing"
    /// ("playing", not "now", is the tail).
    private static let trailingFillers = ["thank you", "right now", "actually", "instead",
                                          "please", "thanks", "for me", "though", "now"]

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
        var stripped = true
        while stripped, !s.isEmpty {
            stripped = false
            for filler in trailingFillers {
                if s == filler { s = ""; stripped = true; break }
                if s.hasSuffix(" " + filler) {
                    s = String(s.dropLast(filler.count + 1))
                    stripped = true
                    break
                }
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// `open|launch|start|show|switch to|bring up|focus|go to|bring|foreground|pull up|raise <app>` —
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
            // A trailing display phrase is scope, not part of the app name
            // — "open google on this monitor" queries "google". The marker
            // itself stays out of the tuple; the executor recovers it by
            // calling peelDisplayScope on the raw goal.
            rest = peelDisplayScope(rest).rest
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
        if let nick = nicknameApp(q, apps: apps, frontmostBundle: frontmostBundle) {
            return nick
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
    private static func parseAppControl(_ normalized: String) -> (action: FastAction, appQualifier: String?)? {
        let verbs: [(String, AppVerb)] = [("hide", .hide), ("unhide", .unhide),
                                          ("minimize", .minimize), ("minimise", .minimize),
                                          ("close", .quit), ("exit", .quit),
                                          ("quit", .quit)]
        for (verb, kind) in verbs {
            guard normalized.hasPrefix(verb + " ") else { continue }
            var rest = String(normalized.dropFirst(verb.count + 1))
            if rest.hasPrefix("the ") { rest = String(rest.dropFirst(4)) }
            var hadWindowSuffix = false
            // " window*"/" tab*" and " app" packaging only; possessive flattening
            // ("spotify's windows" → "spotifys windows") is recovered by
            // namedApp's trailing-'s' fallback so "notes window" isn't
            // mangled into a substring that can turn ambiguous.
            for suffix in [" windows", " window", " tabs", " tab", " app"] {
                if rest.hasSuffix(suffix) {
                    hadWindowSuffix = suffix.contains("window") || suffix.contains("tab")
                    rest = String(rest.dropLast(suffix.count)); break
                }
            }
            // "close Spotify's window" means ⌘W, not ⌘Q — a window- or
            // tab-suffixed close must not lane as an app quit. "exit full
            // screen" is likewise a window/fullscreen toggle, never a quit.
            if hadWindowSuffix, verb == "close" { continue }
            if verb == "exit", ["fullscreen", "full screen", "full-screen"].contains(rest) { continue }
            rest = rest.trimmingCharacters(in: .whitespaces)
            // "minimize window", "hide the app" and vague or collective
            // referents keep their whole-phrase table meaning; only a
            // resolvable app name may lane.
            guard !rest.isEmpty,
                  !["window", "windows", "app", "it", "this", "that", "current",
                    "tab", "tabs", "all", "everything", "others", "other apps"].contains(rest)
            else { continue }
            let description: String
            let result: String
            switch kind {
            case .hide: description = "Hiding the app"; result = "Hid the app"
            case .unhide: description = "Unhiding the app"; result = "Unhid the app"
            case .minimize: description = "Minimizing the window"; result = "Minimized the window"
            case .quit: description = "Quitting the app"; result = "Quit the app"
            }
            return (FastAction(body: .appControl(kind), generic: true,
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
        -> (action: FastAction, appQualifier: String?)? {
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

    /// `search [for] <query>` with no app qualifier — the web-search lane.
    /// Runs only after the qualified parses miss ("search X for Y",
    /// "search X in App"), so the tail is always the query itself: "search
    /// for cute dogs" → Google results in a fresh tab. Never an app guess,
    /// never a typed-into-whichever-field gamble.
    static func parseBareSearch(_ command: String) -> FastAction? {
        guard let query = searchQueryTail(command),
              let encoded = query.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return FastAction(body: .webSearch("https://www.google.com/search?q=\(encoded)"),
                          generic: true,
                          description: "Searching Google for '\(query)'",
                          result: "Opened the results",
                          effect: .delivered)
    }

    private static func queryAction(_ query: String, playTopHit: Bool) -> FastAction {
        FastAction(body: .appSearch(query: query, playTopHit: playTopHit), generic: true,
                   description: playTopHit ? "Playing “\(query)”" : "Searching for “\(query)”",
                   result: playTopHit ? "Dispatched play for “\(query)”" : "Searched for “\(query)”",
                   effect: .delivered)
    }

    /// `scroll <dir> [the page] <N> times` — a counted repetition the static
    /// phrases can't enumerate. Pages are capped; beyond ten the drive loop
    /// decides what "a lot" means in the window.
    private static func parseScrollReps(_ command: String) -> FastAction? {
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
        return FastAction(body: .scroll(direction: direction, pages: min(count, 10)), generic: true,
                          description: "Scrolling \(direction)", result: "Scrolled \(direction)",
                          effect: .delivered)
    }

    /// Spoken number words shared by the tab-index and task-choice
    /// parses — cardinals, the ordinals "the third tab" carries, and the
    /// tens a spoken chip number can reach.
    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9
    ]

    /// `tab <n>` / `go to tab <n>` / `the third tab` — ⌘<digit> selects a
    /// tab by position, a browser-chrome chord, so the action stays
    /// non-generic and keeps needsTabbableApp. Positions stop at nine —
    /// ⌘10 is no chord and a longer count is a guess, not a command.
    private static func parseTabIndex(_ command: String) -> FastAction? {
        for pattern in [#"^(?:(?:go|switch|move) to )?(?:the )?tab ([a-z0-9]+)$"#,
                        #"^(?:(?:go|switch|move) to )?(?:the )?([a-z]+) tab$"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                  let range = Range(match.range(at: 1), in: command) else { continue }
            let token = String(command[range])
            guard let n = Int(token) ?? numberWords[token], (1...9).contains(n) else { continue }
            return FastAction(body: .hotkey(keys: ["cmd", "\(n)"], shortcut: "⌘\(n)"),
                              generic: false,
                              description: "Switching to tab \(n)",
                              result: "Switched to tab \(n)",
                              effect: .tabSelectionDelta)
        }
        return nil
    }

    /// `choose <item> in the <menu> menu` / `<menu> menu <item>` /
    /// `menu <item>` / `press <item> in the menu` — a native menu path the
    /// driver resolves one segment at a time. Conservative by contract:
    /// the phrase must carry a menu/choose frame, and an item containing
    /// another preposition is ambiguous — the loop owns it.
    private static func parseMenu(_ command: String) -> FastAction? {
        func action(_ path: [String]) -> FastAction {
            FastAction(body: .menu(path: path), generic: true,
                       description: "Choosing “\(path.joined(separator: " → "))”",
                       result: "Chose the menu item", effect: .delivered)
        }
        // An item carrying another preposition ("menu save as in notes")
        // blurs where the item ends — ambiguous phrasing stays for the loop.
        func validItem(_ item: String) -> String? {
            let item = item.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty,
                  item.range(of: #"\b(?:in|on|inside|with|using)\b"#,
                             options: .regularExpression) == nil else { return nil }
            return item
        }
        // "choose <item> in [the] <menu> menu" — menu segment first.
        if let expression = try? NSRegularExpression(
                pattern: #"^choose (.+?) in (?:the )?([a-z]+(?: [a-z]+)?) menu$"#),
           let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
           let itemRange = Range(match.range(at: 1), in: command),
           let menuRange = Range(match.range(at: 2), in: command),
           let item = validItem(String(command[itemRange])) {
            return action([String(command[menuRange]), item])
        }
        // "<menu> menu <item>" — "file menu save as", "choose edit menu
        // copy". The menu segment stays a single word: anything longer
        // ("show me the menu bar") is prose wearing the frame.
        if let expression = try? NSRegularExpression(
                pattern: #"^(?:choose )?([a-z]+) menu (.+)$"#),
           let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
           let menuRange = Range(match.range(at: 1), in: command),
           let itemRange = Range(match.range(at: 2), in: command),
           let item = validItem(String(command[itemRange])) {
            return action([String(command[menuRange]), item])
        }
        // "menu <item>" / "press <item> in the menu" — item-only: the
        // driver searches the top-level menus or fails closed.
        var item: String?
        if command.hasPrefix("menu ") {
            item = String(command.dropFirst(5))
        } else if let expression = try? NSRegularExpression(pattern: #"^press (.+?) in the menu$"#),
                  let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                  let range = Range(match.range(at: 1), in: command) {
            item = String(command[range])
        }
        guard let item, let valid = validItem(item) else { return nil }
        return action([valid])
    }

    enum RetiredTargetRequest: Equatable {
        case palette, pick(Int), unboundGaze
    }

    static func retiredTargetRequest(_ text: String) -> RetiredTargetRequest? {
        let raw = HandsFreeActionSyntax.withoutCourtesy(text)
        let scoped = peelDisplayScope(raw)
        let head = scoped.rest.split(separator: " ").first ?? ""
        if scoped.scoped || ["type", "hide", "close", "minimize", "minimise"].contains(head) {
            if let parsed = parse(raw) {
                if parsed.action.deictic { return .unboundGaze }
                if parsed.appQualifier == gazeDisplayQualifier {
                    if case .gaze(.describe) = parsed.action.body { return nil }
                    return .unboundGaze
                }
            } else if head == "type", stripDeicticSuffix(raw) != nil {
                return .unboundGaze
            } else if scoped.scoped, ["type", "close", "hide", "minimize", "minimise"].contains(head) {
                return .unboundGaze
            }
        }
        if scoped.rest.hasSuffix(" menu"), parseMenu(scoped.rest) != nil { return nil }
        let qualifier = splitAppQualifier(scoped.rest)
        let command = qualifier?.command ?? scoped.rest
        switch command {
        case "show numbers", "show me the numbers", "show the numbers", "numbers",
             "show numbers everywhere", "numbers everywhere", "all numbers",
             "show all numbers", "hide numbers", "clear numbers", "hide the numbers":
            return .palette
        default: break
        }
        let words = command.split(separator: " ")
        guard words.count == 2, ["click", "press", "choose", "pick", "number"].contains(words[0]),
              let n = Int(words[1]) ?? numberWords[String(words[1])] else { return nil }
        guard !scoped.scoped, qualifier == nil, (1...99).contains(n),
              !text.contains(where: { "\"“”‘’'`?".contains($0) }) else { return .palette }
        return .pick(n)
    }

    /// `where did <X> go` / `wheres <X>` / `bring back <X>` / `find my <X>`
    /// — locate a window that left the screen. Only the where-framed and
    /// possessive forms lane here: bare "find" stays ⌘F and "find X" stays
    /// a search, never a window hunt.
    private static func parseLocate(_ command: String) -> FastAction? {
        var rest: String?
        for prefix in ["where did ", "where is ", "wheres ", "bring back ", "find my "] {
            if command.hasPrefix(prefix) { rest = String(command.dropFirst(prefix.count)); break }
        }
        guard var query = rest else { return nil }
        if query.hasSuffix(" go") { query = String(query.dropLast(3)) }
        // Packaging words are not the target — "where did my notes window
        // go" hunts "notes".
        let words = query.split(separator: " ")
            .map(String.init)
            .filter { !["my", "the", "window", "windows", "app"].contains($0) }
        query = words.joined(separator: " ")
        // A pronoun or an empty remainder names nothing the lane can find.
        guard !query.isEmpty, !["it", "this", "that", "there"].contains(query) else { return nil }
        return FastAction(body: .locate(query: query), generic: true,
                          description: "Finding where “\(query)” went",
                          result: "Located “\(query)”", effect: .delivered)
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
    /// the literal remainder in its original casing. A fully-quoted payload is
    /// verbatim. Otherwise a trailing app qualifier is peeled only at the
    /// rightmost trailing preposition, and any *interior* destination
    /// preposition ("type X into this document") returns nil: deciding where
    /// the text lands is the literal-insertion path's job, not a guess. A
    /// qualifier that resolves to no app also fails the whole parse, so
    /// "type sign in hello" keeps its payload intact for the agent loop.
    private static func parseType(_ text: String) -> (action: FastAction, appQualifier: String?)? {
        let stripped = stripFillers(text)
        let pattern = #"^type(?:\s+(?:out|exactly|the\s+(?:word|phrase|text|string)))?\s+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let prefix = Range(match.range, in: stripped) else { return nil }
        var rest = String(stripped[prefix.upperBound...])
        var qualifier: String?
        var deictic = false
        let verbatim = fullyQuoted(rest)
        if let quoted = verbatim {
            rest = quoted
        } else {
            if peelDisplayScope(rest).scoped { return nil }
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
        let payload = verbatim ?? unquote(rest.trimmingCharacters(in: .whitespaces))
        guard !payload.isEmpty else { return nil }
        let shown = payload.count > 40 ? String(payload.prefix(40)) + "…" : payload
        return (FastAction(body: .type(payload), generic: true,
                           description: "Typing “\(shown)”\(deictic ? " at the insertion point" : "")",
                           result: "Typed the text", effect: .typedText,
                           deictic: deictic),
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
    /// request. User-named mutations ("close tab", "undo", "save") lane
    /// here with `directlyRequested` — the literal phrase is the consent.
    /// "quit" stays verb-first in parseAppControl, and `press delete` is
    /// deliberately absent: its label carries a risk keyword that must be
    /// judged, not shortcut.
    private static let table: [String: FastAction] = {
        var t: [String: FastAction] = [:]
        func add(_ phrases: [String], _ keys: [String], _ shortcut: String,
                 _ description: String, _ result: String, _ effect: Effect,
                 generic: Bool = false, directlyRequested: Bool = false) {
            let action = FastAction(body: .hotkey(keys: keys, shortcut: shortcut), generic: generic,
                                    description: description, result: result, effect: effect,
                                    directlyRequested: directlyRequested)
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
             "minimise window", "minimise the window", "minimise this window",
             "minimize", "minimise", "minimize this", "minimize it",
             "minimize the app", "minimise this", "minimise it", "minimise the app"],
            ["cmd", "m"], "⌘M", "Minimizing the window", "Minimized the window", .windowOffScreen,
            generic: true)
        // ⌥⌘M minimizes every window of the frontmost app — the pinned
        // window leaving the screen remains the honest readback.
        add(["minimize all windows", "minimize all the windows", "minimise all windows",
             "minimize everything", "minimise everything"],
            ["alt", "cmd", "m"], "⌥⌘M", "Minimizing all windows", "Minimized the windows",
            .windowOffScreen, generic: true)
        // ⌥⌘H hides every app but the frontmost — the receipt is the
        // honest effect; other apps' windows aren't ours to read back.
        add(["hide others", "hide other apps", "hide the other apps",
             "hide all other apps"],
            ["alt", "cmd", "h"], "⌥⌘H", "Hiding the other apps", "Hid the other apps",
            .delivered, generic: true)
        add(["hide", "hide this app", "hide the app", "hide this", "hide it"],
            ["cmd", "h"], "⌘H", "Hiding the app", "Hid the app", .appOffScreen,
            generic: true)
        add(["enter full screen", "enter fullscreen", "full screen", "fullscreen",
             "go full screen", "go fullscreen", "make it full screen",
             "make it fullscreen", "make this fullscreen", "maximize", "maximise"],
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
            let action = FastAction(body: .scroll(direction: direction, pages: pages), generic: true,
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
             "zoom in on the page", "make the page bigger",
             "make text bigger", "bigger text", "make the words bigger", "bigger"],
            ["cmd", "="], "⌘+", "Zooming in", "Zoomed in", .delivered)
        add(["zoom out", "zoom out the page", "zoom the page out", "decrease zoom",
             "zoom out of the page", "make the page smaller",
             "make text smaller", "smaller text", "make the words smaller", "smaller"],
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
        // ⌘W closes the frontmost window or tab — the user names the
        // target in the phrase itself, so the request is the consent and
        // the window delta verifies the close actually happened.
        add(["close this tab", "close tab", "close the tab",
             "close this window", "close the window", "close window",
             "close this", "close it"],
            ["cmd", "w"], "⌘W", "Closing the window", "Closed the window",
            .windowDelta(-1), generic: true, directlyRequested: true)
        // Editing chords — the user literally names the mutation, so the
        // phrase is the consent; no AX readback distinguishes a delivered
        // chord, so the driver's receipt is the honest effect.
        add(["undo", "undo that", "undo this", "take that back", "put it back"],
            ["cmd", "z"], "⌘Z", "Undoing", "Undid the last change", .delivered,
            generic: true, directlyRequested: true)
        add(["redo", "redo that"], ["cmd", "shift", "z"], "⇧⌘Z",
            "Redoing", "Redid the change", .delivered,
            generic: true, directlyRequested: true)
        add(["cut", "cut that", "cut this"], ["cmd", "x"], "⌘X",
            "Cutting", "Cut the selection", .delivered,
            generic: true, directlyRequested: true)
        add(["copy", "copy that", "copy this"], ["cmd", "c"], "⌘C",
            "Copying", "Copied the selection", .delivered,
            generic: true, directlyRequested: true)
        add(["paste", "paste that", "paste this"], ["cmd", "v"], "⌘V",
            "Pasting", "Pasted", .delivered,
            generic: true, directlyRequested: true)
        add(["select all", "select everything"], ["cmd", "a"], "⌘A",
            "Selecting all", "Selected all", .delivered,
            generic: true, directlyRequested: true)
        add(["save", "save this", "save it", "save that"], ["cmd", "s"], "⌘S",
            "Saving", "Saved", .delivered,
            generic: true, directlyRequested: true)
        add(["find", "find on page", "find on this page", "search this page"],
            ["cmd", "f"], "⌘F", "Finding on the page", "Opened find", .delivered,
            generic: true, directlyRequested: true)
        add(["print", "print this", "print this page"], ["cmd", "p"], "⌘P",
            "Printing", "Opened print", .delivered,
            generic: true, directlyRequested: true)
        // ⌘L is deliberately absent (same policy as the loop's hotkey
        // chords): delivered to a backgrounded browser the omnibox-focus
        // semantic still activates the app — the fast lane resolves a
        // uniquely-running tabbable app that need not be frontmost.
        return t
    }()

    /// Whole-phrase desktop chords — they act on the machine, not a
    /// window, so the body is `systemHotkey` and the executor posts them
    /// with scope:"desktop". Key names follow the driver's hotkey
    /// vocabulary (mcp-tools.mdx): modifiers first, one non-modifier last
    /// — ⇧⌘4-then-Space window capture is two chords the tool can't
    /// express, so "screenshot window" posts the region chord honestly.
    private static let systemTable: [String: FastAction] = {
        var t: [String: FastAction] = [:]
        func add(_ phrases: [String], _ keys: [String], _ shortcut: String,
                 _ description: String, _ result: String,
                 directlyRequested: Bool = false) {
            let action = FastAction(body: .systemHotkey(keys: keys, shortcut: shortcut),
                                    generic: true, description: description,
                                    result: result, effect: .delivered,
                                    directlyRequested: directlyRequested)
            for phrase in phrases { t[phrase] = action }
        }
        add(["lock screen", "lock my mac", "lock the screen"],
            ["ctrl", "cmd", "q"], "⌃⌘Q", "Locking the screen", "Locked the screen",
            directlyRequested: true)
        add(["screenshot", "take a screenshot", "take a screenshot of the screen"],
            ["cmd", "shift", "3"], "⇧⌘3", "Taking a screenshot", "Took a screenshot")
        add(["screenshot selection", "screenshot a region", "capture a region",
             "screenshot region"],
            ["cmd", "shift", "4"], "⇧⌘4", "Capturing a region", "Posted the region capture")
        add(["screenshot window", "screenshot the window", "capture the window"],
            ["cmd", "shift", "4"], "⇧⌘4", "Capturing a window", "Posted the capture chord")
        add(["show desktop", "show the desktop"],
            ["f11"], "F11", "Showing the desktop", "Showed the desktop")
        add(["app switcher", "switch app", "previous app", "switch apps"],
            ["cmd", "tab"], "⌘⇥", "Opening the app switcher", "Posted ⌘⇥",
            directlyRequested: true)
        // ⌥⌘8 toggles the system screen zoom — the comfort lane, not the
        // page zoom the ⌘=/⌘- rows drive.
        add(["zoom the screen", "magnify the screen", "screen zoom"],
            ["alt", "cmd", "8"], "⌥⌘8", "Toggling screen zoom", "Toggled screen zoom")
        return t
    }()

    /// Snap/tile phrases — `set_window_frame` fractions of the containing
    /// screen; the executor's bounds readback is the verification.
    private static let snapTable: [String: FastAction] = {
        var t: [String: FastAction] = [:]
        func add(_ phrases: [String], _ snap: WindowSnap, _ label: String) {
            let action = FastAction(body: .windowFrame(snap), generic: true,
                                    description: "Snapping the window \(label)",
                                    result: "Snapped the window \(label)",
                                    effect: .delivered)
            for phrase in phrases { t[phrase] = action }
        }
        add(["snap left", "tile left", "window left", "move window left",
             "move the window left", "snap the window left"], .left, "left")
        add(["snap right", "tile right", "window right", "move window right",
             "move the window right", "snap the window right"], .right, "right")
        add(["maximize the window", "maximise the window", "fill the screen",
             "make the window fill", "zoom window"], .fill, "to fill the screen")
        return t
    }()

    /// "Do that again" — the coordinator owns the replay log; the lane
    /// only names the intent and the executor refuses honestly when the
    /// log is empty.
    private static let repeatTable: [String: FastAction] = {
        var t: [String: FastAction] = [:]
        let action = FastAction(body: .repeatLast, generic: true,
                                description: "Doing that again",
                                result: "Repeated the last action", effect: .delivered)
        for phrase in ["do that again", "again", "repeat that", "repeat",
                       "do it again", "same thing", "one more time",
                       "do the same thing"] {
            t[phrase] = action
        }
        return t
    }()

    /// Whole-utterance system-key phrases — NX_SYSDEFINED media/system keys
    /// posted to the HID tap, no app or window involved. They live outside
    /// `table` so a peeled qualifier can never pretend to scope a global
    /// key, and they match before the qualifier split for the same reason.
    /// "stop" is deliberately absent: the play/pause key toggles, so a stop
    /// request on a paused player would resume it — the opposite effect.
    private static let mediaTable: [String: FastAction] = {
        var t: [String: FastAction] = [:]
        func add(_ phrases: [String], _ key: MediaKeys.Key, _ description: String, _ result: String) {
            let action = FastAction(body: .mediaKey(key), generic: true,
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

    /// Whole-utterance gaze referents — the point arrives at dispatch from
    /// the tracker, so these never resolve an app. Every result phrase
    /// says what actually happened ("clicked"), never the hoped-for effect
    /// ("opened") — a click on a Finder icon selects it, and the honest
    /// report is a click.
    private static let gazeTable: [String: FastAction] = {
        var t: [String: FastAction] = [:]
        func add(_ phrases: [String], _ verb: GazeVerb,
                 _ description: String, _ result: String) {
            let action = FastAction(body: .gaze(verb), generic: true,
                                    description: description, result: result,
                                    effect: .delivered)
            for phrase in phrases { t[phrase] = action }
        }
        add(["click", "click this", "click that", "click here", "click it",
             "tap", "tap this", "tap that", "tap it", "press this",
             "select this", "select that", "choose this", "hit it"],
            .click, "Clicking where you're looking", "Clicked where you're looking")
        add(["open this", "open that", "open it up", "open what im looking at"],
            .click, "Opening what you're looking at", "Clicked what you were looking at")
        add(["double click", "double-click", "double click this", "double click that",
             "double-click this", "double tap", "double-tap"],
            .doubleClick, "Double-clicking where you're looking",
            "Double-clicked where you're looking")
        add(["right click", "right-click", "right click this", "right click that",
             "right-click this", "secondary click", "control click", "context menu this"],
            .rightClick, "Right-clicking where you're looking",
            "Right-clicked where you're looking")
        add(["what is this", "whats this", "what's this", "what am i looking at",
             "what is that", "whats that", "what's that", "describe this",
             "describe what im looking at", "what is under my eyes"],
            .describe, "Looking at what's under your gaze", "Told you what's there")
        return t
    }()

    /// Whole-utterance tracker self-controls — same app-free posture as
    /// media keys and gaze referents. Bare "pause"/"resume" stay media
    /// keys; only the tracking-qualified phrases land here. Pause and
    /// resume share one toggle, so the honest result names the toggle
    /// sent — the tracker, not the phrase, owns which way it went.
    private static let trackerTable: [String: FastAction] = {
        var t: [String: FastAction] = [:]
        func add(_ phrases: [String], _ verb: TrackerVerb,
                 _ description: String, _ result: String) {
            let action = FastAction(body: .tracker(verb), generic: true,
                                    description: description, result: result,
                                    effect: .delivered)
            for phrase in phrases { t[phrase] = action }
        }
        add(["pause tracking", "pause eye tracking", "pause the tracker",
             "pause the eye tracker"],
            .pauseToggle, "Pausing eye tracking", "Toggled the tracking pause")
        add(["resume tracking", "resume eye tracking", "resume the tracker",
             "resume the eye tracker", "unpause tracking"],
            .pauseToggle, "Resuming eye tracking", "Toggled the tracking pause")
        add(["recalibrate", "recalibrate eyes", "recalibrate the tracker",
             "recalibrate eye tracking", "tune the tracker"],
            .recalibrate, "Recalibrating the eye tracker",
            "Asked the tracker to recalibrate")
        add(["turn eye tracking on", "enable eye tracking",
             "enable the eye tracker"],
            .enable, "Turning eye tracking on", "Turned eye tracking on")
        add(["turn eye tracking off", "disable eye tracking",
             "disable the eye tracker"],
            .disable, "Turning eye tracking off", "Turned eye tracking off")
        return t
    }()

    /// Whole-utterance dictation-mode verbs — the same app-free posture
    /// as tracker controls: they steer the literal-capture lane
    /// (`VoiceController.startDictation`/`stopDictationCommand`), never a
    /// window. Bare "dictate" is the mode request; "dictate <text>" keeps
    /// its typing meaning because this table only matches whole phrases.
    private static let dictationTable: [String: FastAction] = {
        var t: [String: FastAction] = [:]
        func add(_ phrases: [String], _ start: Bool,
                 _ description: String, _ result: String) {
            let action = FastAction(body: .dictation(start), generic: true,
                                    description: description, result: result,
                                    effect: .delivered)
            for phrase in phrases { t[phrase] = action }
        }
        add(["dictate", "start dictating", "start dictation", "begin dictating",
             "begin dictation", "dictation mode", "take dictation",
             "turn dictation on", "enable dictation", "dictation on"],
            true, "Starting dictation", "Dictation is on")
        add(["stop dictating", "stop dictation", "end dictation",
             "finish dictating", "finish dictation", "exit dictation",
             "cancel dictation", "turn dictation off", "disable dictation",
             "dictation off"],
            false, "Stopping dictation", "Dictation is off")
        return t
    }()
}

// MARK: - Search engines and explicit URLs

/// Request-phrase parsing shared by the fast lane and the drive loop:
/// explicit navigation URLs, named-engine search URLs, and the
/// element-naming helpers criteria text is built from.
enum ActionCatalog {
    /// A DOM-navigable results URL for a request that names its engine
    /// ("search google for the weather", "bing for flights"). Only a bound
    /// payload becomes the query — an unnamed search stays on the omnibox,
    /// which uses the user's own default engine rather than hardcoding one.
    /// Matches "<engine> for <query>" from the end of a request, allowing a
    /// leading "search" and a multi-word engine ("you tube for X").
    private static let engineQueryExpression = try? NSRegularExpression(
        pattern: #"(?i)\b(?:search\s+)?([a-z0-9]+(?:\s+[a-z0-9]+)?)\s+for\s+(.+?)(?:\s*(?:\.|\?|!))?$"#)

    static func namedEngineSearchURL(in goal: String) -> String? {
        guard goal.range(of: #"(?i)\b(?:do\s+not|don't|didn't|never|avoid)\b"#,
                         options: .regularExpression) == nil,
              let expression = Self.engineQueryExpression,
              let match = expression.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              let engineRange = Range(match.range(at: 1), in: goal),
              let queryRange = Range(match.range(at: 2), in: goal) else { return nil }
        return namedEngineSearchURL(engine: String(goal[engineRange]), query: String(goal[queryRange]))
    }

    /// The engine word is caller-resolved context — where an installed app
    /// was expected, a mapped engine produces a deterministic results URL
    /// instead ("search google for X" where "google" is no app). Anything
    /// unmapped or query-less stays an app-search request.
    static func namedEngineSearchURL(engine: String, query: String) -> String? {
        let normalized = engine.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let templates: [String: String] = [
            "google": "https://www.google.com/search?q=",
            "bing": "https://www.bing.com/search?q=",
            "youtube": "https://www.youtube.com/results?search_query=",
            "you tube": "https://www.youtube.com/results?search_query=",
            "github": "https://github.com/search?q=",
            "git hub": "https://github.com/search?q=",
            "amazon": "https://www.amazon.com/s?k=",
            "duckduckgo": "https://duckduckgo.com/?q=",
            "duck duck go": "https://duckduckgo.com/?q="
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let base = templates[normalized], !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else { return nil }
        return base + encoded
    }

    static func explicitBrowserNavigationURL(in goal: String) -> String? {
        if let quoted = quotedSpan(in: goal),
           onlyTrailingPunctuation(goal[goal.index(after: quoted.range.upperBound)...]),
           let url = explicitHTTPURL(in: goal), hasExplicitNavigationVerb(in: goal) {
            return url
        }
        // Spoken form has no quotes: "go to apple.com", "navigate to
        // example.org/docs". The address is the trailing token after the
        // request's last navigation verb.
        return trailingNavigationURL(in: goal)
    }

    private static func explicitHTTPURL(in goal: String) -> String? {
        guard let text = quotedSpan(in: goal)?.text,
              let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return text
    }

    private static func trailingNavigationURL(in goal: String) -> String? {
        guard goal.range(of: #"(?i)\b(?:do\s+not|don't|didn't|never|avoid)\b"#, options: .regularExpression) == nil else { return nil }
        var tailStart: String.Index?
        var verbStart: String.Index?
        var cursor = goal.startIndex
        while let verb = goal.range(of: #"(?i)\b(?:navigate\s+to|visit|go\s+to|open)\s+"#, options: .regularExpression, range: cursor..<goal.endIndex) {
            verbStart = verb.lowerBound
            tailStart = verb.upperBound
            cursor = verb.upperBound
        }
        guard let tailStart else { return nil }
        // A compound request must not half-execute: imperative content
        // before the matched verb ("open the doors and go to X") belongs
        // to a second clause the tool cannot honor — the loop owns it.
        let lead = goal[..<(verbStart ?? tailStart)]
        if lead.range(of: #"(?i)\b(?:open|go\s+to|navigate|visit|search|click|type|press|launch|close|quit|play|find|new\s+tab)\b"#,
                      options: .regularExpression) != nil { return nil }
        let tail = goal[tailStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        // The tail must be the address alone — a trailing clause the tool
        // cannot honor ("in a new tab") or another request ("and search…")
        // means the match is ambiguous and the normal path stays.
        guard let first = tail.split(separator: " ").first,
              tail[first.endIndex...].allSatisfy({ ".!?".contains($0) || $0.isWhitespace }) else { return nil }
        let candidate = String(first).trimmingCharacters(in: CharacterSet(charactersIn: ".!,?;\"'"))
        if candidate.lowercased().hasPrefix("http://") || candidate.lowercased().hasPrefix("https://") {
            return candidate
        }
        // Bare domain (optionally with a path): "apple.com", "developer.apple.com/xcode".
        // Anything without a dot ("google", "the") stays an app or search request.
        guard candidate.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?$"#, options: .regularExpression) != nil else { return nil }
        // A dotted tail is a domain only when its last label is not a file
        // extension — "open report.pdf" means the file, never https://report.pdf.
        if let last = candidate.split(separator: ".").last {
            guard !Self.domainFileExtensions.contains(String(last).lowercased()) else { return nil }
        }
        return "https://" + candidate
    }

    /// Extensions a dotted token is more likely to be — "open report.pdf"
    /// means the file, never https://report.pdf.
    private static let domainFileExtensions: Set<String> = [
        "pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "pages", "numbers", "key",
        "txt", "rtf", "md", "csv", "epub", "jpg", "jpeg", "png", "gif", "heic", "webp",
        "svg", "mp3", "m4a", "wav", "aac", "flac", "ogg", "mp4", "mov", "m4v", "mkv",
        "avi", "webm", "zip", "tar", "gz", "dmg", "pkg", "apk", "ipa", "py", "swift",
        "rb", "js", "ts", "tsx", "jsx", "json", "xml", "yaml", "yml", "html", "css",
        "sql", "sqlite", "db", "log", "scpt", "sketch", "fig", "psd", "indd", "eps",
        "ttf", "otf", "woff", "woff2", "ics", "vcf", "eml", "ipynb", "torrent"
    ]

    /// The first domain-shaped token anywhere in the goal — "open
    /// example.com in Safari" carries its address mid-sentence, where the
    /// navigation-lane parser can't see it. The launch path uses this to
    /// deliver the URL with the app's reopen; it stays narrower than a
    /// free-text scan: http(s) tokens pass through verbatim, bare tokens
    /// must match the full domain grammar and miss the file list.
    static func firstDomainURL(in goal: String) -> String? {
        for raw in goal.split(separator: " ") {
            let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".!,?;\"'()"))
            if token.lowercased().hasPrefix("http://") || token.lowercased().hasPrefix("https://") {
                return token
            }
            guard token.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?$"#, options: .regularExpression) != nil,
                  let last = token.split(separator: ".").last,
                  !domainFileExtensions.contains(String(last).lowercased()) else { continue }
            return "https://" + token
        }
        return nil
    }

    private static func hasExplicitNavigationVerb(in goal: String) -> Bool {
        guard let quoted = quotedSpan(in: goal) else { return false }
        let prefix = goal[..<quoted.opening]
        guard prefix.range(of: #"(?i)\b(?:do\s+not|don't|didn't|never|avoid)\b"#, options: .regularExpression) == nil else { return false }
        return prefix.range(of: #"(?i)\b(?:navigate\s+to|visit|go\s+to|open)\s*$"#, options: .regularExpression) != nil
    }

    private static func onlyTrailingPunctuation(_ text: Substring) -> Bool {
        text.allSatisfy { $0.isWhitespace || ".!?".contains($0) }
    }

    private static func quotedSpan(in source: String) -> (text: String, range: Range<String.Index>, opening: String.Index)? {
        var spans: [(String, Range<String.Index>, String.Index)] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let opening = source[cursor]
            let closing: Character
            switch opening {
            case "\"": closing = "\""
            case "“": closing = "”"
            default:
                cursor = source.index(after: cursor)
                continue
            }
            let start = source.index(after: cursor)
            var end = start
            while end < source.endIndex, source[end] != closing { end = source.index(after: end) }
            guard end < source.endIndex else { return nil }
            spans.append((String(source[start..<end]), start..<end, cursor))
            cursor = source.index(after: end)
        }
        guard spans.count == 1, let (text, range, opening) = spans.first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, range, opening)
    }
}
