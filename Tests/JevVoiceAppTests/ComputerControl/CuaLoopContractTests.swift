import XCTest
import JevVoiceCore
@testable import JevVoice

/// Contract tests for the honest observe → judge → dispatch loop:
/// `done` needs a confirmed effect this run, `satisfied` is the
/// zero-effect settle, goal-matching text regions outrank interactive
/// filler under the visual cap, a delivery ack is never proof, the
/// gesture lane ids map to the right driver tools, and one identical
/// re-pick retires the lane from the next offer.
@MainActor
final class CuaLoopContractTests: XCTestCase {

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

    private func region(_ id: String, _ label: String, interactive: Bool = false,
                        x: Double = 10, y: Double = 10) -> JSONValue {
        .object(["id": .string(id), "kind": .string("text"), "text": .string(label),
                 "bounds": .object(["x": .number(x), "y": .number(y),
                                    "width": .number(50), "height": .number(14)]),
                 "confidence": .number(0.9), "interactive": .bool(interactive)])
    }

    /// The screenshot pixel space `pixelPoint` resolves element frames
    /// against — window bounds plus the capture's pixel dims.
    private var pixelSpace: [String: JSONValue] {
        ["window_bounds": .object(["x": .number(0), "y": .number(0),
                                   "width": .number(800), "height": .number(600)]),
         "screenshot_width": .number(800), "screenshot_height": .number(600),
         "capture_id": .string("cap1")]
    }

    private func pick(_ choice: String, _ confidence: Double = 0.9) -> Answer {
        .choice(choice: choice, confidence: confidence, probabilities: [choice: confidence])
    }

    private func answers(next: String, confidence: Double = 0.9,
                         doneEvidence: String = "proven",
                         blocked: String = "other") -> [String: Answer] {
        ["next": pick(next, confidence), "fill": pick("unavailable"),
         "doneEvidence": pick(doneEvidence), "blockedReason": pick(blocked)]
    }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func harness(states: [JSONValue],
                         steps: @escaping (Int) -> [String: Answer],
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
            return try dispatch(name, args)
        }
        let judge: CuaTaskAgent.Judge = { _, questions in
            asked.value.append(questions)
            return steps(asked.value.count - 1)
        }
        return (CuaAgentLoop(call: call, judge: judge,
                             isFrontmostApp: { _ in true }), calls, asked)
    }

    private func criteria(_ questions: [String: Question]) -> Set<String> {
        guard let question = questions["next"],
              case .choice(_, let criteria) = question else { return [] }
        return Set(criteria.keys)
    }

    // MARK: - Honest settle semantics

    /// "Says done but nothing happened": a judge `done` pick with zero
    /// confirmed effects dispatched this run must settle `.blocked`,
    /// never `.done` — and say why.
    func testDoneWithoutEffectSettlesBlocked() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "tap the button",
                                                    pid: 7, windowID: 42))
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertFalse(result.dispatchedEffect)
        XCTAssertEqual(result.blockedReason, "claimed done before acting")
    }

    /// The zero-effect settle: the judge says the observed state already
    /// fulfills the request — `.alreadySatisfied`, with no effect claimed.
    func testSatisfiedLaneSettlesAlreadySatisfied() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "satisfied") })
        let result = try await loop.drive(DriveTask(goal: "tap the button",
                                                    pid: 7, windowID: 42))
        guard case .alreadySatisfied(let reason) = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(result.dispatchedEffect)
    }

    /// A success_contains string readable on the very first observation
    /// was already true — not done BY this run.
    func testSuccessContainsBeforeAnyDispatchAlreadySatisfied() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "42")])],
            steps: { _ in self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "compute six times seven",
                                                    pid: 7, windowID: 42,
                                                    successContains: ["42"]))
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        XCTAssertFalse(result.dispatchedEffect)
    }

    // MARK: - Delivery ack is not proof

    /// A `verified: true` receipt — top-level AND nested — without
    /// `effect: confirmed` is a delivery acknowledgement, not a dispatched
    /// effect: the run still has nothing it may call `done`.
    func testVerifiedTrueAloneIsNotProof() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { step in step == 0
                ? self.answers(next: "click_0")
                : self.answers(next: "done") },
            dispatch: { name, _ in
                if name == "click" {
                    return .object(["verified": .bool(true),
                                    "exact_window_effect": .object(["verified": .bool(true)])])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "tap the button",
                                                    pid: 7, windowID: 42))
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertFalse(result.dispatchedEffect,
                       "a bare verified:true ack must never mint a confirmed effect")
    }

    /// The other side of the same gate: `effect: confirmed` does count —
    /// a backed `done` settles `.done` with dispatchedEffect true.
    func testConfirmedEffectEnablesDone() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { step in step == 0
                ? self.answers(next: "click_0")
                : self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "tap the button",
                                                    pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
    }

    // MARK: - Goal-ranked visual regions

    /// 30 interactive filler regions plus one non-interactive "Yanky" row:
    /// under interactive-first ranking the cap drops the goal word; under
    /// goal-first ranking it leads the offered set — a text-only region
    /// is a valid vclick target when its label names the goal.
    func testGoalMatchedTextRegionSurvivesVisualCap() async throws {
        var regions = (0..<30).map {
            region("r\($0)", "filler \($0)", interactive: true, y: Double($0 * 20))
        }
        regions.append(region("r_yanky", "Yanky", interactive: false, y: 700))
        let (loop, _, asked) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")],
                            extra: ["capture_id": .string("cap1")])],
            steps: { _ in self.answers(next: "stuck") },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    return .object(["regions": .array(regions)])
                }
                return .object(["effect": .string("confirmed")])
            })
        _ = try await loop.drive(DriveTask(goal: "open yanky chat",
                                           pid: 7, windowID: 42))
        let offered = criteria(asked.value[0])
        XCTAssertTrue(offered.contains("vclick_r_yanky"),
                      "the goal-named text region must rank inside the visual cap")
        XCTAssertTrue(offered.contains("vdclick_r_yanky")
                      && offered.contains("vrclick_r_yanky"),
                      "gesture lanes ride the same goal-matched region")
    }

    // MARK: - Gesture lane dispatch

    /// AX gesture ids map to their driver tools: dclick_# → double_click,
    /// rclick_# → right_click (element_token path), drag_<i>_to_<j> →
    /// drag between the elements' pixel centers — foreground, the only
    /// delivery macOS supports for drag.
    func testAXGestureLanesDispatch() async throws {
        let frame: [String: JSONValue] = ["x": .number(100), "y": .number(100),
                                          "w": .number(40), "h": .number(20)]
        let frame2: [String: JSONValue] = ["x": .number(300), "y": .number(300),
                                           "w": .number(40), "h": .number(20)]
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Target"),
                             element(1, role: "AXButton", label: "Alpha",
                                     extra: ["frame": .object(frame)]),
                             element(2, role: "AXButton", label: "Beta",
                                     extra: ["frame": .object(frame2)])],
                            extra: pixelSpace)],
            steps: { step in
                switch step {
                case 0: return self.answers(next: "dclick_0")
                case 1: return self.answers(next: "rclick_0")
                case 2: return self.answers(next: "drag_1_to_2")
                default: return self.answers(next: "done")
                }
            })
        let result = try await loop.drive(DriveTask(goal: "gestures on target; drag alpha onto beta",
                                                    pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        let doubleClick = calls.value.first { $0.0 == "double_click" }
        XCTAssertEqual(doubleClick?.1["element_token"], .string("tok0"))
        XCTAssertEqual(doubleClick?.1["delivery_mode"], .string("background"))
        let rightClick = calls.value.first { $0.0 == "right_click" }
        XCTAssertEqual(rightClick?.1["element_token"], .string("tok0"))
        let drag = calls.value.first { $0.0 == "drag" }
        XCTAssertEqual(drag?.1["window_id"], .number(42))
        XCTAssertEqual(drag?.1["delivery_mode"], .string("foreground"),
                       "macOS refuses background drags — the lane must front the window")
        XCTAssertEqual(drag?.1["from_x"], .number(120))
        XCTAssertEqual(drag?.1["from_y"], .number(110))
        XCTAssertEqual(drag?.1["to_x"], .number(320))
        XCTAssertEqual(drag?.1["to_y"], .number(310))
    }

    /// Visual gesture ids map to pixel coordinates on the same tools —
    /// vdclick_/vrclick_ click the region center, vdrag_ drags region
    /// center to region center.
    func testVisualGestureLanesDispatch() async throws {
        let regions: [JSONValue] = [
            region("r_yanky", "Yanky"),
            region("r_alpha", "Alpha", x: 100, y: 100),
            region("r_beta", "Beta", x: 300, y: 300)]
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")],
                            extra: ["capture_id": .string("cap1")])],
            steps: { step in
                switch step {
                case 0: return self.answers(next: "vdclick_r_yanky")
                case 1: return self.answers(next: "vrclick_r_yanky")
                case 2: return self.answers(next: "vdrag_r_alpha_to_r_beta")
                default: return self.answers(next: "done")
                }
            },
            dispatch: { name, _ in
                if name == "parse_visual_regions" {
                    return .object(["regions": .array(regions)])
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "yanky alpha beta drag",
                                                    pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        let doubleClick = calls.value.first { $0.0 == "double_click" }
        XCTAssertNil(doubleClick?.1["element_token"],
                     "a visual lane clicks pixels, not an element")
        XCTAssertEqual(doubleClick?.1["x"], .number(35))
        XCTAssertEqual(doubleClick?.1["y"], .number(17))
        XCTAssertNotNil(calls.value.first { $0.0 == "right_click" }?.1["x"])
        let drag = calls.value.first { $0.0 == "drag" }
        XCTAssertEqual(drag?.1["from_x"], .number(125))
        XCTAssertEqual(drag?.1["to_x"], .number(325))
    }

    // MARK: - The one replay rule

    /// click_0 picked twice in a row: the second pick fires its last
    /// dispatch and the lane leaves the next offer set — no counters,
    /// no ledgers, just one rule.
    func testIdenticalRePickRetiresLane() async throws {
        let (loop, calls, asked) = harness(
            states: [window([element(0, role: "AXButton", label: "Go"),
                             element(1, role: "AXButton", label: "Stop")])],
            steps: { step in
                switch step {
                case 0, 1: return self.answers(next: "click_0")
                case 2: return self.answers(next: "click_1")
                default: return self.answers(next: "done")
                }
            })
        let result = try await loop.drive(DriveTask(goal: "press the buttons",
                                                    pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter {
            $0.0 == "click" && $0.1["element_token"] == .string("tok0") }.count, 2,
            "the re-picked lane fires its last dispatch, then leaves")
        XCTAssertFalse(criteria(asked.value[2]).contains("click_0"),
                       "the identical re-pick retires the lane from the next offer")
        XCTAssertTrue(criteria(asked.value[2]).contains("click_1"))
    }
}
