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
                         windowRows: [JSONValue] = [],
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
            if name == "list_windows" { return .object(["windows": .array(windowRows)]) }
            if name == "bring_to_front" { return .object(["activated": .bool(true)]) }
            return try dispatch(name, args)
        }
        let judge: CuaTaskAgent.Judge = { _, questions in
            asked.value.append(questions)
            return steps(asked.value.count - 1)
        }
        return (CuaAgentLoop(call: call, judge: judge, approve: approve,
                             isFrontmostApp: { _ in frontmost },
                             timedCall: timedCall, lanes: leases), calls, asked)
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
        // The corpus already proves the goal before any dispatch — the
        // pre-judge settle reports alreadySatisfied, not done.
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
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
            "Click the AXButton \"Go\"", "Click the AXButton \"Other\""])))
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
        // Two uncertain dispatches of the identical pick, then the re-pick
        // bound retires the lane — a judge that insists on it hands back
        // untrusted instead of burning the step budget.
        XCTAssertEqual(result.status, .handedBack(.untrustedAnswer))
        XCTAssertEqual(scrolls, 2, "two uncertain outcomes on the identical dispatch, then honest stop")
    }

    /// Four uncertain outcomes across DIFFERENT dispatches also block —
    /// the run-wide uncertain bound caps the passes a run can spend.
    func testUncertainOutcomeTotalBoundAcrossLanes() async throws {
        var dispatches = 0
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { step in
                // Four distinct scroll lanes — all offered for a scroll
                // goal — so each uncertain outcome lands on a different
                // dispatch key.
                self.answers(next: ["scroll_down", "scroll_left", "scroll_up", "scroll_right"][min(step, 3)])
            },
            dispatch: { _, _ in
                dispatches += 1
                throw CuaUncertainOutcome(tool: "any", result: .object([:]))
            })
        // A purely scroll-shaped goal keeps the 30-lane shortlist off the
        // keyboard lanes, so all four scroll directions stay offered.
        let result = try await loop.drive(DriveTask(goal: "scroll the list",
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
    /// set — the model must pick something else or honestly stop. A judge
    /// that insists on the banned lane hands back untrusted: the lane was
    /// never offered again, so the pick cannot be honored.
    func testRepickBoundRemovesLaneFromOfferedSet() async throws {
        let (loop, calls, asked) = harness(
            states: [window([element(0, role: "AXTextField", label: "Name")])],
            steps: { step in step < 3
                ? self.answers(next: "key_return")
                : self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "press the return key",
                                                    pid: 7, windowID: 42,
                                                    values: ["field": "x"]))
        XCTAssertEqual(result.status, .handedBack(.untrustedAnswer))
        XCTAssertEqual(calls.value.filter { $0.0 == "press_key" }.count, 1,
                       "the identical submit key is never re-dispatched")
        let lastAsk = asked.value.last ?? [:]
        XCTAssertFalse(criteria(lastAsk).contains("key_return"),
                       "the skipped-then-banned lane leaves the offered set")
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
        // Two consecutive identical picks ban the lane from the next offer —
        // the scripted third click_0 answer is then untrusted, and the loop
        // never dispatched it either way.
        XCTAssertEqual(calls.value.filter { $0.0 == "click" }.count, 2,
                       "the third identical blind click is never dispatched")
        XCTAssertGreaterThanOrEqual(asked.value.count, 3)
        XCTAssertFalse(criteria(asked.value[2]).contains("click_0"),
                       "the banned lane leaves the offered set")
        XCTAssertTrue(criteria(asked.value[2]).contains("click_1"),
                      "other lanes stay offered")
        if case .done = result.status { } else if case .handedBack = result.status { }
        else { XCTFail("expected done or handedBack, got \(result.status)") }
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
        // shortlist trim. Filler buttons keep the AX pool adequate so
        // the fused visual read never fires — the snapshot sequence
        // stays purely positional.
        let home = element(9, role: "AXButton", label: "Search Results")
        let fillers = (20..<28).map { element($0, role: "AXButton", label: "filler \($0)") }
        let (loop, calls, asked) = harness(
            states: [window([searchButton(0, "tA"), home] + fillers),
                     window([searchButton(3, "tB"), home] + fillers),
                     window([searchButton(5, "tC"), home] + fillers),
                     window([searchButton(2, "tD"), home] + fillers)],
            steps: { step in
                self.answers(next: ["click_0", "click_3", "click_5", "done"][min(step, 3)])
            })
        let result = try await loop.drive(DriveTask(goal: "open search", pid: 7, windowID: 42))
        // The scripted third pick targets the banned control at its new
        // index — an unoffered answer hands back untrusted rather than
        // dispatching blind. The ban itself is what the asks prove.
        XCTAssertEqual(result.status, .handedBack(.untrustedAnswer))
        XCTAssertEqual(calls.value.filter { $0.0 == "click" }.count, 2,
                       "the same control is retried at most once across re-snapshots")
        let lastAsk = asked.value.last ?? [:]
        XCTAssertFalse(criteria(lastAsk).contains("click_5"),
                       "the ban holds at the element's new index and token")
        XCTAssertTrue(criteria(lastAsk).contains("click_9"),
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

    /// A stuck verdict on an ADEQUATE AX window (the fused pass never ran,
    /// so the escalation is unspent) gets one visual escalation: detected
    /// regions arrive as clickable candidates carrying their capture, and
    /// picking one dispatches a real pixel click bound to that capture.
    func testStuckVerdictArmsVisualClickCandidates() async throws {
        // Ten candidates + a goal-matched lane pass the adequacy gate —
        // the visual pass stays a stuck escalation, not a fused read.
        let adequate = window(
            (0..<9).map { element($0, role: "AXButton", label: "filler \($0)") }
                + [element(9, role: "AXButton", label: "Biggest")])
        let (loop, calls, asked) = harness(
            states: [adequate,
                     window([], extra: ["capture_id": .string("cap1")]),
                     adequate],
            steps: { step in
                switch step {
                case 0: return self.answers(next: "stuck")
                case 1: return self.answers(next: "vclick_r1")
                default: return self.answers(next: "done")
                }
            },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    return .object(["regions": .array([
                        .object(["id": .string("r1"), "kind": .string("text"),
                                 "bounds": .object(["x": .number(10), "y": .number(20),
                                                    "width": .number(40), "height": .number(20)]),
                                 "text": .string("K"),
                                 "confidence": .number(0.9),
                                 "interactive": .bool(true)])])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "click the biggest K",
                                                    pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(criteria(asked.value[1]).contains("vclick_r1"),
                      "the visual region must be offered as a clickable candidate")
        guard let click = calls.value.first(where: { $0.0 == "click" })?.1 else {
            return XCTFail("the visual lane must dispatch a real click")
        }
        XCTAssertEqual(click["capture_id"], .string("cap1"))
        XCTAssertEqual(click["x"], .number(30))  // bounds center: 10 + 40/2
        XCTAssertEqual(click["y"], .number(30))  // bounds center: 20 + 20/2
    }

    /// A visual read that finds nothing — or a judge that stays stuck
    /// after seeing the regions — blocks honestly instead of inventing an
    /// action.
    func testStuckVerdictBlocksWhenVisualPassFindsNothing() async throws {
        let (loop, calls, _) = harness(
            states: [window([]), window([], extra: ["capture_id": .string("cap1")])],
            steps: { _ in self.answers(next: "stuck") },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    return .object(["regions": .array([])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let empty = try await loop.drive(DriveTask(goal: "click the biggest K",
                                                   pid: 7, windowID: 42))
        guard case .blocked = empty.status else { return XCTFail("expected blocked, got \(empty.status)") }
        XCTAssertFalse(calls.value.contains { $0.0 == "click" },
                       "nothing visual means nothing to click")
    }

    /// The escalation is bounded: after candidates are offered, a second
    /// consecutive stuck verdict ends the run rather than paying another
    /// screenshot + parse round-trip.
    func testStuckVerdictBlocksOnSecondConsecutiveStuck() async throws {
        // Adequate AX keeps the fused pass off — the escalation is the
        // only visual read this run pays for.
        let adequate = window(
            (0..<9).map { element($0, role: "AXButton", label: "filler \($0)") }
                + [element(9, role: "AXButton", label: "Biggest")])
        let (loop, calls, _) = harness(
            states: [adequate, window([], extra: ["capture_id": .string("cap1")]),
                     adequate],
            steps: { _ in self.answers(next: "stuck") },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    return .object(["regions": .array([
                        .object(["id": .string("r1"), "kind": .string("text"),
                                 "bounds": .object(["x": .number(0), "y": .number(0),
                                                    "width": .number(10), "height": .number(10)]),
                                 "text": .string("K"), "confidence": .number(0.8),
                                 "interactive": .bool(true)])])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "click the biggest K",
                                                    pid: 7, windowID: 42))
        guard case .blocked = result.status else { return XCTFail("expected blocked, got \(result.status)") }
        XCTAssertEqual(calls.value.filter { $0.0 == "parse_visual_regions" }.count, 1,
                       "one bounded visual read per run")
        XCTAssertFalse(calls.value.contains { $0.0 == "click" })
    }

    /// Hybrid perception: a sparse AX tree (0-2 candidates, no goal
    /// match) fuses the visual pass into the SAME ask — regions arrive
    /// as clickable candidates before any stuck verdict, and the
    /// ordinary observe still pays for no screenshot.
    func testSparseAXFusesVisualCandidatesBeforeStuck() async throws {
        let (loop, calls, asked) = harness(
            states: [window([element(0, role: "AXStaticText", label: "drawn pixels")]),
                     window([], extra: ["capture_id": .string("cap1")])],
            steps: { step in step == 0
                ? self.answers(next: "vclick_r1")
                : self.answers(next: "done") },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    return .object(["regions": .array([
                        .object(["id": .string("r1"), "kind": .string("text"),
                                 "bounds": .object(["x": .number(10), "y": .number(20),
                                                    "width": .number(40), "height": .number(20)]),
                                 "text": .string("K"), "confidence": .number(0.9),
                                 "interactive": .bool(true)])])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "click the biggest K",
                                                    pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(criteria(asked.value[0]).contains("vclick_r1"),
                      "a thin AX pool fuses visual lanes without waiting for stuck")
        XCTAssertEqual(calls.value.first { $0.0 == "get_window_state" }?.1["include_screenshot"],
                       .bool(false), "the ordinary observe never pays for pixels")
        guard let click = calls.value.first(where: { $0.0 == "click" })?.1 else {
            return XCTFail("the visual lane must dispatch a real click")
        }
        XCTAssertEqual(click["capture_id"], .string("cap1"))
    }

    /// The "Yanky" trap: the judge alternates an element lane and a visual
    /// lane at the SAME on-screen target — distinct lane ids, so the
    /// consecutive-pick rule never fires. The per-target strike bound must
    /// remove every lane aiming there after a bounded number of
    /// state-changing-less dispatches, whichever identity the pick wore.
    func testAlternatingLanesOnOneTargetHitTheStrikeBound() async throws {
        let stuck = window([element(0, role: "AXButton", label: "Yanky")],
                           extra: ["capture_id": .string("cap1")])
        let parses = Box(0)
        let (loop, calls, asked) = harness(
            states: [stuck],
            steps: { step in
                switch step {
                case 0: return self.answers(next: "vclick_r1")
                case 1: return self.answers(next: "click_0")
                case 2: return self.answers(next: "vclick_r3")
                case 3: return self.answers(next: "vclick_r4")
                default: return self.answers(next: "stuck")
                }
            },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    // Fresh parse, fresh region ids — the live failure the
                    // bound exists for: every pick carries a new id|text
                    // pair the consecutive re-pick rule cannot see.
                    parses.value += 1
                    return .object(["regions": .array([
                        .object(["id": .string("r\(parses.value)"), "kind": .string("text"),
                                 "bounds": .object(["x": .number(10), "y": .number(20),
                                                    "width": .number(40), "height": .number(20)]),
                                 "text": .string("Yanky"), "confidence": .number(0.9),
                                 "interactive": .bool(true)])])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "click yanky",
                                                    pid: 7, windowID: 42))
        guard case .blocked = result.status else {
            return XCTFail("expected blocked once the dead target is banned, got \(result.status)")
        }
        XCTAssertEqual(calls.value.filter { $0.0 == "click" }.count, 4,
                       "bounded strikes — no twelve-step hammering of one dead target")
        let finalCriteria = criteria(asked.value[asked.value.count - 1])
        XCTAssertFalse(finalCriteria.contains("vclick_r1"),
                       "the visual lane at the dead target leaves the offer set")
        XCTAssertFalse(finalCriteria.contains("click_0"),
                       "the element lane at the dead target leaves the offer set")
    }

    /// "click X" with no app means the thing on screen: the loop binds the
    /// frontmost app's window instead of refusing the goal for want of a
    /// named target. The test host IS the frontmost app here, so a nil-app
    /// task that reaches the observe/judge loop proves the binding.
    func testAppLessGoalBindsTheFrontmostWindow() async throws {
        let surface = window([element(0, role: "AXButton", label: "Yanky")])
        let (loop, calls, _) = harness(
            states: [surface],
            steps: { step in step == 0
                ? self.answers(next: "click_0")
                : self.answers(next: "done") },
            windowRows: [.object(["window_id": .number(9),
                                  "is_on_screen": .bool(true)])])
        let result = try await loop.drive(DriveTask(goal: "click yanky"))
        XCTAssertTrue(calls.value.contains { $0.0 == "get_window_state" },
                      "an app-less goal must reach the observe/judge loop, not refuse")
        XCTAssertEqual(result.status, .done)
    }

    /// The converse invariant: an adequate AX pool — at least the element
    /// floor plus a goal-matched lane — must not grow the judge's option
    /// space with pixels. No screenshot read, no parse, ever.
    func testAdequateAXNeverRunsVisualParse() async throws {
        let elements = (0..<9).map { element($0, role: "AXButton", label: "filler \($0)") }
            + [element(9, role: "AXButton", label: "Save File")]
        let (loop, calls, _) = harness(
            states: [window(elements)],
            steps: { step in step == 0
                ? self.answers(next: "click_9")
                : self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "save the file", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertFalse(calls.value.contains { $0.0 == "parse_visual_regions" },
                       "an adequate AX pool never pays for the visual pass")
        XCTAssertFalse(calls.value.contains {
            $0.0 == "get_window_state" && $0.1["include_screenshot"] == .bool(true) },
                       "no read buys a screenshot it does not need")
    }

    /// A scroll on a window AX cannot read reveals new pixels even when
    /// the tree itself looks identical: the post-scroll observation
    /// re-arms visual candidates on a FRESH capture — the stale one is
    /// never reused.
    func testScrollOnSparseWindowReArmsVisualCandidates() async throws {
        var parses = 0
        let (loop, calls, asked) = harness(
            states: [window([]),
                     window([], extra: ["capture_id": .string("cap1")]),
                     window([]),
                     window([], extra: ["capture_id": .string("cap2")]),
                     window([])],
            steps: { step in
                switch step {
                case 0: return self.answers(next: "scroll_down")
                case 1: return self.answers(next: "vclick_r2")
                default: return self.answers(next: "done")
                }
            },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    parses += 1
                    return .object(["regions": .array([
                        .object(["id": .string("r\(parses)"), "kind": .string("text"),
                                 "bounds": .object(["x": .number(0),
                                                    "y": .number(parses == 1 ? 0 : 50),
                                                    "width": .number(10), "height": .number(10)]),
                                 "text": .string(parses == 1 ? "top" : "bottom"),
                                 "confidence": .number(0.9),
                                 "interactive": .bool(true)])])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "click the bottom entry",
                                                    pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(parses, 2,
                       "the post-scroll observation pays for a fresh visual read")
        XCTAssertTrue(criteria(asked.value[1]).contains("vclick_r2"))
        XCTAssertEqual(calls.value.filter { $0.0 == "parse_visual_regions" }
                        .map { $0.1["capture_id"] }, [.string("cap1"), .string("cap2")])
        guard let click = calls.value.first(where: { $0.0 == "click" })?.1 else {
            return XCTFail("the refreshed visual lane must dispatch a real click")
        }
        XCTAssertEqual(click["capture_id"], .string("cap2"),
                       "the refreshed regions ride the new capture, never a stale one")
    }

    /// On an adequate AX window the fused pass never ran, so the stuck
    /// verdict pays for exactly one visual read — and finding nothing,
    /// the run blocks honestly instead of inventing an action.
    func testStuckVerdictBlocksWhenEscalationFindsNothing() async throws {
        let elements = (0..<9).map { element($0, role: "AXButton", label: "filler \($0)") }
            + [element(9, role: "AXButton", label: "Biggest")]
        let (loop, calls, _) = harness(
            states: [window(elements),
                     window([], extra: ["capture_id": .string("cap1")])],
            steps: { _ in self.answers(next: "stuck") },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    return .object(["regions": .array([])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "click the biggest K",
                                                    pid: 7, windowID: 42))
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(calls.value.filter { $0.0 == "parse_visual_regions" }.count, 1,
                       "the stuck escalation pays for exactly one bounded visual read")
        XCTAssertFalse(calls.value.contains { $0.0 == "click" })
    }
}
