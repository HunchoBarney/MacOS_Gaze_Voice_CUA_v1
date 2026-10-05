import XCTest
import JevVoiceCore
@testable import JevVoice

/// Regression tests for the drive-loop fixes: the per-step success_contains
/// done-check, the offered-lane shortlist, keyed uncertain bounds,
/// needsChoice handbacks, insert-proof masking, lane leases, scaled
/// type_text timeouts, step-phase timings, element-signature re-pick
/// bounds and fill-lane shortlist survival.
@MainActor
final class CuaAgentLoopFixesTests: XCTestCase {

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

    private func pick(_ choice: String, _ confidence: Double = 0.9,
                      probabilities: [String: Double]? = nil) -> Answer {
        .choice(choice: choice, confidence: confidence,
                probabilities: probabilities ?? [choice: confidence])
    }

    private func answers(next: String, confidence: Double = 0.9,
                         probabilities: [String: Double]? = nil,
                         fill: String = "unavailable",
                         doneEvidence: String = "proven",
                         blocked: String = "other") -> [String: Answer] {
        ["next": pick(next, confidence, probabilities: probabilities),
         "fill": pick(fill), "doneEvidence": pick(doneEvidence),
         "blockedReason": pick(blocked)]
    }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    /// A lease registry that just records acquire/release pairing.
    private final class RecordingLeases: CuaLaneLeasing, @unchecked Sendable {
        var focusAcquires = 0, focusReleases = 0
        var pasteAcquires = 0, pasteReleases = 0
        func acquireFocus(workID: String) async throws { focusAcquires += 1 }
        func releaseFocus(workID: String) async { focusReleases += 1 }
        func acquirePasteboard(workID: String) async throws { pasteAcquires += 1 }
        func releasePasteboard(workID: String) async { pasteReleases += 1 }
    }

    private func harness(states: [JSONValue],
                         steps: @escaping (Int) -> [String: Answer],
                         frontmost: Bool = true,
                         approve: ((String) async throws -> Bool)? = nil,
                         leases: (any CuaLaneLeasing)? = nil,
                         timedCall: CuaAgentLoop.TimedCall? = nil,
                         stepTiming: ((Int, [String: Double]) -> Void)? = nil,
                         dispatch: @escaping (String, [String: JSONValue]) throws -> JSONValue = { _, _ in
                             .object(["effect": .string("confirmed")])
                         })
        -> (loop: CuaAgentLoop, calls: Box<[(String, [String: JSONValue])]>, asked: Box<[[String: Question]]>) {
        let calls = Box<[(String, [String: JSONValue])]>([])
        let asked = Box<[[String: Question]]>([])
        var snapshots = states
        let call: CuaTaskAgent.Call = { name, args in
            calls.value.append((name, args))
            if name == "get_window_state" {
                return snapshots.count > 1 ? snapshots.removeFirst() : (snapshots.first ?? .object([:]))
            }
            if name == "list_apps" { return .object(["apps": .array([])]) }
            if name == "list_windows" { return .object(["windows": .array([])]) }
            if name == "bring_to_front" { return .object(["activated": .bool(true)]) }
            return try dispatch(name, args)
        }
        let judge: CuaTaskAgent.Judge = { _, questions in
            asked.value.append(questions)
            return steps(asked.value.count - 1)
        }
        return (CuaAgentLoop(call: call, judge: judge, approve: approve,
                             isFrontmostApp: { _ in frontmost },
                             timedCall: timedCall, lanes: leases,
                             stepTiming: stepTiming), calls, asked)
    }

    private func criteria(_ questions: [String: Question]) -> Set<String> {
        guard let question = questions["next"],
              case .choice(_, let criteria) = question else { return [] }
        return Set(criteria.keys)
    }

    /// A proven success_contains claim finishes the run on ANY step —
    /// not just inside the single-lane bypass. With two action lanes the
    /// old path would have spent a judge call first.
    func testSuccessContainsDoneBeforeJudgeOnEveryStep() async throws {
        let proven = window([
            element(0, role: "AXStaticText", label: "x", extra: ["value": .string("Message sent")]),
            element(1, role: "AXButton", label: "Send"),
            element(2, role: "AXButton", label: "Cancel")])
        let (loop, _, asked) = harness(states: [proven], steps: { _ in self.answers(next: "click_1") })
        let result = try await loop.drive(DriveTask(goal: "send", pid: 7, windowID: 42,
                                                    successContains: ["sent"]))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(asked.value.isEmpty, "the corpus match must finish before the judge is asked")
    }

    /// Goal-matched element lanes survive the shortlist; filler lanes,
    /// keyboard lanes and scroll lanes drop out of the offered set.
    func testShortlistKeepsGoalMatchedElementLanes() async throws {
        var elements: [JSONValue] = []
        for i in 0..<40 {
            let label = i == 5 ? "save file" : (i == 9 ? "save doc" : "filler \(i)")
            elements.append(element(i, role: "AXButton", label: label))
        }
        let (loop, _, asked) = harness(states: [window(elements)],
                                       steps: { _ in self.answers(next: "stuck", blocked: "other") })
        _ = try await loop.drive(DriveTask(goal: "save the file", pid: 7, windowID: 42))
        let offered = criteria(asked.value[0])
        XCTAssertTrue(offered.contains("click_5"))
        XCTAssertTrue(offered.contains("click_9"))
        XCTAssertFalse(offered.contains("click_0"), "unmatched element lanes are trimmed")
        XCTAssertFalse(offered.contains { $0.hasPrefix("key_") || $0.hasPrefix("hotkey_") },
                       "keyboard lanes are withheld when the request never mentions them")
        XCTAssertFalse(offered.contains { $0.hasPrefix("scroll_") })
        XCTAssertTrue(offered.contains("done")); XCTAssertTrue(offered.contains("stuck"))
    }

    /// Zero lexical matches still gets the role-priority floor so the
    /// judge isn't staring at sentinels alone.
    func testShortlistKeepsElementFloorWhenNothingMatches() async throws {
        let elements = (0..<12).map { element($0, role: "AXButton", label: "filler \($0)") }
        let (loop, _, asked) = harness(states: [window(elements)],
                                       steps: { _ in self.answers(next: "stuck", blocked: "other") })
        _ = try await loop.drive(DriveTask(goal: "zzz qqq", pid: 7, windowID: 42))
        let offered = criteria(asked.value[0])
        XCTAssertEqual(offered.filter { $0.hasPrefix("click_") }.count, 8,
                       "the element floor keeps eight lanes by role priority")
        XCTAssertFalse(offered.contains { $0.hasPrefix("scroll_") })
    }

    /// A hesitant pick settles and re-observes once; a second consecutive
    /// hesitant pick hands back the top candidates, ranked by the judge's
    /// own probabilities.
    func testLowConfidenceRecoveryHandsBackNeedsChoice() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go"),
                             element(1, role: "AXButton", label: "Other")])],
            steps: { _ in self.answers(next: "click_0", confidence: 0.3,
                                       probabilities: ["click_0": 0.4, "click_1": 0.2,
                                                       "done": 0.1, "stuck": 0.1]) })
        let result = try await loop.drive(DriveTask(goal: "go", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .handedBack(.needsChoice(options: [
            "Click AXButton \"Go\"", "Click AXButton \"Other\""])))
    }

    /// Two uncertain outcomes on the SAME dispatch block; the count is
    /// keyed so a different lane's uncertain doesn't burn the same budget.
    func testUncertainOutcomeBoundIsPerDispatchKey() async throws {
        var scrolls = 0
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "scroll_down") },
            dispatch: { name, _ in
                if name == "scroll" {
                    scrolls += 1
                    throw CuaUncertainOutcome(tool: "scroll", result: .object([:]))
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "scroll the list", pid: 7, windowID: 42))
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(scrolls, 2, "two uncertain outcomes on the identical dispatch, then honest blocked")
    }

    /// Four uncertain outcomes across DIFFERENT dispatches also block —
    /// the per-key bound doesn't let a run spend unlimited uncertain passes.
    func testUncertainOutcomeTotalBoundAcrossLanes() async throws {
        var dispatches = 0
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { step in
                // scroll_up lexically sorts last — the 30-lane cap drops
                // it, so the fourth distinct dispatch is a key lane.
                self.answers(next: ["scroll_down", "scroll_left", "click_0", "key_return"][min(step, 3)])
            },
            dispatch: { _, _ in
                dispatches += 1
                throw CuaUncertainOutcome(tool: "any", result: .object([:]))
            })
        let result = try await loop.drive(DriveTask(goal: "scroll then press return",
                                                    pid: 7, windowID: 42))
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(dispatches, 4)
    }

    /// The positional target not reading the text must not mask the broad
    /// scan — a sibling element holding the inserted text still proves it.
    func testInsertProofBroadScanWhenTargetDoesntRead() async throws {
        let (loop, _, _) = harness(
            states: [
                window([element(0, role: "AXTextField", label: "Search")]),
                window([element(0, role: "AXTextField", label: "Search",
                                extra: ["value": .string("placeholder")]),
                        element(1, role: "AXTextArea", label: "Body",
                                extra: ["value": .string("weather")])])],
            steps: { step in step == 0
                ? self.answers(next: "typeinto_0", fill: "query")
                : self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "search", pid: 7, windowID: 42,
                                                    values: ["query": "weather"]))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(loop.observedPostconditions.contains {
            $0.evidence.contains("visible in Body")
        }, "the sibling field holding the text proves the insert")
    }

    /// invoke_menu transiently fronts the app — the focus lease must wrap
    /// the call so a peer lane can't interleave its own activation.
    func testInvokeMenuHoldsFocusLease() async throws {
        let leases = RecordingLeases()
        let menuState = window([
            element(0, role: "AXMenuItem", label: "Quit App",
                    extra: ["parent_index": .number(1)]),
            element(1, role: "AXMenu", label: "",
                    extra: ["parent_index": .number(2)]),
            element(2, role: "AXMenuBar", label: "")])
        let (loop, calls, _) = harness(
            states: [menuState, window([])],
            steps: { step in step == 0
                ? self.answers(next: "menu_0")
                : self.answers(next: "done") },
            approve: { _ in true },
            leases: leases)
        let result = try await loop.drive(DriveTask(goal: "quit the app", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter { $0.0 == "invoke_menu" }.count, 1)
        XCTAssertEqual(leases.focusAcquires, 1)
        XCTAssertEqual(leases.focusReleases, 1)
    }

    /// ⌘C touches the pasteboard — the chord holds the pasteboard lease so
    /// another lane's copy can't interleave.
    func testPasteboardChordHoldsPasteboardLease() async throws {
        let leases = RecordingLeases()
        let state = window([element(0, role: "AXTextField", label: "Name")])
        let (loop, calls, _) = harness(
            states: [state],
            steps: { step in step == 0
                ? self.answers(next: "hotkey_cmd+c")
                : self.answers(next: "done") },
            leases: leases)
        let result = try await loop.drive(DriveTask(goal: "copy the text", pid: 7, windowID: 42,
                                                    values: ["field": "x"]))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter { $0.0 == "hotkey" }.count, 1)
        XCTAssertEqual(leases.pasteAcquires, 1)
        XCTAssertEqual(leases.pasteReleases, 1)
    }

    /// The same fill/submit dispatch skipped twice leaves the offered
    /// set — the model must pick something else or honestly stop.
    func testRepickBoundRemovesLaneFromOfferedSet() async throws {
        let (loop, calls, asked) = harness(
            states: [window([element(0, role: "AXTextField", label: "Name")])],
            steps: { step in step < 3
                ? self.answers(next: "key_return")
                : self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "press the return key",
                                                    pid: 7, windowID: 42,
                                                    values: ["field": "x"]))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter { $0.0 == "press_key" }.count, 1,
                       "the identical submit key is never re-dispatched")
        XCTAssertFalse(criteria(asked.value[3]).contains("key_return"),
                       "the twice-skipped lane leaves the offered set")
    }

    /// Synthesized typing runs ~38ms/char — type_text gets a text-scaled
    /// timeout instead of the 30s default.
    func testTypeTextScalesCallTimeout() async throws {
        let timeouts = Box<[TimeInterval]>([])
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXTextField", label: "Search")]),
                     window([element(0, role: "AXTextField", label: "Search",
                                     extra: ["value": .string("weather")])])],
            steps: { step in step == 0
                ? self.answers(next: "typeinto_0", fill: "query")
                : self.answers(next: "done") },
            timedCall: { name, _, timeout in
                timeouts.value.append(timeout)
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "search", pid: 7, windowID: 42,
                                                    values: ["query": "weather"]))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(timeouts.value, [30 + 7 * 0.05])
    }

    /// The step-timing seam fires once per iteration with the phase map —
    /// early exits included.
    func testStepTimingFiresPhasesPerIteration() async throws {
        let timings = Box<[(Int, [String: Double])]>([])
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go"),
                             element(1, role: "AXButton", label: "Stop")])],
            steps: { step in step == 0
                ? self.answers(next: "click_0")
                : self.answers(next: "done") },
            stepTiming: { step, phases in timings.value.append((step, phases)) })
        let result = try await loop.drive(DriveTask(goal: "go", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(timings.value.count, 2)
        for key in ["observe_ms", "judge_ms", "dispatch_ms", "post_ms"] {
            XCTAssertNotNil(timings.value[0].1[key], "step 0 is missing \(key)")
        }
        XCTAssertNotNil(timings.value[1].1["observe_ms"])
        XCTAssertNotNil(timings.value[1].1["judge_ms"])
    }

    /// The click lane gets the same re-pick bound as fills and submits:
    /// two identical dispatches into a window whose observation never
    /// changes, then the lane leaves the offered set — a third blind
    /// click never fires. (The production bug: a Search button clicked
    /// ~10x while the query was never typed.)
    func testIdenticalClickSuppressedAfterTwoBlindDispatches() async throws {
        // The second button shares a goal word so the shortlist keeps it
        // offered — the ban (not the trim) is what removes click_0.
        let state = window([element(0, role: "AXButton", label: "Search"),
                            element(1, role: "AXButton", label: "Search Results")])
        let (loop, calls, asked) = harness(
            states: [state],
            steps: { step in step < 3
                ? self.answers(next: "click_0")
                : self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "open search", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter { $0.0 == "click" }.count, 2,
                       "the third identical blind click is never dispatched")
        XCTAssertFalse(criteria(asked.value[3]).contains("click_0"),
                       "the suppressed lane leaves the offered set")
        XCTAssertTrue(criteria(asked.value[3]).contains("click_1"),
                      "other lanes stay offered")
    }

    /// A re-snapshot that rotates element_token AND element_index must not
    /// let the same control slip the bound — identity rides the control's
    /// role + label + frame, not the slot it sits in.
    func testRepickBoundFollowsElementAcrossReshuffle() async throws {
        func searchButton(_ index: Int, _ token: String) -> JSONValue {
            element(index, role: "AXButton", label: "Search", extra: [
                "element_token": .string(token),
                "frame": .object(["x": .number(10), "y": .number(10),
                                  "w": .number(40), "h": .number(20)])])
        }
        // A second goal-matched button stays offered throughout — the
        // ban removing the search control is a signature match, not a
        // shortlist trim.
        let home = element(9, role: "AXButton", label: "Search Results")
        let (loop, calls, asked) = harness(
            states: [window([searchButton(0, "tA"), home]),
                     window([searchButton(3, "tB"), home]),
                     window([searchButton(5, "tC"), home]),
                     window([searchButton(2, "tD"), home])],
            steps: { step in
                self.answers(next: ["click_0", "click_3", "click_5", "done"][min(step, 3)])
            })
        let result = try await loop.drive(DriveTask(goal: "open search", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter { $0.0 == "click" }.count, 2,
                       "the same control is retried at most once across re-snapshots")
        XCTAssertFalse(criteria(asked.value[3]).contains("click_2"),
                       "the ban holds at the element's new index and token")
        XCTAssertTrue(criteria(asked.value[3]).contains("click_9"),
                      "a different control at a stable slot is not collateral")
    }

    /// A supplied payload keeps every fill lane offered even when the
    /// field's own label matches no goal word — a placeholder-labeled
    /// search field is still the only lane that can land the text.
    func testFillLanesSurviveShortlistWhenValuesSupplied() async throws {
        let elements = [
            element(0, role: "AXButton", label: "Search"),
            element(1, role: "AXButton", label: "Spotify Premium"),
            element(2, role: "AXButton", label: "Marvin Gaye"),
            element(9, role: "AXSearchField", label: "What do you want to listen to?")]
        let (loop, _, asked) = harness(
            states: [window(elements)],
            steps: { _ in self.answers(next: "stuck", blocked: "other") })
        _ = try await loop.drive(DriveTask(goal: "search spotify for marvin's room",
                                           pid: 7, windowID: 42,
                                           values: ["query": "marvin's room"]))
        let offered = criteria(asked.value[0])
        XCTAssertTrue(offered.contains("typeinto_9"),
                      "a placeholder-labeled field must survive the shortlist")
        XCTAssertTrue(offered.contains("click_0"))
    }

    /// When the AX readback can't see the inserted text, one bounded
    /// visual read may still prove the landing — the region text is
    /// observed evidence, not a replayed claim.
    func testInsertProofVisualReadProvesLanding() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXTextField", label: "Search")]),
                     window([element(0, role: "AXTextField", label: "Search",
                                     extra: ["value": .string("placeholder")])],
                            extra: ["capture_id": .string("cap1")])],
            steps: { step in step == 0
                ? self.answers(next: "typeinto_0", fill: "query")
                : self.answers(next: "done") },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    return .object(["regions": .array([
                        .object(["text": .string("weather in tokyo")])])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "search", pid: 7, windowID: 42,
                                                    values: ["query": "weather"]))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(loop.observedPostconditions.contains {
            $0.evidence.contains("visible on screen")
        }, "the visual read proves the insert when AX cannot")
    }
}
