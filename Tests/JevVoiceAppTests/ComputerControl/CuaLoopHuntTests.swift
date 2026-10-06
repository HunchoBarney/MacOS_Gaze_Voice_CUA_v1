import XCTest
import AppKit
import JevVoiceCore
@testable import JevVoice

/// Regression tests for the second hunt wave: window-input gating for
/// scroll lanes, ambiguity-refusal budgeting, host-matched navigation
/// verification, the re-armed navigation miss budget, named-window bind
/// refusal, vanished-window dispatch outcomes, the running flag in the
/// list_apps fallback, element-slot validation, screen-frame coordinate
/// spaces, fresh-tab resolution against a stale baseline, and app-memory
/// load retry.
@MainActor
final class CuaLoopHuntTests: XCTestCase {

    private func element(_ index: Int, role: String, label: String,
                         extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "element_index": .number(Double(index)),
            "element_token": .string("tok\(index)"),
            "role": .string(role), "label": .string(label)]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    private func window(_ elements: [JSONValue], extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "elements": .array(elements), "title": .string("Test Window")]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    private func pick(_ choice: String, _ confidence: Double = 0.9) -> Answer {
        .choice(choice: choice, confidence: confidence, probabilities: [choice: confidence])
    }

    private func answers(next: String, confidence: Double = 0.9,
                         fill: String = "unavailable",
                         doneEvidence: String = "proven",
                         blocked: String = "other") -> [String: Answer] {
        ["next": pick(next, confidence), "fill": pick(fill),
         "doneEvidence": pick(doneEvidence), "blockedReason": pick(blocked)]
    }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    /// A loop whose driver + judge are canned. `states` are served in order
    /// (the last repeats); `steps` answer the judge per step. `listWindows`,
    /// when given, answers each list_windows call by index (0-based).
    private func harness(states: [JSONValue],
                         steps: @escaping (Int) -> [String: Answer],
                         listWindows: ((Int) -> JSONValue)? = nil,
                         apps: [JSONValue] = [],
                         frontmost: Bool = true,
                         raiseMakesFrontmost: Bool = true,
                         dispatch: @escaping (String, [String: JSONValue]) throws -> JSONValue = { _, _ in
                             .object(["effect": .string("confirmed")])
                         })
        -> (loop: CuaAgentLoop, calls: Box<[(String, [String: JSONValue])]>, asked: Box<[[String: Question]]>) {
        let calls = Box<[(String, [String: JSONValue])]>([])
        let asked = Box<[[String: Question]]>([])
        var snapshots = states
        var listCount = 0
        let frontmostState = Box(frontmost)
        let call: CuaTaskAgent.Call = { name, args in
            calls.value.append((name, args))
            if name == "get_window_state" {
                return snapshots.count > 1 ? snapshots.removeFirst() : (snapshots.first ?? .object([:]))
            }
            if name == "list_apps" { return .object(["apps": .array(apps)]) }
            if name == "list_windows" {
                defer { listCount += 1 }
                return listWindows?(listCount) ?? .object(["windows": .array([])])
            }
            if name == "bring_to_front" {
                if raiseMakesFrontmost { frontmostState.value = true }
                return .object(["activated": .bool(raiseMakesFrontmost),
                                "exact_window_effect": .object(["verified": .bool(raiseMakesFrontmost)])])
            }
            return try dispatch(name, args)
        }
        let judge: CuaTaskAgent.Judge = { _, questions in
            asked.value.append(questions)
            return steps(asked.value.count - 1)
        }
        return (CuaAgentLoop(call: call, judge: judge,
                             isFrontmostApp: { _ in frontmostState.value }), calls, asked)
    }

    private func criteria(_ questions: [String: Question]) -> Set<String> {
        guard let question = questions["next"],
              case .choice(_, let criteria) = question else { return [] }
        return Set(criteria.keys)
    }

    private func chromeApp() -> JSONValue {
        .object(["pid": .number(7), "name": .string("Chrome"),
                 "bundle_id": .string("com.google.Chrome"), "running": .bool(true)])
    }

    private func browserWindow() -> JSONValue {
        .object(["windows": .array([.object(["window_id": .number(42),
                                            "title": .string("Tab"),
                                            "is_on_screen": .bool(true)])])])
    }

    /// A browser window whose AX pool is adequate and goal-matched — the
    /// fused visual pass stays off so get_window_state reads stay aligned
    /// with the scripted snapshot queue.
    private func browserAXWindow() -> JSONValue {
        window([element(0, role: "AXButton", label: "Apple")]
               + (1..<8).map { element($0, role: "AXButton", label: "filler \($0)") })
    }

    // MARK: - Scroll lanes share the window-input gate

    /// A background task on a non-frontmost app whose window input is
    /// ambiguous must not be offered scroll lanes — a picked scroll takes
    /// the same raise→verify→foreground path a keystroke does, and a
    /// background task never steals the user's foreground.
    func testAmbiguousWindowInputWithholdsScrollLanes() async throws {
        let (loop, calls, asked) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { step in step == 0
                ? self.answers(next: "scroll_down")
                : self.answers(next: "done") },
            frontmost: false,
            dispatch: { name, _ in
                if name == "scroll" {
                    throw DriverConnectionError.toolRefused(
                        tool: "scroll", code: "same_pid_keyboard_ambiguity", detail: "")
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "scroll down the list",
                                                    pid: 7, windowID: 42))
        // The scroll refused and nothing else ran — a zero-effect run
        // settles blocked, never done.
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(calls.value.filter { $0.0 == "bring_to_front" }.count, 0,
                       "a background task must never raise its target window")
        let offered = criteria(asked.value[1])
        XCTAssertFalse(offered.contains { $0.hasPrefix("scroll_") },
                       "scroll is window input — it shares the ambiguity gate")
        XCTAssertFalse(offered.contains { $0.hasPrefix("key_") || $0.hasPrefix("hotkey_") })
    }

    /// The ambiguity refusal is a dispatch failure like any other — while
    /// the app stays frontmost the lane remains offered, so uncounted
    /// refusals would burn the whole step budget on identical retries.
    func testAmbiguityRefusalsCountTowardDispatchBound() async throws {
        var scrolls = 0
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "scroll_down") },
            frontmost: true,
            dispatch: { name, _ in
                if name == "scroll" {
                    scrolls += 1
                    throw DriverConnectionError.toolRefused(
                        tool: "scroll", code: "same_pid_keyboard_ambiguity", detail: "")
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "scroll down the list",
                                                    pid: 7, windowID: 42, maxSteps: 10))
        // Two refusals dispatch; the identical third pick finds the lane
        // retired by the re-pick bound and hands back untrusted — the
        // step budget is never spent on an endless refusal loop.
        XCTAssertEqual(result.status, .handedBack(.untrustedAnswer))
        XCTAssertEqual(scrolls, 2, "two identical ambiguity refusals bound out honestly")
    }

    // MARK: - Navigation verification

    /// A lookalike host must not satisfy the deferred navigation check:
    /// "apple.com.evil.example" embeds the needle but is not the site —
    /// no "navigated" postcondition may be recorded.
    func testDeferredNavigationMissesOnWrongHost() async throws {
        let tab = JSONValue.object(["tab_id": .string("tab1"), "active": .bool(true),
                                    "url": .string(""), "title": .string("")])
        var browserReads: [JSONValue] = [
            // 1. step-0 binding read — target + tab, no page url yet.
            .object(["target_id": .string("t1"), "tab_id": .string("tab1"),
                     "tabs": .array([tab])]),
            // 2. the dispatch's own verify read — transitional, no url.
            .object([:]),
            // 3. the step-1 ordinary read — a different site that contains
            //    "apple.com" as a substring of its host.
            .object(["target_id": .string("t1"), "tab_id": .string("tab1"),
                     "url": .string("https://apple.com.evil.example/"),
                     "tabs": .array([tab])])]
        let (loop, calls, _) = harness(
            states: [browserAXWindow()],
            steps: { step in step == 0
                ? self.answers(next: "navigate")
                : self.answers(next: "done") },
            listWindows: { _ in self.browserWindow() },
            apps: [chromeApp()],
            dispatch: { name, _ in
                if name == "get_browser_state" {
                    return browserReads.count > 1 ? browserReads.removeFirst() : browserReads[0]
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "go to apple.com",
                                                    application: "com.google.Chrome"))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter { $0.0 == "browser_navigate" }.count, 1)
        XCTAssertFalse(loop.observedPostconditions.contains {
            $0.evidence.contains("navigated to apple.com")
        }, "a lookalike host must never record the navigation as landed")
    }

    /// The host match keeps the subdomain allowance — a site that
    /// redirects "apple.com" to "www.apple.com" still verifies.
    func testDeferredNavigationMatchesSubdomain() async throws {
        let tab = JSONValue.object(["tab_id": .string("tab1"), "active": .bool(true),
                                    "url": .string(""), "title": .string("")])
        var browserReads: [JSONValue] = [
            .object(["target_id": .string("t1"), "tab_id": .string("tab1"),
                     "tabs": .array([tab])]),
            .object([:]),
            .object(["target_id": .string("t1"), "tab_id": .string("tab1"),
                     "url": .string("https://www.apple.com/"),
                     "tabs": .array([tab])])]
        let (loop, _, _) = harness(
            states: [browserAXWindow()],
            steps: { step in step == 0
                ? self.answers(next: "navigate")
                : self.answers(next: "done") },
            listWindows: { _ in self.browserWindow() },
            apps: [chromeApp()],
            dispatch: { name, _ in
                if name == "get_browser_state" {
                    return browserReads.count > 1 ? browserReads.removeFirst() : browserReads[0]
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "go to apple.com",
                                                    application: "com.google.Chrome"))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(loop.observedPostconditions.contains {
            $0.evidence.contains("navigated to apple.com")
        }, "a subdomain of the destination still proves the navigation")
    }

    /// Re-arming pendingNavigation starts a fresh miss budget — a stale
    /// count of ≥2 would clear the NEXT navigation after a single
    /// non-matching read, so a destination arriving on the second read
    /// would never be recorded.
    func testReArmedNavigationGetsFreshMissBudget() async throws {
        let tab = JSONValue.object(["tab_id": .string("tab1"), "active": .bool(true),
                                    "url": .string(""), "title": .string("")])
        func page(_ url: String) -> JSONValue {
            .object(["target_id": .string("t1"), "tab_id": .string("tab1"),
                     "url": .string(url), "tabs": .array([tab])])
        }
        var browserReads: [JSONValue] = [
            // 1. step-0 binding read.
            .object(["target_id": .string("t1"), "tab_id": .string("tab1"),
                     "tabs": .array([tab])]),
            // 2. step-0 verify read — transitional, arms the pending check.
            .object([:]),
            // 3-4. steps 1-2: two misses exhaust the first pending budget.
            page("https://other.com/"), page("https://other.com/"),
            // 5. step-3 read before the second navigate.
            page("https://other.com/"),
            // 6. step-3 verify read — transitional, re-arms the check.
            .object([:]),
            // 7. step-4: one miss — under the stale count this would clear.
            page("https://other.com/"),
            // 8. step-5: the destination lands — only a fresh budget sees it.
            page("https://www.apple.com/"),
            // 9. step-6 read.
            page("https://www.apple.com/")]
        let (loop, _, _) = harness(
            states: [browserAXWindow()],
            steps: { step in
                switch step {
                case 0, 3: return self.answers(next: "navigate")
                case 6: return self.answers(next: "done")
                // Filler picks must be distinct AND offered — an identical
                // re-pick retires the lane, and only the goal-matched
                // "Apple" element survives the shortlist. Its gesture
                // variants plus a later re-click carry the filler steps
                // without spending a scripted browser read.
                case 1: return self.answers(next: "click_0")
                case 2: return self.answers(next: "dclick_0")
                case 4: return self.answers(next: "rclick_0")
                default: return self.answers(next: "click_0")
                }
            },
            listWindows: { _ in self.browserWindow() },
            apps: [chromeApp()],
            dispatch: { name, _ in
                if name == "get_browser_state" {
                    return browserReads.count > 1 ? browserReads.removeFirst() : browserReads[0]
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "go to apple.com",
                                                    application: "com.google.Chrome"))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(loop.observedPostconditions.contains {
            $0.evidence.contains("navigated to apple.com")
        }, "a re-armed pending navigation must observe its full two-miss budget")
    }

    // MARK: - Window binding and vanished windows

    /// A named window that matches nothing is gone — the loop must hand
    /// the pick back with the windows that exist rather than silently
    /// binding the app's top window (and typing the payload into it).
    func testNamedWindowMissHandsBackCandidates() async throws {
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "done") },
            listWindows: { _ in .object(["windows": .array([
                .object(["window_id": .number(7), "title": .string("Untitled Doc"),
                         "is_on_screen": .bool(true)])])]) })
        let result = try await loop.drive(DriveTask(goal: "type the note", pid: 7,
                                                    windowName: "Quarterly Report",
                                                    values: ["field": "x"]))
        XCTAssertEqual(result.status, .needsWindow(candidates: ["Untitled Doc"]))
        XCTAssertFalse(calls.value.contains { $0.0 == "type_text" },
                       "the wrong window must never receive the payload")
    }

    /// A dispatch refusal whose text names a vanished window runs the
    /// same outcome path the observe side does — for a close goal the
    /// gone app IS the done evidence, not a blocked report.
    func testRefusedVanishedWindowRunsCloseOutcome() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "click_0") },
            dispatch: { name, _ in
                if name == "click" {
                    throw DriverConnectionError.refused("window_id_not_found: the window is gone")
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "close the window",
                                                    pid: 7, windowID: 42))
        // The app was already gone before the click landed — the honest
        // verdict is alreadySatisfied, not done (nothing ran this run).
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        XCTAssertTrue(loop.observedPostconditions.contains {
            $0.evidence.contains("no longer running")
        }, "the close goal is satisfied by the vanished window")
    }

    // MARK: - CuaTaskAgent helpers

    /// The list_apps fallback must apply the same running flag the loop
    /// does — an exited row carrying a stale pid must not count as a
    /// second instance and trip the multiple-instances refusal.
    func testListAppsFallbackIgnoresExitedRows() async throws {
        var scrolled = false
        let sut = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([
                    .object(["name": .string("Fixture"), "bundle_id": .string("test.fixture"),
                             "running": .bool(false), "pid": .number(99998)]),
                    .object(["name": .string("Fixture"), "bundle_id": .string("test.fixture"),
                             "running": .bool(true), "pid": .number(99997)])])])
            case "list_windows":
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "is_on_screen": .bool(true)])])])
            case "scroll":
                scrolled = true
            default:
                break
            }
            return .object([:])
        })
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "scroll down in fixture",
            apps: [.object(["name": .string("Fixture"), "bundle_id": .string("test.fixture"),
                            "running": .bool(true), "pid": .number(99997)])]))
        do {
            _ = try await sut.runFastLane(resolved, goal: "scroll down in fixture") { _ in }
        } catch {
            XCTFail("the stale row must not trip the multiple-instances refusal: \(error)")
        }
        XCTAssertTrue(scrolled, "the live pid's window receives the scroll")
    }

    /// The element slot is positional: a reshuffled tree can seat a
    /// stranger at it. The role+label match wins outright, and an index
    /// hit is trusted only while it still names the same control.
    func testSameElementPrefersRoleLabelOverStaleSlot() {
        let field: JSONValue = .object(["element_index": .number(2),
                                        "role": .string("AXTextField"),
                                        "label": .string("Query")])
        let squatter: JSONValue = .object(["element_index": .number(5),
                                           "role": .string("AXButton"),
                                           "label": .string("Other")])
        // The target sat at slot 5; after the reshuffle a different
        // element occupies it — the role+label match must win.
        let hit = CuaTaskAgent.sameElement(in: [squatter, field], index: 5,
                                           role: "AXTextField", label: "Query")
        XCTAssertEqual(hit?["element_index"], .number(2),
                       "a stranger at the old slot must never verify a readback")
        // The slot stays honest: same role and label still resolve by index.
        let same = CuaTaskAgent.sameElement(in: [field], index: 2,
                                            role: "AXTextField", label: "Query")
        XCTAssertEqual(same?["element_index"], .number(2))
        // Nothing matches — the slot's squatter is not the element.
        XCTAssertNil(CuaTaskAgent.sameElement(in: [squatter], index: 5,
                                              role: "AXTextField", label: "Query"))
    }

    /// AX window bounds are top-left-origin while NSScreen frames are
    /// bottom-left-origin anchored on the primary display — a fullscreen
    /// window on a vertically offset secondary display must still cover
    /// its screen.
    func testCoversAnyScreenConvertsScreenFramesToTopLeft() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let left = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let screens = [primary, above, left]
        // A fullscreen window on the display above the primary reads
        // y = -1080 in top-left space; its NSScreen frame's y is 900.
        XCTAssertTrue(CuaTaskAgent.coversAnyScreen(x: 0, y: -1080, width: 1920,
                                                   height: 1080, screens: screens))
        // The primary display is where the two spaces coincide.
        XCTAssertTrue(CuaTaskAgent.coversAnyScreen(x: 0, y: 0, width: 1440,
                                                   height: 900, screens: screens))
        // A display left of the primary: y' = 900 - 0 - 800 = 100.
        XCTAssertTrue(CuaTaskAgent.coversAnyScreen(x: -1280, y: 100, width: 1280,
                                                   height: 800, screens: screens))
        // A smaller window on that same display covers nothing.
        XCTAssertFalse(CuaTaskAgent.coversAnyScreen(x: 0, y: -1080, width: 960,
                                                    height: 540, screens: screens))
    }

    // MARK: - Tab resolution and app memory

    /// The fresh-tab pick counts only BLANK signatures over the baseline:
    /// a baseline tab the task's own earlier navigate moved off its
    /// signature also reads as "added" and must not make a second
    /// new-tab→navigate cycle ambiguous.
    func testResolveNavigationTabCountsOnlyFreshBlankTabs() {
        let existing: JSONValue = .object(["tab_id": .string("a"),
                                           "url": .string("https://a.com/"),
                                           "title": .string("A")])
        let navigated: JSONValue = .object(["tab_id": .string("n"),
                                            "url": .string("https://apple.com/"),
                                            "title": .string("Apple")])
        let fresh: JSONValue = .object(["tab_id": .string("b"),
                                        "url": .string(""), "title": .string("")])
        let baseline = [CuaBrowserTarget.tabSignature(existing)]
        let picked = CuaBrowserTarget.resolveNavigationTab(
            tabs: [existing, navigated, fresh], baseline: baseline,
            newTabRequested: true)
        XCTAssertEqual(picked?["tab_id"], .string("b"),
                       "the stale navigated signature must not count against the fresh tab")
        // Two fresh blanks stay ambiguous — nothing resolved.
        let second: JSONValue = .object(["tab_id": .string("c"),
                                         "url": .string("about:blank"),
                                         "title": .string("")])
        XCTAssertNil(CuaBrowserTarget.resolveNavigationTab(
            tabs: [existing, navigated, fresh, second], baseline: baseline,
            newTabRequested: true))
    }

}
