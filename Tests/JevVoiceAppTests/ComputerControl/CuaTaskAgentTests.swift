import XCTest
import JevVoiceCore
@testable import JevVoice

/// Coverage for the post-split CuaTaskAgent: the deterministic fast lane plus
/// the pure helpers the drive loop's escalation seams call back into.
/// Per-step selection lives in CuaAgentLoopDriveTests.
@MainActor
final class CuaTaskAgentTests: XCTestCase {

    // MARK: - Fixture plumbing

    private func app(_ name: String, bundle: String, running: Bool = false, pid: Int = 0) -> JSONValue {
        .object(["name": .string(name), "bundle_id": .string(bundle),
                 "running": .bool(running), "pid": .number(Double(pid))])
    }

    // MARK: - resolveFastLane

    func testOpenVerbResolvesExactlyOneInstalledApp() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Fixture", bundle: "test.fixture"),
                    app("Other App", bundle: "test.other")]
        let resolved = sut.resolveFastLane(goal: "open fixture", apps: apps)
        XCTAssertEqual(resolved?.bundle, "test.fixture")
        XCTAssertEqual(resolved?.name, "Fixture")
        XCTAssertNotNil(resolved?.openVerb)
        XCTAssertNil(resolved?.action)
    }

    func testNonPrimitiveFallsThroughToPlanner() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Fixture", bundle: "test.fixture")]
        for utterance in ["click the red button", "open fixture and type hello",
                          "please could you possibly open fixture for me"] {
            XCTAssertNil(sut.resolveFastLane(goal: utterance, apps: apps), utterance)
        }
    }

    func testNegatedRequestNeverResolvesFastLane() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Fixture", bundle: "test.fixture")]
        for utterance in ["don't open fixture", "never open fixture", "do not quit fixture"] {
            XCTAssertNil(sut.resolveFastLane(goal: utterance, apps: apps), utterance)
        }
    }

    func testUnknownAppNameDoesNotResolve() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Fixture", bundle: "test.fixture")]
        XCTAssertNil(sut.resolveFastLane(goal: "open nonexistent", apps: apps))
    }

    /// "scroll down in X" resolves as a deterministic window scroll — the
    /// highest frequency pointer replacement a voice user asks for — with
    /// zero planner or judge calls. (The unqualified form resolves against
    /// the frontmost app, which a test host cannot pose as.)
    func testScrollResolvesAndDispatchesWindowScroll() async throws {
        var dispatched: [String: JSONValue]?
        let sut = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "scroll": dispatched = args
            case "get_accessibility_tree", "list_apps":
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 42)])])
            case "list_windows":
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "is_on_screen": .bool(true)])])])
            default: break
            }
            return .object([:])
        })
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "scroll down in fixture", apps: [app("Fixture", bundle: "test.fixture",
                                                       running: true, pid: 42)]))
        let evidence = try await sut.runFastLane(resolved, goal: "scroll down in fixture") { _ in }
        XCTAssertNotNil(evidence)
        XCTAssertEqual(dispatched?["direction"], .string("down"))
        XCTAssertEqual(dispatched?["window_id"], .number(7))
        XCTAssertEqual(dispatched?["delivery_mode"], .string("background"))
    }

    /// A scroll aimed at a window never rewrites into a keystroke: "scroll
    /// down" must not dispatch ⌘-style chords even when the page is key-heavy.
    func testScrollLaneNeverSendsHotkeys() async throws {
        var hotkeyCalls = 0
        let sut = CuaTaskAgent(call: { tool, _ in
            if tool == "hotkey" { hotkeyCalls += 1 }
            if tool == "get_accessibility_tree" || tool == "list_apps" {
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 42)])])
            }
            if tool == "list_windows" {
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "is_on_screen": .bool(true)])])])
            }
            return .object([:])
        })
        for phrase in ["scroll up in fixture", "scroll down in fixture",
                       "scroll left in fixture", "scroll right in fixture"] {
            let resolved = try XCTUnwrap(sut.resolveFastLane(
                goal: phrase, apps: [app("Fixture", bundle: "test.fixture",
                                         running: true, pid: 42)]), phrase)
            _ = try await sut.runFastLane(resolved, goal: phrase) { _ in }
        }
        XCTAssertEqual(hotkeyCalls, 0)
    }

    // MARK: - runFastLane

    /// An open verb on a not-running app launches it and verifies through the
    /// observed process — zero model calls.
    func testOpenLaunchesAndVerifies() async throws {
        var launched = false
        let sut = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "get_accessibility_tree", "list_apps":
                return .object(["apps": .array([
                    self.app("Fixture", bundle: "test.fixture",
                             running: launched, pid: launched ? 42 : 0)])])
            case "launch_app":
                launched = true
                return .object(["pid": .number(42), "name": .string("Fixture"),
                                "bundle_id": .string("test.fixture")])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            default:
                return .object([:])
            }
        })
        let resolved = try XCTUnwrap(
            sut.resolveFastLane(goal: "open fixture", apps: [app("Fixture", bundle: "test.fixture")]))
        let evidence = try await sut.runFastLane(resolved, goal: "open fixture") { _ in }
        XCTAssertTrue(launched)
        XCTAssertNotNil(evidence)
        XCTAssertEqual(sut.bundleID, "test.fixture")
    }

    /// App-control verbs refuse to launch an app just to quit/hide it —
    /// inventing work the user never asked for is worse than an honest refusal.
    func testAppControlOnStoppedAppRefusesWithoutLaunching() async throws {
        var launchCalls = 0
        let sut = CuaTaskAgent(call: { tool, _ in
            if tool == "launch_app" { launchCalls += 1 }
            if tool == "get_accessibility_tree" || tool == "list_apps" {
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture")])])
            }
            return .object([:])
        })
        let quit = try XCTUnwrap(
            sut.resolveFastLane(goal: "quit fixture", apps: [app("Fixture", bundle: "test.fixture",
                                                                 running: true, pid: 7)]))
        // resolve saw the app "running" in the caller's snapshot; runFastLane's
        // fresh read reports it stopped — the refusal must land there.
        do {
            _ = try await sut.runFastLane(quit, goal: "quit fixture") { _ in }
            XCTFail("A quit on a stopped app must refuse, not launch-then-quit")
        } catch {
            XCTAssertEqual(launchCalls, 0)
        }
    }

    // MARK: - Pure helpers the escalation seams use

    func testUniqueEditableTargetRequiresExactlyOneEditable() {
        let editable: JSONValue = .object([
            "role": .string("AXTextArea"), "label": .string("Body"),
            "element_token": .string("tok-3")])
        let button: JSONValue = .object([
            "role": .string("AXButton"), "label": .string("Save"),
            "element_token": .string("tok-1")])
        XCTAssertNotNil(CuaTaskAgent.uniqueEditableTarget(in: [editable, button]))
        let second: JSONValue = .object([
            "role": .string("AXTextField"), "label": .string("Title"),
            "element_token": .string("tok-4")])
        XCTAssertNil(CuaTaskAgent.uniqueEditableTarget(in: [editable, second]))
        XCTAssertNil(CuaTaskAgent.uniqueEditableTarget(in: [button]))
        // A field without a driver token can never be addressed — not editable.
        let tokenless: JSONValue = .object([
            "role": .string("AXTextArea"), "label": .string("Body")])
        XCTAssertNil(CuaTaskAgent.uniqueEditableTarget(in: [tokenless]))
    }

    func testSupportsIsolatedBrowserRecognizesChromiumBrowsers() {
        XCTAssertTrue(CuaTaskAgent.supportsIsolatedBrowser("com.google.Chrome"))
        XCTAssertTrue(CuaTaskAgent.supportsIsolatedBrowser("com.microsoft.edgemac"))
        XCTAssertFalse(CuaTaskAgent.supportsIsolatedBrowser("com.apple.Safari"))
        XCTAssertFalse(CuaTaskAgent.supportsIsolatedBrowser("com.apple.Notes"))
        XCTAssertFalse(CuaTaskAgent.supportsIsolatedBrowser(""))
    }

    func testRequiresRiskJudgmentFlagsConsequentialActions() {
        XCTAssertTrue(CuaTaskAgent.requiresRiskJudgment(goal: "delete the file",
                                                        actionDescription: "Press Delete"))
        XCTAssertTrue(CuaTaskAgent.requiresRiskJudgment(goal: "send the reply",
                                                        actionDescription: "Click Send"))
        XCTAssertFalse(CuaTaskAgent.requiresRiskJudgment(goal: "open a new tab",
                                                         actionDescription: "Open a new browser tab"))
    }

    /// A hotkey description names no consequential keyword but carries the
    /// same effect — ⌘Q quits, ⌘W closes, ⌘⌫ trashes. These must ask.
    func testRequiresRiskJudgmentFlagsConsequentialHotkeys() {
        XCTAssertTrue(CuaTaskAgent.requiresRiskJudgment(goal: "quit the app",
                                                        actionDescription: "Press ⌘Q"))
        XCTAssertTrue(CuaTaskAgent.requiresRiskJudgment(goal: "close the window",
                                                        actionDescription: "hotkey_cmd+w"))
        XCTAssertTrue(CuaTaskAgent.requiresRiskJudgment(goal: "close the window",
                                                        actionDescription: "Press cmd+w"))
        XCTAssertTrue(CuaTaskAgent.requiresRiskJudgment(goal: "trash the file",
                                                        actionDescription: "Press ⌘⌫"))
        XCTAssertFalse(CuaTaskAgent.requiresRiskJudgment(goal: "copy the selection",
                                                         actionDescription: "Press ⌘C"))
        XCTAssertFalse(CuaTaskAgent.requiresRiskJudgment(goal: "save the document",
                                                         actionDescription: "hotkey_cmd+s"))
    }

    // MARK: - Search-query backfill

    /// "search for X" goals carry a verbatim query — when the planner omits
    /// `values`, the runtime recovers it deterministically so the loop can
    /// type instead of hunting for a chorded shortcut.
    func testImpliedQueryRecoversSearchText() {
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "Search for Marvins Room in Spotify",
                                                  app: "Spotify"), "Marvins Room")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "look up the weather in yuba city",
                                                  app: nil), "the weather in yuba city")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "google how to make pasta",
                                                  app: nil), "how to make pasta")
        // No search verb → nothing recovered.
        XCTAssertNil(CuaVoiceRuntime.impliedQuery(in: "open the notes app", app: "Notes"))
        // An empty tail is no query.
        XCTAssertNil(CuaVoiceRuntime.impliedQuery(in: "search for", app: nil))
    }

    // MARK: - Postcondition ledger

    /// Postconditions record only what the driver observed — the ledger exists
    /// so verified outcomes bind to readback evidence, never to self-assertion.
    func testObservedPostconditionsStartEmpty() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        XCTAssertTrue(sut.observedPostconditions.isEmpty)
    }

    // MARK: - Spotify play

    /// "play X" is a media verb: the scripting bridge resolves the top hit
    /// inside Spotify and the `current track` readback proves what actually
    /// started — no launch_app, no window ceremony, no drive loop.
    func testPlayPrefersScriptedPlayVerifiedByReadback() async throws {
        var launchCalls = 0
        var sources: [String] = []
        let sut = CuaTaskAgent(call: { tool, _ in
            if tool == "launch_app" { launchCalls += 1 }
            return .object([:])
        }, osascript: { source, _ in
            sources.append(source)
            if source.contains("play track") { return "" }
            if source.contains("player state") { return "No Mistakes, Kanye West, playing" }
            return nil
        })
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "play no mistakes by kanye",
            apps: [app("Spotify", bundle: "com.spotify.client", running: true, pid: 99)]))
        let evidence = try await sut.runFastLane(resolved,
                                                 goal: "play no mistakes by kanye") { _ in }
        XCTAssertEqual(evidence, "Playing No Mistakes by Kanye West on Spotify.")
        XCTAssertEqual(launchCalls, 0, "the scripting bridge must not pay an app launch")
        XCTAssertTrue(sources.contains { $0.contains("spotify:search:no%20mistakes")
                                            || $0.contains("spotify:search:no mistakes") },
                      "the search URI reaches the play command")
        XCTAssertTrue(sut.observedPostconditions.contains {
            $0.kind == .resultObserved && $0.evidence.contains("No Mistakes") })
    }

    /// The Kendrick failure: Spotify accepts the search URI but resumes its
    /// stale queue, so the readback names an unrelated track. The content-
    /// word guard rejects that "playing" state and the honest URI+Return
    /// path carries the search instead — the evidence names what is ACTUALLY
    /// playing, never the requested song.
    func testPlayReadbackRejectingWrongTrackFallsBackToSearch() async throws {
        var launchedURLs: [String] = []
        var returnDispatched = false
        let sut = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "launch_app":
                launchedURLs = (args["urls"]?.array ?? []).compactMap { $0.string }
                return .object(["pid": .number(99)])
            case "list_apps":
                return .object(["apps": .array([
                    self.app("Spotify", bundle: "com.spotify.client",
                             running: true, pid: 99)])])
            case "list_windows":
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "title": .string("Spotify"),
                    "is_on_screen": .bool(true)])])])
            case "get_window_state":
                return .object(["elements": .array([.object([
                    "role": .string("AXSearchField"),
                    "value": .string("no+mistakes+by+kanye")])]),
                    "title": .string("Spotify")])
            case "press_key":
                returnDispatched = true
                return .object(["effect": .string("confirmed")])
            default:
                return .object([:])
            }
        }, osascript: { source, _ in
            if source.contains("play track") { return "" }
            if source.contains("player state") { return "Alright, Kendrick Lamar, playing" }
            return nil
        })
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "play no mistakes by kanye",
            apps: [app("Spotify", bundle: "com.spotify.client", running: true, pid: 99)]))
        let evidence = try await sut.runFastLane(resolved,
                                                 goal: "play no mistakes by kanye") { _ in }
        let answer = try XCTUnwrap(evidence)
        XCTAssertTrue(answer.contains("Kendrick"),
                      "the wrong track is named, not silently claimed — got: \(answer)")
        XCTAssertFalse(answer.hasPrefix("Playing No Mistakes"),
                       "an unrelated readback can never satisfy the request")
        XCTAssertEqual(launchedURLs, ["spotify:search:no%20mistakes%20by%20kanye"],
                       "the honest fallback delivers the visible search URI")
        XCTAssertTrue(returnDispatched, "the verified results page earns the Return press")
    }
}
