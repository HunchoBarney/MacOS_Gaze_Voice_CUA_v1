import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaAgentLoopDriveTests: XCTestCase {

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

    /// A loop whose driver + judge are canned. `states` are served in order
    /// (the last repeats); `steps` answer the judge per step.
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
            return try dispatch(name, args)
        }
        let judge: CuaTaskAgent.Judge = { _, questions in
            asked.value.append(questions)
            return steps(asked.value.count - 1)
        }
        return (CuaAgentLoop(call: call, judge: judge), calls, asked)
    }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func criteria(_ questions: [String: Question]) -> Set<String> {
        guard let question = questions["next"],
              case .choice(_, let criteria) = question else { return [] }
        return Set(criteria.keys)
    }

    func testDoneWithProvenEvidenceReturnsDone() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Save")])],
            steps: { _ in self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "save the file", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.pid, 7)
        XCTAssertEqual(result.windowID, 42)
    }

    func testDeniedLabelIsNeverOffered() async throws {
        let (loop, _, asked) = harness(
            states: [window([element(0, role: "AXButton", label: "Save"),
                             element(1, role: "AXButton", label: "Delete")])],
            steps: { _ in self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "save", pid: 7, windowID: 42, deny: ["delete"]))
        XCTAssertEqual(result.status, .done)
        let offered = criteria(asked.value[0])
        XCTAssertTrue(offered.contains("click_0"))
        XCTAssertFalse(offered.contains("click_1"))
    }

    func testDeniedTextInAnswerStopsDispatch() async throws {
        var dispatched = false
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Account",
                                   extra: ["description": .string("Delete account")])])],
            steps: { _ in self.answers(next: "click_0") },
            dispatch: { _, _ in dispatched = true; return .object(["effect": .string("confirmed")]) })
        let result = try await loop.drive(DriveTask(goal: "manage", pid: 7, windowID: 42, deny: ["delete"]))
        XCTAssertEqual(result.status, .handedBack(.untrustedAnswer))
        XCTAssertFalse(dispatched)
    }

    func testValuesFlowTypesOnlyCallerText() async throws {
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXTextField", label: "Search"),
                             element(1, role: "AXStaticText", label: "Done")]),
                     window([element(0, role: "AXTextField", label: "Search",
                                     extra: ["value": .string("weather")])])],
            steps: { step in step == 0
                ? self.answers(next: "typeinto_0", fill: "query")
                : self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "search", pid: 7, windowID: 42,
                                                    values: ["query": "weather"]))
        XCTAssertEqual(result.status, .done)
        let typed = calls.value.first { $0.0 == "type_text" }?.1
        XCTAssertEqual(typed?["text"], .string("weather"))
        XCTAssertEqual(typed?["element_token"], .string("tok0"))
        XCTAssertEqual(typed?["delivery_mode"], .string("background"))
        XCTAssertEqual(typed?["window_id"], .number(42))
    }

    func testUnsuppliedFieldEndsAsNeedsText() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXTextField", label: "To")])],
            steps: { _ in self.answers(next: "typeinto_0", fill: "unavailable") })
        let result = try await loop.drive(DriveTask(goal: "compose", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .needsText(fieldLabel: "To"))
    }

    func testLowConfidenceHandsBack() async throws {
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "click_0", confidence: 0.3) })
        let result = try await loop.drive(DriveTask(goal: "go", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .handedBack(.lowConfidence))
        XCTAssertFalse(calls.value.contains { $0.0 == "click" })
    }

    func testInertSnapshotHandsBackNoInteractiveElements() async throws {
        let (loop, _, asked) = harness(
            states: [window([element(0, role: "AXStaticText", label: "nothing")])],
            steps: { _ in self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "read", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .handedBack(.noInteractiveElements))
        XCTAssertTrue(asked.value.isEmpty)
    }

    func testStuckMapsToBlockedWithReason() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Sign in")])],
            steps: { _ in self.answers(next: "stuck", blocked: "authentication") })
        let result = try await loop.drive(DriveTask(goal: "post", pid: 7, windowID: 42))
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("authentication"))
    }

    func testConsentRefusalMapsToBlockedByConsent() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "click_0") },
            dispatch: { _, _ in throw DriverConnectionError.toolRefused(tool: "click", code: "blocked_by_consent") })
        let result = try await loop.drive(DriveTask(goal: "go", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .blockedByConsent("blocked_by_consent"))
    }

    func testMaxStepsReturnsHistory() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "scroll_down") })
        let result = try await loop.drive(DriveTask(goal: "bottom", pid: 7, windowID: 42, maxSteps: 2))
        guard case .maxSteps(let history) = result.status else {
            return XCTFail("expected maxSteps, got \(result.status)")
        }
        XCTAssertEqual(history.count, 2)
    }

    func testInvalidAnswerHandsBackUntrusted() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "click_99") })
        let result = try await loop.drive(DriveTask(goal: "go", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .handedBack(.untrustedAnswer))
    }

    func testUnprovenDoneRetriesThenBlocks() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "done", doneEvidence: "unproven") })
        let result = try await loop.drive(DriveTask(goal: "go", pid: 7, windowID: 42))
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
    }

    func testSuccessContainsGatesDone() async throws {
        let proven = window([element(0, role: "AXStaticText", label: "x",
                                     extra: ["value": .string("Message sent")]),
                             element(1, role: "AXButton", label: "Send")])
        let (loop, _, _) = harness(states: [proven], steps: { _ in self.answers(next: "done") })
        let result = try await loop.drive(DriveTask(goal: "send", pid: 7, windowID: 42,
                                                    successContains: ["sent"]))
        XCTAssertEqual(result.status, .done)
    }

    func testSuspectedNoopArmsPixelLaneWithScreenshotSpace() async throws {
        let framed = element(0, role: "AXButton", label: "Go", extra: [
            "frame": .object(["x": .number(10), "y": .number(10), "w": .number(40), "h": .number(20)])])
        let snap = window([framed], extra: [
            "window_bounds": .object(["x": .number(0), "y": .number(0),
                                      "width": .number(800), "height": .number(600)]),
            "screenshot_width": .number(1600), "screenshot_height": .number(1200)])
        let (loop, calls, asked) = harness(
            states: [snap, snap],
            steps: { step in step == 0 ? self.answers(next: "click_0") : self.answers(next: "done") },
            dispatch: { name, _ in
                name == "click"
                    ? .object(["effect": .string("suspected_noop"),
                               "escalation": .object(["target": .string("pixel"),
                                                      "reason": .string("suspected_noop")])])
                    : .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "go", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        let secondRead = calls.value.filter { $0.0 == "get_window_state" }[1].1
        XCTAssertEqual(secondRead["include_screenshot"], .bool(true))
        XCTAssertTrue(criteria(asked.value[1]).contains("pixel_0"))
    }

    func testApplicationLaunchesAndPinsReturnedWindow() async throws {
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Go")])],
            steps: { _ in self.answers(next: "done") },
            dispatch: { name, _ in
                name == "launch_app"
                    ? .object(["pid": .number(55), "name": .string("TestApp"),
                               "bundle_id": .string("com.test.app"),
                               "windows": .array([.object(["window_id": .number(9),
                                                           "title": .string("Doc"),
                                                           "is_on_screen": .bool(true)])])])
                    : .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "work", application: "com.test.app"))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.pid, 55)
        XCTAssertEqual(result.windowID, 9)
        XCTAssertTrue(calls.value.contains { $0.0 == "launch_app" })
        XCTAssertEqual(calls.value.first { $0.0 == "get_window_state" }?.1["window_id"], .number(9))
    }
}
