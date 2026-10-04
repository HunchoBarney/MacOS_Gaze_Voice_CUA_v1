import XCTest
import JevVoiceCore
@testable import JevVoice

/// Coverage for the post-split CuaTaskAgent: the deterministic fast lane plus
/// the pure helpers the drive loop's escalation seams call back into. Planning
/// coverage lives in CompanionBrain tests; per-step selection lives in
/// CuaAgentLoopDriveTests.
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
            if tool == "get_accessibility_tree" {
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

    // MARK: - Postcondition ledger

    /// Postconditions record only what the driver observed — the ledger exists
    /// so verified outcomes bind to readback evidence, never to self-assertion.
    func testObservedPostconditionsStartEmpty() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        XCTAssertTrue(sut.observedPostconditions.isEmpty)
    }
}
