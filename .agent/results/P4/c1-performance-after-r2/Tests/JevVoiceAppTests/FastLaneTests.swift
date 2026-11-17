import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: the deterministic verb layer resolves known commands without
/// a model, dispatches once, and verifies the effect from live state.
/// Parse tests are pure; run() tests drive a scripted driver.
final class FastLaneTests: XCTestCase {

    @MainActor
    func testCapturedApplicationResolutionRequiresExactFreshOwner() {
        let current: () -> (bundle: String, pid: Int)? = { ("com.apple.TextEdit", 42) }
        XCTAssertEqual(VoiceTaskCoordinator.capturedForegroundPID(
            application: "com.apple.TextEdit", windowID: 7, frontmost: current,
            focusedWindow: { $0 == 42 ? 7 : nil }), 42)
        for app in [nil, "TextEdit", "com.apple.TextEdit.other", "com.apple.calculator"] as [String?] {
            XCTAssertNil(VoiceTaskCoordinator.capturedForegroundPID(
                application: app, windowID: 7, frontmost: current,
                focusedWindow: { _ in XCTFail("A different app must not borrow focused-window evidence"); return 7 }))
        }
        for window in [nil, 0, -1, 8] as [Int?] {
            XCTAssertNil(VoiceTaskCoordinator.capturedForegroundPID(
                application: "com.apple.TextEdit", windowID: window,
                frontmost: current, focusedWindow: { _ in 7 }))
        }
        XCTAssertNil(VoiceTaskCoordinator.capturedForegroundPID(
            application: "com.apple.TextEdit", windowID: 7, frontmost: { nil },
            focusedWindow: { _ in 7 }))
        XCTAssertNil(VoiceTaskCoordinator.capturedForegroundPID(
            application: "com.apple.TextEdit", windowID: 7,
            frontmost: { ("com.apple.TextEdit", 0) }, focusedWindow: { _ in 7 }))
        XCTAssertNil(VoiceTaskCoordinator.capturedForegroundPID(
            application: "com.apple.TextEdit", windowID: 7, frontmost: current,
            focusedWindow: { _ in nil }))
    }

    func testCanonicalBundleQualifierResolvesWhenVoiceHUDOwnsFrontmost() {
        let editor = appRow("TextEdit", "com.apple.TextEdit", pid: 42)
        for frontmost in [nil, "com.chriswozniczek.jevvoice", "fixture.other"] {
            let result = DriveLoop.resolveFastLane(goal: "type hello Jarvis", apps: [editor],
                appHint: "com.apple.TextEdit", frontmostBundle: frontmost)
            XCTAssertEqual(result?.bundle, "com.apple.TextEdit")
            guard case .type("hello Jarvis") = result?.action?.body else {
                XCTFail("A canonical captured app must resolve without a display-name guess")
                continue
            }
        }
    }

    func testCanonicalBundleQualifierIsExactAndRejectsDuplicateIdentities() throws {
        let action = try XCTUnwrap(FastAction.parse("type fixture")).action
        let editor = appRow("TextEdit", "com.apple.TextEdit", pid: 42)
        XCTAssertEqual(FastAction.resolveApp(qualifier: "COM.APPLE.TEXTEDIT", action: action,
            apps: [editor], frontmostBundle: nil)?.bundle, "com.apple.TextEdit")
        XCTAssertNil(FastAction.resolveApp(qualifier: "com.apple.TextEdit", action: action,
            apps: [editor, editor], frontmostBundle: nil))
        XCTAssertNil(FastAction.resolveApp(qualifier: "com.apple.TextEdit.other", action: action,
            apps: [editor], frontmostBundle: nil))
    }

    // MARK: - Parse contracts

    func testFullyQuotedTypePreservesPayloadBytes() {
        for payload in [" Jev audit alpha", "Jev audit alpha ", " \tCase, punctuation!\t ",
                        "\"inner quotes\"", "'inner quotes'", " "] {
            guard let parsed = FastAction.parse("type \"\(payload)\""),
                  case .type(let actual) = parsed.action.body else {
                XCTFail("nonempty quoted literal must parse"); continue
            }
            XCTAssertEqual(actual, payload)
            XCTAssertNil(parsed.appQualifier)
            XCTAssertFalse(parsed.action.deictic)
        }
        guard let unquoted = FastAction.parse("type   Plain text   "),
              case .type(let normalized) = unquoted.action.body else {
            return XCTFail("unquoted type must retain its existing parse")
        }
        XCTAssertEqual(normalized, "Plain text")
        XCTAssertNil(FastAction.parse("type "))
        // The existing quote recognizer treats an empty quote pair as two
        // literal quote characters; this exception does not change that rule.
        guard let pair = FastAction.parse("type \"\""), case .type(let quotes) = pair.action.body else {
            return XCTFail("existing empty-pair spelling must remain unchanged")
        }
        XCTAssertEqual(quotes, "\"\"")
    }

    /// Whole-phrase chords parse to their keys — "open a new tab" is a
    /// keystroke command, never an app launch.
    func testTableChordsParse() {
        guard let newTab = FastAction.parse("new tab") else {
            return XCTFail("new tab should parse")
        }
        if case .hotkey(let keys, _) = newTab.action.body {
            XCTAssertEqual(keys, ["cmd", "t"])
        } else { XCTFail("expected hotkey, got \(newTab.action.body)") }

        guard let openTab = FastAction.parse("open a new tab") else {
            return XCTFail("'open a new tab' must hit the table, not open-verb")
        }
        if case .hotkey(let keys, _) = openTab.action.body {
            XCTAssertEqual(keys, ["cmd", "t"])
        } else { XCTFail("expected hotkey, got \(openTab.action.body)") }
        // The table wins in resolveFastLane — parseOpen is only consulted
        // after a table miss, so the utterance is never an app launch.
        let chrome = appRow("Google Chrome", "com.google.Chrome", pid: 7)
        let resolved = DriveLoop.resolveFastLane(goal: "open a new tab",
                                                 apps: [chrome], frontmostBundle: nil)
        XCTAssertNil(resolved?.openVerb, "table owns 'open a new tab' before the open verb sees it")

        guard let enter = FastAction.parse("press enter") else {
            return XCTFail("press enter should parse")
        }
        if case .hotkey(let keys, _) = enter.action.body {
            XCTAssertEqual(keys, ["return"])
        } else { XCTFail("expected hotkey") }

        guard let scroll = FastAction.parse("scroll down 3 times") else {
            return XCTFail("counted scroll should parse")
        }
        if case .scroll(let dir, let pages) = scroll.action.body {
            XCTAssertEqual(dir, "down")
            XCTAssertEqual(pages, 3)
        } else { XCTFail("expected scroll, got \(scroll.action.body)") }
    }

    /// Media keys are whole-utterance global events — no app qualifier.
    func testMediaKeysParse() {
        guard let pause = FastAction.parse("pause") else {
            return XCTFail("pause should parse")
        }
        guard case .mediaKey(.playPause) = pause.action.body else {
            return XCTFail("expected play/pause key, got \(pause.action.body)")
        }
        XCTAssertNil(pause.appQualifier)
    }

    /// "play it"/"play the song" are resume phrases, not searches.
    func testPlayPronounIsMediaKey() {
        guard let parsed = FastAction.parse("play it") else {
            return XCTFail("'play it' should parse")
        }
        guard case .mediaKey = parsed.action.body else {
            return XCTFail("'play it' is resume, not a search — got \(parsed.action.body)")
        }
    }

    /// A named song is the search lane, not the media key.
    func testPlayNamedQueryIsSearch() {
        guard let parsed = FastAction.parse("play bohemian rhapsody") else {
            return XCTFail("'play <song>' should parse")
        }
        guard case .appSearch(let query, let play) = parsed.action.body else {
            return XCTFail("expected appSearch, got \(parsed.action.body)")
        }
        XCTAssertEqual(query, "bohemian rhapsody")
        XCTAssertTrue(play)
    }

    /// Typed payloads keep case and punctuation verbatim.
    func testTypeLanePreservesPayload() {
        guard let parsed = FastAction.parse("type Hello, World") else {
            return XCTFail("type should parse")
        }
        guard case .type(let payload) = parsed.action.body else {
            return XCTFail("expected type, got \(parsed.action.body)")
        }
        XCTAssertEqual(payload, "Hello, World")
    }

    /// A negated command must never hit the fast lane.
    func testNegationBlocksTheLane() {
        XCTAssertNil(FastAction.parse("don't open a new tab"))
        XCTAssertNil(FastAction.parse("never new tab"))
        XCTAssertNil(FastAction.parseOpen("don't open notes"))
    }

    /// Verb-first app control parses the app name as the qualifier.
    func testAppControlParse() {
        guard let hide = FastAction.parse("hide calculator") else {
            return XCTFail("hide <app> should parse")
        }
        guard case .appControl(.hide) = hide.action.body else {
            return XCTFail("expected hide, got \(hide.action.body)")
        }
        XCTAssertEqual(hide.appQualifier, "calculator")

        guard let min = FastAction.parse("minimize the notes window") else {
            return XCTFail("minimize <app> window should parse")
        }
        guard case .appControl(.minimize) = min.action.body else {
            return XCTFail("expected minimize, got \(min.action.body)")
        }
        XCTAssertEqual(min.appQualifier, "notes")

        // "minimize the window" stays a frontmost ⌘M — no app qualifier.
        guard let frontmost = FastAction.parse("minimize the window") else {
            return XCTFail("minimize the window should parse")
        }
        if case .hotkey(let keys, _) = frontmost.action.body {
            XCTAssertEqual(keys, ["cmd", "m"])
        } else { XCTFail("expected ⌘M hotkey, got \(frontmost.action.body)") }
        XCTAssertNil(frontmost.appQualifier)
    }

    /// "minimize this" names the window under the user's eyes — the
    /// pronoun marks the action deictic so the executor binds the gazed
    /// window instead of the frontmost app's focused one.
    func testDeicticWindowVerbsMarkGazeBinding() {
        let deicticMinimize = ["minimize this", "minimize it", "minimize this window",
                               "minimise this", "minimise it"]
        for phrase in deicticMinimize {
            guard let parsed = FastAction.parse(phrase) else {
                return XCTFail("'\(phrase)' should parse")
            }
            XCTAssertTrue(parsed.action.deictic, "'\(phrase)' must mark deictic")
        }
        // Bare and definite-article forms keep the frontmost meaning.
        for phrase in ["minimize", "minimize the window", "minimize the app",
                       "minimize everything", "minimize all windows"] {
            guard let parsed = FastAction.parse(phrase) else {
                return XCTFail("'\(phrase)' should parse")
            }
            XCTAssertFalse(parsed.action.deictic, "'\(phrase)' must not mark deictic")
        }
    }

    /// The same pronoun on close/hide lands the same binding; "hide this"
    /// now parses instead of falling to the loop.
    func testDeicticCloseAndHideMark() {
        for phrase in ["close this", "close it", "close this window", "close this tab",
                       "hide this", "hide it", "hide this app"] {
            guard let parsed = FastAction.parse(phrase) else {
                return XCTFail("'\(phrase)' should parse")
            }
            XCTAssertTrue(parsed.action.deictic, "'\(phrase)' must mark deictic")
        }
        for phrase in ["close the window", "close window", "close tab",
                       "hide", "hide the app", "hide others"] {
            guard let parsed = FastAction.parse(phrase) else {
                return XCTFail("'\(phrase)' should parse")
            }
            XCTAssertFalse(parsed.action.deictic, "'\(phrase)' must not mark deictic")
        }
    }

    /// A deictic token on a NON-window verb stays frontmost — "cut this"
    /// and "make it fullscreen" keep their focused-target meaning.
    func testDeicticTokenDoesNotRetargetEditing() {
        for phrase in ["cut this", "copy this", "paste that", "undo this",
                       "make it fullscreen", "make this fullscreen"] {
            guard let parsed = FastAction.parse(phrase) else {
                return XCTFail("'\(phrase)' should parse")
            }
            XCTAssertFalse(parsed.action.deictic, "'\(phrase)' must not mark deictic")
        }
    }

    /// The executor maps only window-level effects to a deictic control —
    /// the same effect gate the parser used to mark the action.
    func testDeicticWindowControlMapping() {
        func control(_ phrase: String) -> DriveLoop.DeicticWindowControl? {
            guard let parsed = FastAction.parse(phrase) else { return nil }
            return DriveLoop.deicticWindowControl(for: parsed.action)
        }
        guard case .minimize? = control("minimize this") else {
            return XCTFail("minimize this → .minimize")
        }
        guard case .close? = control("close it") else {
            return XCTFail("close it → .close")
        }
        guard case .hideApp? = control("hide this app") else {
            return XCTFail("hide this app → .hideApp")
        }
        XCTAssertNil(control("press enter"))
        XCTAssertNil(control("new window"))
        // "minimize everything" shares .windowOffScreen so the mapping
        // exists, but its action never carries the deictic flag — the
        // executor's gate is the pair, and the flag tests cover it.
        guard case .minimize? = control("minimize everything") else {
            return XCTFail("the effect maps; the flag is what withholds it")
        }
    }

    // MARK: - Open verbs

    func testParseOpenVerbs() {
        XCTAssertEqual(FastAction.parseOpen("open notes")?.verb, "open")
        XCTAssertEqual(FastAction.parseOpen("open notes")?.query, "notes")
        XCTAssertEqual(FastAction.parseOpen("bring messages to the front")?.verb, "bring")
        XCTAssertEqual(FastAction.parseOpen("bring messages to the front")?.query, "messages")
        XCTAssertEqual(FastAction.parseOpen("bring up notes")?.verb, "bring up")
        XCTAssertNil(FastAction.parseOpen("check something"))
    }

    /// Raise verbs demand a verified front window; launch verbs don't.
    func testOpenRequiresRaise() {
        XCTAssertFalse(FastAction.openRequiresRaise(goal: "open notes"))
        XCTAssertFalse(FastAction.openRequiresRaise(goal: "launch notes"))
        XCTAssertTrue(FastAction.openRequiresRaise(goal: "bring notes to the front"))
        XCTAssertTrue(FastAction.openRequiresRaise(goal: "switch to notes"))
    }

    // MARK: - App resolution

    private func appRow(_ name: String, _ bundle: String, pid: Int? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["name": .string(name), "bundle_id": .string(bundle)]
        if let pid { row["pid"] = .number(Double(pid)) }
        return .object(row)
    }

    /// "the notes app" resolves by display name; "it" names the frontmost app.
    func testResolveOpenApp() {
        let notes = appRow("Notes", "com.apple.Notes", pid: 42)
        let resolved = FastAction.resolveOpenApp(query: "the notes app",
                                                 apps: [notes], frontmostBundle: nil)
        XCTAssertEqual(resolved?.bundle, "com.apple.Notes")

        let pronoun = FastAction.resolveOpenApp(query: "it",
                                                apps: [notes], frontmostBundle: "com.apple.Notes")
        XCTAssertEqual(pronoun?.bundle, "com.apple.Notes")
    }

    /// "google" resolves to Google Chrome by substring — the user's "open
    /// google" failure. An ambiguous substring stays unresolved.
    func testGoogleResolvesToChrome() {
        let chrome = appRow("Google Chrome", "com.google.Chrome", pid: 7)
        let safari = appRow("Safari", "com.apple.Safari", pid: 8)
        let resolved = FastAction.resolveOpenApp(query: "google",
                                                 apps: [chrome, safari], frontmostBundle: nil)
        XCTAssertEqual(resolved?.bundle, "com.google.Chrome")
    }

    // MARK: - resolveFastLane end-to-end

    /// "open notes" resolves to the open verb against a resolved app.
    func testResolveFastLaneOpen() {
        let apps = [appRow("Notes", "com.apple.Notes", pid: 42)]
        let r = DriveLoop.resolveFastLane(goal: "open Notes", apps: apps,
                                          frontmostBundle: nil)
        XCTAssertEqual(r?.openVerb, "open")
        XCTAssertEqual(r?.bundle, "com.apple.Notes")
        XCTAssertEqual(r?.pid, 42)
    }

    /// "search google for X" is a navigation URL — never web_lookup and
    /// never an app named "Google Chrome".
    func testResolveFastLaneEngineSearch() {
        let apps = [appRow("Google Chrome", "com.google.Chrome", pid: 7)]
        let r = DriveLoop.resolveFastLane(goal: "search google for dogs",
                                          apps: apps, frontmostBundle: nil)
        guard case .navigateURL(let url)? = r?.action?.body else {
            return XCTFail("expected navigateURL, got \(String(describing: r?.action?.body))")
        }
        XCTAssertTrue(url.hasPrefix("https://www.google.com/search?q="))
        XCTAssertTrue(url.contains("dogs"))
    }

    /// Bare "search for X" / "search X" is a web search in a fresh tab —
    /// never launch_app(name: the whole phrase). The qualified forms keep
    /// their lanes: "search spotify for X" stays in-app, "search google
    /// for X" stays an engine navigation.
    func testResolveFastLaneBareSearch() {
        for goal in ["search for cute dogs", "search cute dogs"] {
            let r = DriveLoop.resolveFastLane(goal: goal, apps: [], frontmostBundle: nil)
            guard case .webSearch(let url)? = r?.action?.body else {
                return XCTFail("'\(goal)' must resolve webSearch, got \(String(describing: r?.action?.body))")
            }
            XCTAssertTrue(url.hasPrefix("https://www.google.com/search?q="), goal)
            XCTAssertTrue(url.contains("cute%20dogs"), goal)
        }
        // Qualified forms are untouched by the bare lane.
        let chrome = appRow("Google Chrome", "com.google.Chrome", pid: 7)
        let spotify = appRow("Spotify", "com.spotify.client", pid: 9)
        let engine = DriveLoop.resolveFastLane(goal: "search google for dogs",
                                               apps: [chrome], frontmostBundle: nil)
        guard case .navigateURL? = engine?.action?.body else {
            return XCTFail("qualified engine search must keep its navigateURL lane")
        }
        let inApp = DriveLoop.resolveFastLane(goal: "search spotify for drake",
                                              apps: [spotify], frontmostBundle: nil)
        guard case .appSearch(let query, _)? = inApp?.action?.body, query == "drake" else {
            return XCTFail("'search spotify for drake' must keep the in-app search lane")
        }
        // An unresolved qualifier falls through to the web lane honestly:
        // "search <nothing-installed> for X" googles the tail, not an app guess.
        let nobody = DriveLoop.resolveFastLane(goal: "search nothingreal for stuff",
                                               apps: [], frontmostBundle: nil)
        guard case .webSearch(let url)? = nobody?.action?.body else {
            return XCTFail("unresolved qualifier must fall through to web search")
        }
        XCTAssertTrue(url.contains("nothingreal%20for%20stuff"), url)
    }

    /// "go to apple.com" resolves to navigation, not an app named "apple.com".
    func testResolveFastLaneNavigation() {
        let r = DriveLoop.resolveFastLane(goal: "go to apple.com", apps: [],
                                          frontmostBundle: nil)
        guard case .navigateURL(let url)? = r?.action?.body else {
            return XCTFail("expected navigateURL, got \(String(describing: r?.action?.body))")
        }
        XCTAssertEqual(url, "https://apple.com")
        XCTAssertNil(FastAction.resolveOpenApp(query: "apple.com", apps: [],
                                               frontmostBundle: nil),
                     "a bare domain is never an app name")
    }

    /// "new tab" resolves against the uniquely-running tabbable app.
    /// Two running browsers are ambiguous → nil → the drive loop owns it.
    func testResolveFastLaneNewTabAmbiguity() {
        let chrome = appRow("Google Chrome", "com.google.Chrome", pid: 7)
        let one = DriveLoop.resolveFastLane(goal: "new tab", apps: [chrome],
                                            frontmostBundle: nil)
        XCTAssertEqual(one?.bundle, "com.google.Chrome")

        let safari = appRow("Safari", "com.apple.Safari", pid: 8)
        let ambiguous = DriveLoop.resolveFastLane(goal: "new tab",
                                                  apps: [chrome, safari],
                                                  frontmostBundle: nil)
        XCTAssertNil(ambiguous, "two running browsers must not be guessed at")
    }

    /// Bare "quit" is not a whole-phrase lane — the drive loop judges it.
    /// "quit notes" resolves as an app control with self-approval.
    func testResolveFastLaneQuit() {
        let apps = [appRow("Notes", "com.apple.Notes", pid: 42)]
        XCTAssertNil(DriveLoop.resolveFastLane(goal: "quit", apps: apps,
                                               frontmostBundle: nil))
        let r = DriveLoop.resolveFastLane(goal: "quit notes", apps: apps,
                                          frontmostBundle: nil)
        guard case .appControl(.quit)? = r?.action?.body else {
            return XCTFail("expected quit, got \(String(describing: r?.action?.body))")
        }
        XCTAssertEqual(r?.bundle, "com.apple.Notes")
    }

    /// Spoken packaging around the app name is not the name: "close my
    /// google browser" must still resolve to Chrome's quit — a miss here
    /// demotes a plain app control to the generic loop, which launched the
    /// app instead of quitting it (observed failure 2026-10-11).
    func testResolveFastLaneCloseWithPackaging() {
        let apps = [appRow("Google Chrome", "com.google.Chrome", pid: 7)]
        for goal in ["close my google", "close my google browser",
                     "close the chrome browser"] {
            let r = DriveLoop.resolveFastLane(goal: goal, apps: apps,
                                              frontmostBundle: nil)
            guard case .appControl(.quit)? = r?.action?.body else {
                return XCTFail("'\(goal)' should lane as quit, got \(String(describing: r?.action?.body))")
            }
            XCTAssertEqual(r?.bundle, "com.google.Chrome", goal)
        }
    }

    /// "pause" needs no app at all — it resolves app-free.
    func testResolveFastLaneMediaKey() {
        let r = DriveLoop.resolveFastLane(goal: "pause", apps: [],
                                          frontmostBundle: nil)
        guard case .mediaKey(.playPause)? = r?.action?.body else {
            return XCTFail("expected play/pause, got \(String(describing: r?.action?.body))")
        }
        XCTAssertEqual(r?.bundle, "")
    }

    // MARK: - run() integration — the real dispatch paths

    /// A scripted driver for fast-lane runs — same shape as DriveLoopTests.
    private final class FakeDriver {
        var calls: [(tool: String, args: [String: JSONValue])] = []
        var responses: [String: [JSONValue]] = [:]
        var snapshotForRound: (Int) -> JSONValue = { _ in .object(["elements": .array([])]) }
        private var round = 0

        func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
            calls.append((tool, args))
            if tool == "get_window_state" {
                defer { round += 1 }
                return snapshotForRound(round)
            }
            if var queue = responses[tool], !queue.isEmpty {
                let first = queue.removeFirst()
                responses[tool] = queue
                return first
            }
            return .object(["effect": .string("confirmed")])
        }
    }

    private func windows(_ ids: [Int]) -> JSONValue {
        .object(["windows": .array(ids.map { id in
            .object(["window_id": .number(Double(id)),
                     "title": .string("W\(id)"),
                     "is_on_screen": .bool(true)])
        })])
    }

    private func apps(_ rows: [JSONValue]) -> JSONValue {
        .object(["apps": .array(rows)])
    }

    /// "Open Notes" on a running Notes: launch skipped, the raise is the
    /// verified effect — zero model calls.
    func testOpenRunningAppRaisesWindow() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        driver.responses["list_windows"] = [windows([7])]
        driver.responses["bring_to_front"] = [
            .object(["activated": .bool(true),
                     "exact_window_effect": .object(["verified": .bool(true)])])
        ]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "open Notes"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(result.pid, 42)
        XCTAssertEqual(driver.calls.map(\.tool),
                       ["list_apps", "list_windows", "bring_to_front"])
    }

    func testCanonicalOpenSkipsUnrelatedAppInventory() async {
        let driver = FakeDriver()
        driver.responses["list_windows"] = [windows([7])]
        driver.responses["bring_to_front"] = [.object([
            "activated": .bool(true), "exact_window_effect": .object(["verified": .bool(true)])
        ])]
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in XCTFail("canonical open needs no model"); return nil },
            ask: nil, granted: { true },
            resolver: AppResolver(listApps: {
                [AppResolver.App(name: "Calculator", bundle: "com.apple.calculator", pid: 42)]
            }))
        let task = await VoiceTaskCoordinator.voiceTaskSpec("show Calculator", app: "com.apple.calculator")
        XCTAssertEqual(task.scope, .work)
        let result = await loop.run(task, session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertFalse(driver.calls.contains { $0.tool == "list_apps" })
        XCTAssertEqual(driver.calls.filter { $0.tool == "bring_to_front" }.count, 1)
    }

    func testCapturedAppCannotBeReplacedByFreshAliasMatch() async {
        var mutations: [String] = []
        let loop = DriveLoop(call: { tool, _ in
            if tool == "list_apps" {
                return .object(["apps": .array([.object([
                    "name": .string("Google Chrome"),
                    "bundle_id": .string("fixture.other.chrome"), "pid": .number(43)
                ])])])
            }
            if tool != "list_windows" { mutations.append(tool) }
            return self.windows([7])
        }, choose: { _, _ in XCTFail("missing captured app must not reach a model"); return nil },
        ask: nil, granted: { true }, resolver: AppResolver(listApps: { [] }),
        appIsHidden: { _ in false }, activateRestoredApp: { _, _ in mutations.append("host_reopen") })
        for goal in ["show Chrome", "focus Chrome", "bring Google to the front"] {
            let task = await VoiceTaskCoordinator.voiceTaskSpec(goal, app: "fixture.captured.chrome")
            XCTAssertEqual(task.scope, .work, "exercise the real coordinator classification")
            let result = await loop.run(task, session: "t")
            guard case .blocked = result.status else {
                return XCTFail("must not replace a disappeared captured app with another alias match")
            }
        }
        XCTAssertTrue(mutations.isEmpty, "no action is allowed on the replacement identity")
    }

    func testForegroundOpenActivatesBeforeWindowEnumeration() async {
        var activated = false
        let loop = DriveLoop(call: { tool, _ in
            switch tool {
            case "list_windows": return self.windows(activated ? [7] : [])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                    "exact_window_effect": .object(["verified": .bool(true)])])
            default: return .object([:])
            }
        }, choose: { _, _ in XCTFail("foreground open needs no model"); return nil },
        ask: nil, granted: { true }, resolver: AppResolver(listApps: {
            [AppResolver.App(name: "Calculator", bundle: "com.apple.calculator", pid: 42)]
        }), appIsHidden: { _ in false }, activateRestoredApp: { _, bundle in
            XCTAssertEqual(bundle, "com.apple.calculator"); activated = true
        })
        let result = await loop.run(DriveTask(goal: "open Calculator",
            application: "com.apple.calculator", scope: .open, foreground: true), session: "t")
        XCTAssertTrue(activated)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.windowID, 7)
    }

    func testDisplayNameOpenStillUsesInventory() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Calculator", "com.apple.calculator", pid: 42)])]
        driver.responses["list_windows"] = [windows([7])]
        driver.responses["bring_to_front"] = [.object([
            "activated": .bool(true), "exact_window_effect": .object(["verified": .bool(true)])
        ])]
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in nil }, ask: nil, granted: { true },
            resolver: AppResolver(listApps: {
                [AppResolver.App(name: "Calculator", bundle: "com.apple.calculator", pid: 42)]
            }))
        let result = await loop.run(DriveTask(goal: "show Calculator",
            application: "Calculator", scope: .open), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(driver.calls.contains { $0.tool == "list_apps" })
    }

    /// The physical P3 trial hides Calculator before "show Calculator".
    /// Without a real unhide, window reads stay empty and the command
    /// incorrectly blocks, even though its target app is already running.
    func testShowHiddenRunningAppRestoresWindowBeforeRaising() async {
        var hidden = true
        var unhideCount = 0
        var activationCount = 0
        var calls: [String] = []
        let stages = LockedBox<[String]>([])
        let loop = DriveLoop(call: { tool, _ in
            calls.append(tool)
            switch tool {
            case "list_apps":
                return self.apps([self.appRow("Calculator", "com.apple.calculator", pid: 42)])
            case "list_windows":
                return self.windows(hidden ? [] : [7])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                    "exact_window_effect": .object(["verified": .bool(true)])])
            default:
                return .object([:])
            }
        }, choose: { _, _ in nil }, ask: nil, granted: { true },
        nativeEvent: { stage in stages.set(stages.value + [stage.rawValue]) },
        activateApp: { _ in },
        appIsHidden: { _ in hidden },
        unhideApp: { _ in
            unhideCount += 1; hidden = false
            return false // AppKit may report false even when the app unhides.
        },
        activateRestoredApp: { _, bundle in
            XCTAssertEqual(bundle, "com.apple.calculator"); activationCount += 1
        })
        let result = await loop.run(DriveTask(goal: "show Calculator"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(unhideCount, 1)
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(stages.value.filter { $0 == "nativeUnhideBegin" }.count, 1)
        XCTAssertEqual(stages.value.filter { $0 == "nativeUnhideEnd" }.count, 1)
        XCTAssertEqual(stages.value.filter { $0 == "nativeActivationBegin" }.count, 1)
        XCTAssertLessThan(stages.value.firstIndex(of: "nativeUnhideBegin") ?? Int.max,
                          stages.value.firstIndex(of: "nativeActivationBegin") ?? 0)
        XCTAssertTrue(calls.contains("bring_to_front"))
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(result.windowID, 7)
    }

    func testHiddenRaiseRefusesWhenUnhideFails() async {
        var calls: [String] = []
        let loop = DriveLoop(call: { tool, _ in
            calls.append(tool)
            return tool == "list_apps"
                ? self.apps([self.appRow("Calculator", "com.apple.calculator", pid: 42)])
                : self.windows([])
        }, choose: { _, _ in nil }, ask: nil, granted: { true },
        appIsHidden: { _ in true }, unhideApp: { _ in false },
        activateRestoredApp: { _, _ in XCTFail("must not activate when unhide fails") })
        let result = await loop.run(DriveTask(goal: "show Calculator"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("an unverified restoration must block, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("hidden"), reason)
        XCTAssertFalse(calls.contains("bring_to_front"))
    }

    func testPinnedHiddenRaiseDoesNotUnhideAnotherWindow() async {
        var unhideCount = 0
        let loop = DriveLoop(call: { tool, _ in
            switch tool {
            case "list_apps":
                return self.apps([self.appRow("Calculator", "com.apple.calculator", pid: 42)])
            case "list_windows": return self.windows([8])
            default: return .object([:])
            }
        }, choose: { _, _ in nil }, ask: nil, granted: { true },
        appIsHidden: { _ in true },
        unhideApp: { _ in unhideCount += 1; return true },
        activateRestoredApp: { _, _ in XCTFail("must not activate a stale pinned target") })
        let result = await loop.run(
            DriveTask(goal: "show Calculator", windowID: 7), session: "t")
        guard case .blocked = result.status else {
            return XCTFail("a stale pinned target must remain blocked")
        }
        XCTAssertEqual(unhideCount, 0)
    }

    /// A driver "effect unknown" on bring_to_front can mean it already
    /// happened. Never send a second mutation: require an independent
    /// frontmost PID and the exact on-screen window before reporting done.
    func testUncertainRaiseVerifiesExactWindowWithoutRetry() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Calculator", "com.apple.calculator", pid: 42)])]
        driver.responses["list_windows"] = [windows([7]), windows([7])]
        let loop = DriveLoop(call: { tool, args in
            if tool == "bring_to_front" {
                driver.calls.append((tool, args))
                throw CuaUncertainOutcome(tool: tool, result: .object(["effect": .string("unknown")]))
            }
            return try driver.call(tool, args)
        }, choose: { _, _ in nil }, ask: nil, granted: { true },
        frontmostPID: { 42 }, frontmostWindowID: { 7 })
        let result = await loop.run(DriveTask(goal: "show Calculator"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(result.windowID, 7)
        XCTAssertEqual(driver.calls.filter { $0.tool == "bring_to_front" }.count, 1,
                       "an uncertain mutation must not be sent twice")
    }

    func testUncertainRaiseWithoutVisibleExactWindowStaysBlocked() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Calculator", "com.apple.calculator", pid: 42)])]
        driver.responses["list_windows"] = [windows([7])]
        let loop = DriveLoop(call: { tool, args in
            if tool == "bring_to_front" {
                driver.calls.append((tool, args))
                throw CuaUncertainOutcome(tool: tool, result: .object(["effect": .string("unknown")]))
            }
            return try driver.call(tool, args)
        }, choose: { _, _ in nil }, ask: nil, granted: { true },
        frontmostPID: { nil })
        let result = await loop.run(DriveTask(goal: "show Calculator"), session: "t")
        guard case .blocked = result.status else {
            return XCTFail("no independent frontmost PID must remain blocked")
        }
        XCTAssertFalse(result.dispatchedEffect)
        XCTAssertEqual(driver.calls.filter { $0.tool == "bring_to_front" }.count, 1)
    }

    func testUncertainRaiseCannotUseOtherWindowOrMissingVisibility() async {
        for frontWindow in [7, 8] {
            let driver = FakeDriver()
            driver.responses["list_apps"] = [apps([appRow("Calculator", "com.apple.calculator", pid: 42)])]
            let row: JSONValue = frontWindow == 7
                ? .object(["window_id": .number(7)]) // Missing visibility is not proof.
                : .object(["window_id": .number(7), "is_on_screen": .bool(true)])
            driver.responses["list_windows"] = [windows([7])] + Array(
                repeating: .object(["windows": .array([row])]), count: 12)
            let loop = DriveLoop(call: { tool, args in
                if tool == "bring_to_front" {
                    driver.calls.append((tool, args))
                    throw CuaUncertainOutcome(tool: tool, result: .object([:]))
                }
                return try driver.call(tool, args)
            }, choose: { _, _ in nil }, ask: nil, granted: { true },
            frontmostPID: { 42 }, frontmostWindowID: { frontWindow })
            let result = await loop.run(DriveTask(goal: "show Calculator"), session: "t")
            guard case .blocked = result.status else {
                return XCTFail("same process alone or unknown visibility must not verify a raise")
            }
            XCTAssertEqual(driver.calls.filter { $0.tool == "bring_to_front" }.count, 1)
        }
    }

    /// A cold launch materializes no window on the first reads — the poll
    /// catches it materializing, then the raise verifies. This is the
    /// "Open Notes" regression the user hit, fixed.
    func testColdLaunchWaitsForWindow() async {
        let driver = FakeDriver()
        let fixtureBundle = "invalid.jevvoice.fixture.cold-notes"
        driver.responses["list_apps"] = [apps([appRow("Notes", fixtureBundle)])]
        driver.responses["launch_app"] = [
            .object(["pid": .number(99),
                     "bundle_id": .string(fixtureBundle),
                     "windows": .array([])])
        ]
        driver.responses["list_windows"] = [
            .object(["windows": .array([])]),
            .object(["windows": .array([])]),
            windows([5]),
        ]
        driver.responses["bring_to_front"] = [
            .object(["activated": .bool(true),
                     "exact_window_effect": .object(["verified": .bool(true)])])
        ]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             resolver: AppResolver(listApps: { [] }),
                             activateApp: { _ in })
        let result = await loop.run(DriveTask(goal: "open Notes"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.pid, 99)
        XCTAssertEqual(result.windowID, 5)
        let tools = driver.calls.map(\.tool)
        XCTAssertTrue(tools.contains("launch_app"))
        XCTAssertTrue(tools.contains("bring_to_front"),
                      "the raise must be dispatched — not just a window wait")
    }

    /// A launch that never materializes a window still reports honestly:
    /// the app ran, the open happened, no window claimed.
    func testWindowlessLaunchSettlesHonestly() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes")])]
        driver.responses["launch_app"] = [
            .object(["pid": .number(98),
                     "bundle_id": .string("com.apple.Notes"),
                     "windows": .array([])])
        ]
        driver.responses["list_windows"] = Array(
            repeating: .object(["windows": .array([])]), count: 20)
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             activateApp: { _ in })
        let result = await loop.run(DriveTask(goal: "open Notes"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertNil(result.windowID, "no window is claimed when none materialized")
    }

    /// A raise verb with no materializable window blocks — "brought Notes
    /// forward" can never be claimed without a verified window.
    func testRaiseVerbWithoutWindowBlocks() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        driver.responses["list_windows"] = Array(
            repeating: .object(["windows": .array([])]), count: 30)
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             activateApp: { _ in })
        let result = await loop.run(DriveTask(goal: "bring Notes to the front"),
                                    session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
    }

    /// A declined quit asks once and stops — terminate never fires.
    func testQuitAsksOnceAndDeclines() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        var asked: [DriveLoop.Ask] = []
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil },
                             ask: { ask in asked.append(ask); return "no" },
                             granted: { false })
        let result = await loop.run(DriveTask(goal: "quit Notes"), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertEqual(asked.count, 1)
    }

    /// The standing grant covers quit — "always allow computer use" means
    /// exactly that, so the confirm card must not park the task on a consent
    /// the user already gave. The ask never fires; the run proceeds to the
    /// terminate attempt itself, which here refuses honestly on the dead
    /// pid (99999 can't be a real process).
    func testQuitWithStandingGrantDoesNotAsk() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 99999)])]
        var asked: [DriveLoop.Ask] = []
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil },
                             ask: { ask in asked.append(ask); return "no" },
                             granted: { true })
        let result = await loop.run(DriveTask(goal: "quit Notes"), session: "t")
        XCTAssertTrue(asked.isEmpty, "standing grant must skip the quit confirm")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked on the dead process, got \(result.status)")
        }
    }

    /// The media lane posts the system key and settles — no window, no app.
    func testMediaKeyPostsAndSettles() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        var posted: [MediaKeys.Key] = []
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             postMediaKey: { key in posted.append(key); return true })
        let result = await loop.run(DriveTask(goal: "pause"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(posted, [.playPause])
        XCTAssertEqual(driver.calls.map(\.tool), [],
                       "a global key never touches the app inventory at all")
    }

    /// "new tab" dispatches ⌘T and verifies the tab strip gained one.
    func testNewTabVerifiesTabDelta() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Google Chrome", "com.google.Chrome", pid: 7)])]
        driver.responses["list_windows"] = [windows([3])]
        var round = 0
        driver.snapshotForRound = { _ in
            defer { round += 1 }
            let tabs = round == 0 ? 2 : 3
            return .object(["elements": .array((0..<tabs).map { i in
                .object(["element_index": .number(Double(i)),
                         "role": .string("AXRadioButton"),
                         "label": .string("Tab \(i)"),
                         "element_token": .string("t\(i)"),
                         "selected": .bool(i == 0)])
            })])
        }
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "new tab", application: "com.google.Chrome", pid: 7, windowID: 3),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        let hotkey = driver.calls.first { $0.tool == "hotkey" }
        XCTAssertEqual(hotkey?.args["keys"]?.array?.compactMap(\.string), ["cmd", "t"])
    }

    /// "type hello" types into the window's sole editable element and
    /// verifies the value held it.
    func testTypeVerifiesValueHeld() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        driver.responses["list_windows"] = [windows([7])]
        var round = 0
        driver.snapshotForRound = { _ in
            defer { round += 1 }
            let value: JSONValue = round == 0 ? .null : .string("hello")
            return .object(["elements": .array([
                .object(["element_index": .number(5),
                         "role": .string("AXTextField"),
                         "label": .string("Note"),
                         "element_token": .string("tok5"),
                         "value": value,
                         "enabled": .bool(true)])
            ])])
        }
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(
            DriveTask(goal: "type hello", application: "Notes",
                      pid: 42, windowID: 7),
            session: "t")
        XCTAssertEqual(result.status, .done)
        let typed = driver.calls.first { $0.tool == "type_text" }
        XCTAssertEqual(typed?.args["text"]?.string, "hello")
        XCTAssertEqual(typed?.args["element_token"]?.string, "tok5")
    }
}

/// The expanded fast-lane surface: trailing-filler stripping, the
/// display-scope peel, nickname resolution, close/edit/system chords,
/// tab indexes, menu paths, snaps, overlay picks, repeat and locate.
final class FastLaneParseTests: XCTestCase {

    private func appRow(_ name: String, _ bundle: String, pid: Int? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["name": .string(name), "bundle_id": .string(bundle)]
        if let pid { row["pid"] = .number(Double(pid)) }
        return .object(row)
    }

    /// Parse a phrase expecting a window-scope hotkey; returns the action
    /// for further assertions (effect, flags).
    @discardableResult
    private func assertHotkey(_ phrase: String, _ keys: [String],
                              file: StaticString = #filePath, line: UInt = #line) -> FastAction? {
        guard let parsed = FastAction.parse(phrase) else {
            XCTFail("'\(phrase)' should parse", file: file, line: line)
            return nil
        }
        guard case .hotkey(let k, _) = parsed.action.body else {
            XCTFail("'\(phrase)' should be a hotkey, got \(parsed.action.body)",
                    file: file, line: line)
            return nil
        }
        XCTAssertEqual(k, keys, phrase, file: file, line: line)
        return parsed.action
    }

    /// Same for the desktop-scope chord body.
    @discardableResult
    private func assertSystemHotkey(_ phrase: String, _ keys: [String],
                                    file: StaticString = #filePath, line: UInt = #line) -> FastAction? {
        guard let parsed = FastAction.parse(phrase) else {
            XCTFail("'\(phrase)' should parse", file: file, line: line)
            return nil
        }
        guard case .systemHotkey(let k, _) = parsed.action.body else {
            XCTFail("'\(phrase)' should be a systemHotkey, got \(parsed.action.body)",
                    file: file, line: line)
            return nil
        }
        XCTAssertEqual(k, keys, phrase, file: file, line: line)
        return parsed.action
    }

    /// A whole-word trailing filler strips; a mid-string one stays.
    func testTrailingFillerStrip() {
        guard let parsed = FastAction.parse("minimize devin actually") else {
            return XCTFail("'minimize devin actually' should parse")
        }
        guard case .appControl(.minimize) = parsed.action.body else {
            return XCTFail("expected minimize, got \(parsed.action.body)")
        }
        XCTAssertEqual(parsed.appQualifier, "devin")
        // "now" only strips as the tail — "now playing" is content.
        XCTAssertEqual(FastAction.parseOpen("open now playing")?.query, "now playing")
        // Stacked fillers strip in one pass, leaving a bare row.
        guard let stacked = FastAction.parse("minimize right now please") else {
            return XCTFail("'minimize right now please' should strip to 'minimize'")
        }
        guard case .hotkey(let keys, _) = stacked.action.body else {
            return XCTFail("expected ⌘M, got \(stacked.action.body)")
        }
        XCTAssertEqual(keys, ["cmd", "m"])
    }

    /// The display phrase peels into the sentinel qualifier — and out of
    /// the open query entirely.
    func testDisplayScopePeel() {
        let peeled = FastAction.peelDisplayScope("open google on this monitor")
        XCTAssertTrue(peeled.scoped)
        XCTAssertEqual(peeled.rest, "open google")
        XCTAssertEqual(FastAction.parseOpen("open google on this monitor")?.query, "google")
        XCTAssertFalse(FastAction.peelDisplayScope("open google").scoped)

        guard let scoped = FastAction.parse("minimize the window on this monitor") else {
            return XCTFail("display-scoped minimize should parse")
        }
        XCTAssertEqual(scoped.appQualifier, FastAction.gazeDisplayQualifier)
        guard case .hotkey(let keys, _) = scoped.action.body else {
            return XCTFail("expected ⌘M, got \(scoped.action.body)")
        }
        XCTAssertEqual(keys, ["cmd", "m"])
    }

    /// "the email thing" resolves through the nickname map to Mail; a
    /// missing target fails closed to nil.
    func testNicknameResolves() {
        let mail = appRow("Mail", "com.apple.mail", pid: 5)
        let resolved = FastAction.resolveOpenApp(query: "the email thing",
                                                 apps: [mail], frontmostBundle: nil)
        XCTAssertEqual(resolved?.bundle, "com.apple.mail")
        XCTAssertNil(FastAction.resolveOpenApp(query: "the email thing",
                                               apps: [], frontmostBundle: nil),
                     "a missing nickname target must fail closed")
    }

    /// Bare and referent minimizes are frontmost ⌘M rows; the collective
    /// and others-scoped forms are their own chords.
    func testMinimizeHideRows() {
        for phrase in ["minimize", "minimize this", "minimize it", "minimize the app"] {
            assertHotkey(phrase, ["cmd", "m"])
        }
        assertHotkey("minimize all windows", ["alt", "cmd", "m"])
        assertHotkey("minimize everything", ["alt", "cmd", "m"])
        assertHotkey("hide others", ["alt", "cmd", "h"])
        assertHotkey("hide other apps", ["alt", "cmd", "h"])
        assertHotkey("maximize", ["ctrl", "cmd", "f"])
        assertHotkey("make it fullscreen", ["ctrl", "cmd", "f"])
    }

    /// User-named closes lane as ⌘W with direct request — the phrase is
    /// the consent, and none of them may lane as app quits.
    func testCloseRows() {
        for phrase in ["close this tab", "close tab", "close the tab",
                       "close this window", "close window",
                       "close this", "close it"] {
            let action = assertHotkey(phrase, ["cmd", "w"])
            XCTAssertTrue(action?.directlyRequested ?? false, phrase)
            XCTAssertNil(FastAction.parse(phrase)?.appQualifier, phrase)
        }
        // Verb-first close on a window-suffixed name must not quit the app.
        guard let parsed = FastAction.parse("close this tab") else {
            return XCTFail("close this tab should parse")
        }
        guard case .hotkey = parsed.action.body else {
            return XCTFail("expected ⌘W, got \(parsed.action.body)")
        }
    }

    /// User-named editing chords — literal phrases, generic, consented.
    func testEditingChords() {
        for phrase in ["undo", "undo that", "take that back", "put it back"] {
            XCTAssertTrue(assertHotkey(phrase, ["cmd", "z"])?.directlyRequested ?? false, phrase)
        }
        assertHotkey("redo", ["cmd", "shift", "z"])
        assertHotkey("cut", ["cmd", "x"])
        for phrase in ["copy", "copy that", "copy this"] { assertHotkey(phrase, ["cmd", "c"]) }
        assertHotkey("paste", ["cmd", "v"])
        assertHotkey("select all", ["cmd", "a"])
        for phrase in ["save", "save this", "save it"] { assertHotkey(phrase, ["cmd", "s"]) }
        for phrase in ["find", "search this page", "find on page"] {
            assertHotkey(phrase, ["cmd", "f"])
        }
        for phrase in ["print", "print this"] { assertHotkey(phrase, ["cmd", "p"]) }
    }

    /// Comfort zoom aliases ride the existing page-zoom rows.
    func testComfortZoomAliases() {
        for phrase in ["make text bigger", "bigger text", "bigger"] {
            assertHotkey(phrase, ["cmd", "="])
        }
        for phrase in ["make text smaller", "smaller text", "smaller"] {
            assertHotkey(phrase, ["cmd", "-"])
        }
        assertSystemHotkey("screen zoom", ["alt", "cmd", "8"])
        assertSystemHotkey("zoom the screen", ["alt", "cmd", "8"])
    }

    /// Desktop-scope system chords — no app, no window.
    func testSystemChords() {
        assertSystemHotkey("lock screen", ["ctrl", "cmd", "q"])
        assertSystemHotkey("lock my mac", ["ctrl", "cmd", "q"])
        assertSystemHotkey("screenshot", ["cmd", "shift", "3"])
        assertSystemHotkey("screenshot selection", ["cmd", "shift", "4"])
        // The driver posts one non-modifier per chord — the ⇧⌘4-then-Space
        // window capture isn't expressible, so the region chord is it.
        assertSystemHotkey("screenshot window", ["cmd", "shift", "4"])
        assertSystemHotkey("show desktop", ["f11"])
        let switcher = assertSystemHotkey("app switcher", ["cmd", "tab"])
        XCTAssertTrue(switcher?.directlyRequested ?? false)
    }

    /// `tab <n>` and ordinal forms select tabs by position — a
    /// browser-chrome chord, so it keeps needsTabbableApp.
    func testTabIndex() {
        assertHotkey("tab 3", ["cmd", "3"])
        assertHotkey("tab three", ["cmd", "3"])
        assertHotkey("go to tab 2", ["cmd", "2"])
        assertHotkey("switch to tab 5", ["cmd", "5"])
        let third = assertHotkey("the third tab", ["cmd", "3"])
        XCTAssertTrue(third?.needsTabbableApp ?? false)
        // Beyond ⌘9 there is no chord — the loop owns it.
        XCTAssertNil(FastAction.parse("tab 10"))
    }

    /// Menu paths: framed two-segment and item-only forms.
    func testMenuPaths() {
        guard let itemOnly = FastAction.parse("menu save as"),
              case .menu(let path) = itemOnly.action.body else {
            return XCTFail("'menu save as' should parse to a menu path")
        }
        XCTAssertEqual(path, ["save as"])

        guard let framed = FastAction.parse("choose save as in the file menu"),
              case .menu(let framedPath) = framed.action.body else {
            return XCTFail("'choose save as in the file menu' should parse to a menu path")
        }
        XCTAssertEqual(framedPath, ["file", "save as"])

        guard let flat = FastAction.parse("file menu save as"),
              case .menu(let flatPath) = flat.action.body else {
            return XCTFail("'file menu save as' should parse to a menu path")
        }
        XCTAssertEqual(flatPath, ["file", "save as"])
    }

    /// Snap/tile phrases resolve to windowFrame verbs.
    func testSnapRows() {
        for (phrase, snap) in [("snap left", FastAction.WindowSnap.left),
                               ("tile left", .left), ("move window left", .left),
                               ("snap right", .right), ("window right", .right),
                               ("maximize the window", .fill), ("fill the screen", .fill),
                               ("zoom window", .fill)] {
            guard let parsed = FastAction.parse(phrase),
                  case .windowFrame(let s) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to windowFrame"); continue
            }
            XCTAssertEqual(s, snap, phrase)
        }
    }

    /// Overlay phrases and the numbered pick.
    func testOverlayRows() {
        guard let show = FastAction.parse("show numbers"),
              case .overlay(let verb) = show.action.body else {
            return XCTFail("'show numbers' should parse to overlay")
        }
        XCTAssertEqual(verb, .showNumbers)
        guard let bare = FastAction.parse("numbers"),
              case .overlay(let bareVerb) = bare.action.body else {
            return XCTFail("'numbers' should parse to overlay")
        }
        XCTAssertEqual(bareVerb, .showNumbers)
        for phrase in ["show numbers everywhere", "numbers everywhere", "all numbers"] {
            guard let parsed = FastAction.parse(phrase),
                  case .overlay(let v) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to overlay"); continue
            }
            XCTAssertEqual(v, .showNumbersAll, phrase)
        }
        // "hide numbers" is the overlay phrase, never the Numbers app.
        for phrase in ["hide numbers", "clear numbers"] {
            guard let parsed = FastAction.parse(phrase),
                  case .overlay(let v) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to overlay"); continue
            }
            XCTAssertEqual(v, .hideNumbers, phrase)
        }
        for (phrase, n) in [("click 3", 3), ("click three", 3), ("press 12", 12),
                            ("choose 7", 7), ("pick 7", 7), ("number 42", 42)] {
            guard let parsed = FastAction.parse(phrase),
                  case .overlay(let v) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to overlay"); continue
            }
            XCTAssertEqual(v, .clickIndex(n), phrase)
        }
    }

    /// Repeat and locate lanes.
    func testRepeatAndLocate() {
        for phrase in ["do that again", "again", "repeat", "repeat that",
                       "do it again", "same thing", "one more time"] {
            guard let parsed = FastAction.parse(phrase),
                  case .repeatLast = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to repeatLast"); continue
            }
        }
        for (phrase, query) in [("where did notes go", "notes"),
                                ("wheres my notes", "notes"),
                                ("where did my notes window go", "notes"),
                                ("bring back safari", "safari"),
                                ("find my notes", "notes")] {
            guard let parsed = FastAction.parse(phrase),
                  case .locate(let q) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to locate"); continue
            }
            XCTAssertEqual(q, query, phrase)
        }
        // Bare "find" is ⌘F; a non-possessive "find X" is nobody's lane.
        assertHotkey("find", ["cmd", "f"])
        XCTAssertNil(FastAction.parse("find notes"))
    }

    /// Bare referents must fall through to the loop — no row may claim
    /// "the yellow thing", "that button" or "this".
    func testVagueReferentsFallThrough() {
        XCTAssertNil(FastAction.parse("the yellow thing"))
        XCTAssertNil(FastAction.parse("that button"))
        XCTAssertNil(FastAction.parse("this"))
    }
}
