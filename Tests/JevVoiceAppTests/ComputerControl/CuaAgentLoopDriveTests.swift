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
    /// (the last repeats); `steps` answer the judge per step. `listWindows`,
    /// when given, answers each list_windows call by index (0-based).
    private func harness(states: [JSONValue],
                         steps: @escaping (Int) -> [String: Answer],
                         listWindows: ((Int) -> JSONValue)? = nil,
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
            // Observation calls are not dispatches — the pid-only target path
            // consults list_apps to recover bundle identity.
            if name == "list_apps" { return .object(["apps": .array([])]) }
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
        let result = try await loop.drive(DriveTask(goal: "read", pid: 7, windowID: 42,
                                                    values: ["query": "weather"]))
        XCTAssertEqual(result.status, .handedBack(.noInteractiveElements))
        XCTAssertTrue(asked.value.isEmpty)
    }

    /// The converse of the payload gate: with nothing pending the judge still
    /// sees done/stuck for an inert window — a readable state can honestly
    /// satisfy or honestly block the request.
    func testInertSnapshotWithoutPayloadStillReachesJudge() async throws {
        let (loop, _, asked) = harness(
            states: [window([element(0, role: "AXStaticText", label: "nothing")])],
            steps: { _ in self.answers(next: "stuck", blocked: "other") })
        let result = try await loop.drive(DriveTask(goal: "read", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .blocked("The task could not be completed from pid 7's current state (other). Nothing further was dispatched."))
        XCTAssertFalse(asked.value.isEmpty)
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
            dispatch: { _, _ in throw DriverConnectionError.toolRefused(tool: "click", code: "blocked_by_consent", detail: "") })
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

    /// Window registration lags the dispatch that caused it: a create-scope
    /// mutation whose first post-dispatch listing shows only the baseline must
    /// settle and re-list once — the produced window then steals the pin and
    /// the done gate can pass on it.
    func testCreateScopeSettlesAndFindsProducedWindow() async throws {
        let oldDoc = JSONValue.object(["window_id": .number(42), "title": .string("Old Doc"),
                                       "is_on_screen": .bool(true)])
        let newDoc = JSONValue.object(["window_id": .number(99), "title": .string("Untitled"),
                                       "is_on_screen": .bool(true)])
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Body")]),
                     window([element(0, role: "AXButton", label: "Body")])],
            steps: { step in step == 0
                ? self.answers(next: "hotkey_cmd+n")
                : self.answers(next: "done") },
            listWindows: { index in
                index < 2
                    ? .object(["windows": .array([oldDoc])])
                    : .object(["windows": .array([oldDoc, newDoc])])
            })
        let result = try await loop.drive(DriveTask(goal: "new document", pid: 7, scope: .create))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.windowID, 99)
        let reads = calls.value.filter { $0.0 == "get_window_state" }
        XCTAssertEqual(reads.last?.1["window_id"], .number(99))
    }

    /// A create-scope done claim pinned to a baseline window is vetoed even
    /// when the judge insists the outcome is proven — the bound window
    /// pre-existed, so nothing the task produced can be claimed.
    func testCreateScopeBaselinePinVetoesDone() async throws {
        let oldDoc = JSONValue.object(["window_id": .number(42), "title": .string("Old Doc"),
                                       "is_on_screen": .bool(true)])
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Body")])],
            steps: { _ in self.answers(next: "done") },
            listWindows: { _ in .object(["windows": .array([oldDoc])]) })
        let result = try await loop.drive(DriveTask(goal: "new document", pid: 7, scope: .create,
                                                    maxSteps: 4))
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("never produced"))
    }

    /// A window the task's own launch produced is not baseline: fresh-launch
    /// create scope can prove done on it (an empty baseline is the correct
    /// pre-task set for an app that was not running).
    func testCreateScopeLaunchWindowIsNotBaseline() async throws {
        let (loop, _, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Body")])],
            steps: { _ in self.answers(next: "done") },
            dispatch: { name, _ in
                name == "launch_app"
                    ? .object(["pid": .number(55), "name": .string("TestApp"),
                               "bundle_id": .string("com.test.app"),
                               "windows": .array([.object(["window_id": .number(9),
                                                           "title": .string("Untitled"),
                                                           "is_on_screen": .bool(true)])])])
                    : .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "new document", application: "com.test.app",
                                                    scope: .create))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.windowID, 9)
    }

    /// A `same_pid_keyboard_ambiguity` refusal doesn't kill keyboard lanes:
    /// the bound window is re-raised and the next dispatch rides
    /// `delivery_mode: foreground` — the only posture the driver can prove
    /// for app-level input in a multi-window app.
    func testWindowInputAmbiguityEscalatesToForegroundDelivery() async throws {
        var hotkeyCalls = 0
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXButton", label: "Body")])],
            steps: { step in step < 2
                ? self.answers(next: "hotkey_cmd+n")
                : self.answers(next: "done") },
            dispatch: { name, _ in
                if name == "hotkey" {
                    hotkeyCalls += 1
                    if hotkeyCalls == 1 {
                        throw DriverConnectionError.toolRefused(tool: "hotkey", code: "same_pid_keyboard_ambiguity", detail: "")
                    }
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "new document", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        let hotkeys = calls.value.filter { $0.0 == "hotkey" }
        XCTAssertEqual(hotkeys.count, 2)
        XCTAssertEqual(hotkeys[0].1["delivery_mode"], .string("background"))
        XCTAssertEqual(hotkeys[1].1["delivery_mode"], .string("foreground"))
    }

    /// The same ambiguity while the app is *not* frontmost: dispatch raises
    /// the bound window, verifies the app came to the front, then delivers
    /// the keystroke foreground — a user-requested task may bring its target
    /// forward; it may never fire a blind keystroke.
    func testWindowInputAmbiguityRaisesThenDeliversForeground() async throws {
        var hotkeyCalls = 0
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXTextArea", label: "Body")])],
            steps: { step in step < 2
                ? self.answers(next: "hotkey_cmd+n")
                : self.answers(next: "done") },
            frontmost: false,
            dispatch: { name, _ in
                if name == "hotkey" {
                    hotkeyCalls += 1
                    if hotkeyCalls == 1 {
                        throw DriverConnectionError.toolRefused(tool: "hotkey", code: "same_pid_keyboard_ambiguity", detail: "")
                    }
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "new document", pid: 7, windowID: 42,
                                                  foreground: true))
        XCTAssertEqual(result.status, .done)
        let hotkeys = calls.value.filter { $0.0 == "hotkey" }
        XCTAssertEqual(hotkeys.count, 2)
        XCTAssertEqual(hotkeys[0].1["delivery_mode"], .string("background"))
        XCTAssertEqual(hotkeys[1].1["delivery_mode"], .string("foreground"))
        XCTAssertEqual(calls.value.filter { $0.0 == "bring_to_front" }.count, 2,
                       "Once at drive start (foreground task), once at the ambiguity escalation")
    }

    /// A background-posture task on a non-frontmost app may not steal the
    /// user's foreground: once the driver reports window ambiguity its
    /// window-input lanes leave the offer set rather than raise.
    func testBackgroundTaskNeverRaisesForAmbiguousWindowInput() async throws {
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXTextArea", label: "Body")])],
            steps: { step in step == 0
                ? self.answers(next: "hotkey_cmd+n")
                : self.answers(next: "done") },
            frontmost: false,
            dispatch: { name, _ in
                if name == "hotkey" {
                    throw DriverConnectionError.toolRefused(tool: "hotkey", code: "same_pid_keyboard_ambiguity", detail: "")
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "new document", pid: 7, windowID: 42))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter { $0.0 == "bring_to_front" }.count, 0,
                       "A background task must never raise its target window")
        XCTAssertEqual(calls.value.filter { $0.0 == "hotkey" }.count, 1,
                       "The only hotkey call is the refused one — withheld lanes cannot be picked again")
    }

    /// A raise that cannot verify the app came to the front is a bounded
    /// dispatch failure — the keystroke is never sent blind into a window
    /// the driver could not pin.
    func testWindowInputAmbiguityNeverFiresABlindKeystroke() async throws {
        let (loop, calls, _) = harness(
            states: [window([element(0, role: "AXTextArea", label: "Body")])],
            steps: { step in step == 0
                ? self.answers(next: "hotkey_cmd+n")
                : self.answers(next: "done") },
            frontmost: false, raiseMakesFrontmost: false,
            dispatch: { name, _ in
                if name == "hotkey" {
                    throw DriverConnectionError.toolRefused(tool: "hotkey", code: "same_pid_keyboard_ambiguity", detail: "")
                }
                return .object(["effect": .string("confirmed")])
            })
        let result = try await loop.drive(DriveTask(goal: "new document", pid: 7, windowID: 42,
                                                  foreground: true))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(calls.value.filter { $0.0 == "hotkey" }.count, 1,
                       "The only hotkey call is the refused one — no blind retry")
    }
}
