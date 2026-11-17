import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: one observe → choose → dispatch loop with honest outcomes.
/// These tests drive the loop against a scripted driver and scripted
/// judge — every assertion is about observable status, not internals.
final class DriveLoopTests: XCTestCase {

    /// A scripted driver: `responses` maps tool name → ordered results;
    /// `calls` records every (tool, args) pair the loop dispatched.
    final class FakeDriver: @unchecked Sendable {
        var calls: [(tool: String, args: [String: JSONValue])] = []
        var responses: [String: [JSONValue]] = [:]
        var errors: [String: Error] = [:]
        /// One-shot failures — thrown once, then the tool succeeds normally.
        var errorsOnce: [String: Error] = [:]
        var snapshotForRound: (Int) -> JSONValue = { _ in emptySnap }
        private(set) var round = 0

        static let emptySnap: JSONValue = .object([
            "window_title": .string("Fixture"),
            "elements": .array([]),
        ])

        static func snap(_ elements: [JSONValue], title: String = "Fixture") -> JSONValue {
            .object(["window_title": .string(title), "elements": .array(elements)])
        }

        static func status(_ message: String, elements: [JSONValue] = []) -> JSONValue {
            snap(elements + [element(999, role: "statictext", label: message, actions: [])])
        }

        static func element(_ index: Int, role: String = "button",
                            label: String, value: String? = nil,
                            token: String? = nil,
                            actions: [String] = ["AXPress"]) -> JSONValue {
            var e: [String: JSONValue] = [
                "element_index": .number(Double(index)),
                "role": .string(role), "label": .string(label),
                "actions": .array(actions.map { .string($0) }),
                "frame": .object(["x": .number(10), "y": .number(10),
                                  "w": .number(80), "h": .number(24)]),
            ]
            if let value { e["value"] = .string(value) }
            if let token { e["element_token"] = .string(token) }
            return .object(e)
        }

        /// Errors that only fire once the tool has succeeded N times — a
        /// transport that dies mid-verify, not at bind time.
        var errorsAfterNCalls: [String: (after: Int, error: Error)] = [:]
        private var callCounts: [String: Int] = [:]

        func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
            calls.append((tool, args))
            let n = (callCounts[tool] ?? 0) + 1
            callCounts[tool] = n
            if let gate = errorsAfterNCalls[tool], n > gate.after { throw gate.error }
            if let error = errorsOnce.removeValue(forKey: tool) { throw error }
            if let error = errors[tool] { throw error }
            if tool == "get_window_state" {
                defer { round += 1 }
                return snapshotForRound(round)
            }
            if var queue = responses[tool], !queue.isEmpty {
                let first = queue.removeFirst()
                responses[tool] = queue
                return first
            }
            // Effects default to confirmed — the driver reported success.
            return .object(["effect": .string("confirmed")])
        }
    }

    /// Assemble a loop whose app/window are already bound — pid+windowID
    /// on the task skip launch_app and list_windows entirely. Bare-id
    /// picks wrap as `JevChoice(id:)` with no confidence and no done
    /// vote — the nil-confidence path stays ungated for stub choosers.
    private func makeLoop(_ driver: FakeDriver,
                          picks: [String?],
                          grant: Bool = true,
                          ask: DriveLoop.AskFn? = nil,
                          config: DriveLoop.Config = .default,
                          gaze: (() async throws -> GazeSample)? = nil,
                          windowControlButtons: ((pid_t) -> [WindowControls.Button])? = nil,
                          windowControlPress: ((WindowControls.Kind, pid_t) -> Bool)? = nil,
                          nativeReadOnly: @escaping NativeWindowObservation.Read = { _, _ in nil })
            -> (DriveLoop, DriveLoop.Call, DriveLoop.Choose) {
        makeLoop(driver, choices: picks.map { $0.map { .pick($0) } },
                 grant: grant, ask: ask, config: config, gaze: gaze,
                 windowControlButtons: windowControlButtons,
                 windowControlPress: windowControlPress, nativeReadOnly: nativeReadOnly)
    }

    /// The full-choice form: confidence and doneVote ride the pick.
    /// Window-control seams default to hermetic stubs — the real ones
    /// open a live AX session against whatever pid the fixture carries.
    private func makeLoop(_ driver: FakeDriver,
                          choices: [DriveLoop.JevChoice?],
                          grant: Bool = true,
                          ask: DriveLoop.AskFn? = nil,
                          config: DriveLoop.Config = .default,
                          gaze: (() async throws -> GazeSample)? = nil,
                          windowControlButtons: ((pid_t) -> [WindowControls.Button])? = nil,
                          windowControlPress: ((WindowControls.Kind, pid_t) -> Bool)? = nil,
                          nativeReadOnly: @escaping NativeWindowObservation.Read = { _, _ in nil })
            -> (DriveLoop, DriveLoop.Call, DriveLoop.Choose) {
        var pickQueue = choices
        let call: DriveLoop.Call = { tool, args in try driver.call(tool, args) }
        let choose: DriveLoop.Choose = { _, _ in
            if pickQueue.isEmpty { return nil }
            // A deliberately-invalid pick must not be silently mapped —
            // the loop treats it as an invalid answer.
            return pickQueue.removeFirst()
        }
        // A fresh resurrector per loop — rotations stick for a daemon's
        // lifetime, so sharing the production singleton would leak label
        // state between tests.
        let loop = DriveLoop(call: call, choose: choose, ask: ask,
                             granted: { grant }, config: config, gaze: gaze,
                             windowControlButtons: windowControlButtons ?? { _ in [] },
                             windowControlPress: windowControlPress ?? { _, _ in false },
                             resurrector: SessionResurrector(), nativeReadOnly: nativeReadOnly)
        return (loop, call, choose)
    }

    // MARK: - Outcomes

    private func exactWindowLoop(_ driver: FakeDriver,
                                 choose: @escaping DriveLoop.Choose = { _, _ in nil },
                                 postMedia: @escaping (MediaKeys.Key) -> Bool = { _ in false },
                                 scopedButtons: @escaping (pid_t, Int) -> [WindowControls.Button] = { _, _ in [] },
                                 scopedPress: @escaping (WindowControls.Kind, pid_t, Int) -> Bool = { _, _, _ in false })
        -> DriveLoop {
        DriveLoop(call: { try driver.call($0, $1) }, choose: choose,
                  ask: nil, granted: { true },
                  resolver: AppResolver(listApps: {
                      [.init(name: "Owned Editor", bundle: "test.owned.editor", pid: 42)]
                  }), config: .init(windowOnly: true), postMediaKey: postMedia,
                  windowControlButtons: { _ in XCTFail("unscoped discovery"); return [] },
                  windowControlPress: { _, _ in XCTFail("unscoped press"); return false },
                  windowControlButtonsInWindow: scopedButtons,
                  windowControlPressInWindow: scopedPress,
                  resurrector: SessionResurrector(), nativeReadOnly: { _, _ in nil })
    }

    func testExactWindowScopeRefusesEmptyOrForeignInventoryBeforeObservation() async {
        for rows: [JSONValue] in [[], [.object([
            "window_id": .number(7), "pid": .number(999),
        ])]] {
            let driver = FakeDriver()
            driver.responses["list_windows"] = [.object(["windows": .array(rows)])]
            let result = await exactWindowLoop(driver).run(
                DriveTask(goal: "Replace document text", pid: 42, windowID: 7), session: "exact")
            guard case .blocked = result.status else { return XCTFail("\(result.status)") }
            XCTAssertFalse(driver.calls.contains { ["get_window_state", "launch_app", "bring_to_front"].contains($0.tool) })
        }
    }

    func testR7WindowOnlyDoesNotBroadenOtherFastLanesOrDropScrollConditions() async {
        let goals = ["mute", "lock screen", "copy", "type hello", "open Calculator",
                     "search for Cedar", "move window left", "scroll down and click Save",
                     "don't scroll down", "she said scroll down", "did you scroll down",
                     "scroll the sidebar down", "scroll down until Cedar is visible",
                     "scroll down exactly three pages"]
        for goal in goals {
            let driver = FakeDriver()
            driver.responses["list_windows"] = [.object(["windows": .array([.object([
                "window_id": .number(7), "pid": .number(42), "title": .string("Owned"),
            ])])])]
            let result = await exactWindowLoop(driver, choose: { _, _ in .init(id: "stuck") },
                postMedia: { _ in XCTFail("Window-only cannot post a media key"); return false }).run(
                    DriveTask(goal: goal, application: "test.owned.editor", pid: 42, windowID: 7), session: "r7-exclusions")
            XCTAssertNotEqual(result.status, .done, goal)
            XCTAssertFalse(driver.calls.contains {
                ["scroll", "hotkey", "type_text", "launch_app", "browser_navigate"].contains($0.tool)
            }, goal)
        }
        for variant in ["postcondition", "values", "context"] {
            let driver = FakeDriver()
            driver.responses["list_windows"] = [.object(["windows": .array([.object([
                "window_id": .number(7), "pid": .number(42), "title": .string("Owned"),
            ])])])]
            var task = DriveTask(goal: "scroll down", application: "test.owned.editor", pid: 42, windowID: 7)
            if variant == "postcondition" { task.successContains = ["Cedar"] }
            if variant == "values" { task.values["text"] = "Cedar" }
            if variant == "context" { task.previousContext = "Until Cedar is visible." }
            let result = await exactWindowLoop(driver, choose: { _, _ in .init(id: "stuck") }).run(task, session: "r7-conditions")
            XCTAssertNotEqual(result.status, .done, variant)
            XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" }, variant)
        }
    }

    func testExactWindowPreviewNeverSelectsHigherSibling() async throws {
        let driver = FakeDriver()
        driver.responses["list_windows"] = [.object(["windows": .array([
            .object(["window_id": .number(7), "pid": .number(42), "title": .string("Owned"), "z_index": .number(1)]),
            .object(["window_id": .number(8), "pid": .number(42), "title": .string("Sibling"), "z_index": .number(2)]),
        ])])]
        _ = try await exactWindowLoop(driver).preview(
            DriveTask(goal: "Inspect", application: "Owned Editor", windowID: 7), session: "exact")
        let reads = driver.calls.filter { $0.tool == "get_window_state" }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertTrue(reads.allSatisfy { $0.args["window_id"] == .number(7) })
    }

    func testExactWindowScopeDoesNotUseGlobalMediaFastLane() async {
        let driver = FakeDriver()
        driver.responses["list_windows"] = [.object(["windows": .array([
            .object(["window_id": .number(7), "pid": .number(42)]),
        ])])]
        var posts = 0
        _ = await exactWindowLoop(driver, postMedia: { _ in posts += 1; return false }).run(
            DriveTask(goal: "pause", pid: 42, windowID: 7), session: "exact")
        XCTAssertEqual(posts, 0)
    }

    func testExactWindowTrafficLightsUseCapturedWindowNotFocusedSibling() async {
        let driver = FakeDriver()
        driver.responses["list_windows"] = Array(repeating: .object(["windows": .array([
            .object(["window_id": .number(7), "pid": .number(42)]),
        ])]), count: 10)
        var picks = ["wc:close"]
        var presses: [(pid_t, Int)] = []
        let loop = exactWindowLoop(driver, choose: { _, _ in
            picks.isEmpty ? nil : .init(id: picks.removeFirst(), confidence: nil, doneVote: nil)
        }, scopedButtons: { pid, window in
            XCTAssertEqual(pid, 42)
            XCTAssertEqual(window, 7)
            return [.init(kind: .close, frame: .init(x: 10, y: 10, width: 15, height: 15))]
        }, scopedPress: { _, pid, window in
            presses.append((pid, window))
            return false
        })
        _ = await loop.run(DriveTask(goal: "close this document window", pid: 42, windowID: 7), session: "exact")
        XCTAssertEqual(presses.count, 1)
        XCTAssertEqual(presses.first?.0, 42)
        XCTAssertEqual(presses.first?.1, 7)
    }

    private func multiInstanceLoop(
        _ driver: FakeDriver, rows: [Int: [JSONValue]],
        pids: [Int] = [42, 99], bundles: [Int: String] = [:], names: [Int: String] = [:],
        windowOnly: Bool = true,
        postMedia: @escaping (MediaKeys.Key) -> Bool = { _ in false },
        choose: @escaping DriveLoop.Choose = { _, _ in .init(id: "stuck") }
    ) -> DriveLoop {
        let apps = pids.map { pid in
            JSONValue.object(["name": .string(names[pid] ?? "Owned Editor"),
                              "bundle_id": .string(bundles[pid] ?? "test.owned.editor"),
                              "pid": .number(Double(pid))])
        }
        driver.responses["list_apps"] = [.object(["apps": .array(apps)])]
        driver.snapshotForRound = { _ in
            FakeDriver.snap([FakeDriver.element(3, label: "Continue")])
        }
        return DriveLoop(call: { tool, args in
            if tool == "list_windows" {
                driver.calls.append((tool, args))
                if let error = driver.errors[tool] { throw error }
                return .object(["windows": .array(rows[args["pid"]?.integer ?? -1] ?? [])])
            }
            return try driver.call(tool, args)
        }, choose: choose, ask: nil, granted: { true },
        resolver: AppResolver(listApps: {
            pids.map { .init(name: names[$0] ?? "Owned Editor",
                            bundle: bundles[$0] ?? "test.owned.editor", pid: $0) }
        }), config: .init(windowOnly: windowOnly),
        postMediaKey: postMedia,
        activateApp: { _ in XCTFail("pinned binding must not activate another process") },
        windowControlButtons: { _ in [] },
        windowControlButtonsInWindow: { _, _ in [] },
        frontmostBundleID: { "test.owned.editor" }, frontmostPID: { 42 },
        resurrector: SessionResurrector(), nativeReadOnly: { _, _ in nil })
    }

    private func ownerRow(_ pid: Int, _ window: Int = 7) -> JSONValue {
        .object(["pid": .number(Double(pid)), "window_id": .number(Double(window))])
    }

    func testPinnedOwnerRunFindsExactProcessRegardlessOfInstanceOrder() async {
        for order in [[42, 99], [99, 42], [42, 99, 99]] {
            let driver = FakeDriver()
            var judgments = 0
            let loop = multiInstanceLoop(driver, rows: [42: [ownerRow(42, 8)], 99: [ownerRow(99)]],
                                        pids: order, choose: { _, _ in
                judgments += 1
                return .init(id: "stuck")
            })
            let result = await loop.run(
                DriveTask(goal: "Inspect document contents", application: "test.owned.editor", windowID: 7),
                session: "pinned-owner")
            XCTAssertEqual(result.pid, 99)
            XCTAssertEqual(judgments, 1)
            let reads = driver.calls.filter { $0.tool == "get_window_state" }
            XCTAssertFalse(reads.isEmpty)
            XCTAssertTrue(reads.allSatisfy {
                $0.args["pid"] == .number(99) && $0.args["window_id"] == .number(7)
            })
            XCTAssertFalse(driver.calls.contains { ["launch_app", "bring_to_front", "click"].contains($0.tool) })
        }
    }

    func testPinnedOwnerPreviewUsesSameExactProcessBinding() async throws {
        let driver = FakeDriver()
        let loop = multiInstanceLoop(driver, rows: [42: [ownerRow(42, 8)], 99: [ownerRow(99)]])
        _ = try await loop.preview(
            DriveTask(goal: "Inspect document contents", application: "test.owned.editor", windowID: 7),
            session: "pinned-owner")
        let reads = driver.calls.filter { $0.tool == "get_window_state" }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertTrue(reads.allSatisfy {
            $0.args["pid"] == .number(99) && $0.args["window_id"] == .number(7)
        })
        XCTAssertTrue(driver.calls.allSatisfy { ["list_windows", "get_window_state"].contains($0.tool) })
    }

    func testPinnedOwnerFastLaneDoesNotRevertToFirstInstance() async {
        let driver = FakeDriver()
        let loop = multiInstanceLoop(driver, rows: [42: [ownerRow(42, 8)], 99: [ownerRow(99)]],
                                    windowOnly: false, choose: { _, _ in
            XCTFail("the deterministic key must not call inference")
            return nil
        })
        _ = await loop.run(
            DriveTask(goal: "press escape", application: "Owned Editor", windowID: 7),
            session: "pinned-owner")
        let keys = driver.calls.filter { $0.tool == "hotkey" }
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.args["pid"], .number(99))
        XCTAssertEqual(keys.first?.args["window_id"], .number(7))
        XCTAssertFalse(driver.calls.contains { ["launch_app", "bring_to_front"].contains($0.tool) })
    }

    func testPinnedOwnerAmbiguousOrUnprovenClaimsNeverReachModelOrInput() async {
        let invalid: [[Int: [JSONValue]]] = [
            [42: [ownerRow(42, 8)], 99: []],
            [42: [ownerRow(42)], 99: [ownerRow(99)]],
            [42: [], 99: [ownerRow(99), ownerRow(99)]],
            [42: [], 99: [.object(["window_id": .number(7)])]],
            [42: [ownerRow(999)], 99: [ownerRow(99)]],
        ]
        for rows in invalid {
            let driver = FakeDriver()
            let loop = multiInstanceLoop(driver, rows: rows, choose: { _, _ in
                XCTFail("unproven owner must not expose document data to inference")
                return nil
            })
            let result = await loop.run(
                DriveTask(goal: "Inspect document contents", application: "test.owned.editor", windowID: 7),
                session: "pinned-owner")
            guard case .blocked = result.status else { return XCTFail("\(result.status)") }
            XCTAssertTrue(driver.calls.allSatisfy { ["list_apps", "list_windows"].contains($0.tool) })
        }
    }

    func testPinnedOwnerNeverRebindsExplicitProcess() async {
        let driver = FakeDriver()
        let loop = multiInstanceLoop(driver, rows: [42: [ownerRow(42, 8)], 99: [ownerRow(99)]],
                                    choose: { _, _ in XCTFail("explicit owner is unavailable"); return nil })
        let result = await loop.run(
            DriveTask(goal: "Inspect document contents", application: "test.owned.editor", pid: 42, windowID: 7),
            session: "pinned-owner")
        guard case .blocked = result.status else { return XCTFail("\(result.status)") }
        XCTAssertTrue(driver.calls.allSatisfy {
            $0.tool == "list_apps" || ($0.tool == "list_windows" && $0.args["pid"] == .number(42))
        })
    }

    func testPinnedOwnerNeverSelectsMatchingWindowInForeignBundle() async {
        let driver = FakeDriver()
        let loop = multiInstanceLoop(driver, rows: [42: [ownerRow(42, 8)], 99: [ownerRow(99)]],
                                    bundles: [99: "test.foreign.editor"],
                                    choose: { _, _ in XCTFail("foreign app"); return nil })
        let result = await loop.run(
            DriveTask(goal: "Inspect document contents", application: "test.owned.editor", windowID: 7),
            session: "pinned-owner")
        guard case .blocked = result.status else { return XCTFail("\(result.status)") }
        XCTAssertTrue(driver.calls.allSatisfy {
            $0.tool == "list_apps" || ($0.tool == "list_windows" && $0.args["pid"] == .number(42))
        })
    }

    func testPinnedOwnerPreviewRefusesAmbiguousOrUnknownOwnerBeforeReadingDocument() async {
        for rows: [Int: [JSONValue]] in [
            [42: [ownerRow(42)], 99: [ownerRow(99)]],
            [42: [], 99: [.object(["window_id": .number(7)])]],
        ] {
            let driver = FakeDriver()
            let loop = multiInstanceLoop(driver, rows: rows,
                                        choose: { _, _ in XCTFail("unproven preview"); return nil })
            do {
                _ = try await loop.preview(
                    DriveTask(goal: "Inspect document contents", application: "test.owned.editor", windowID: 7),
                    session: "pinned-owner")
            } catch {
                XCTAssertTrue(error is DriverConnectionError)
            }
            XCTAssertTrue(driver.calls.allSatisfy { $0.tool == "list_windows" })
        }
    }

    func testPinnedOwnerReadFailureNeverFallsBackToFirstInstance() async {
        let driver = FakeDriver()
        driver.errors["list_windows"] = DriverConnectionError.remote("fixture read failed")
        let loop = multiInstanceLoop(driver, rows: [42: [ownerRow(42)], 99: [ownerRow(99)]],
                                    choose: { _, _ in XCTFail("owner read failed"); return nil })
        let result = await loop.run(
            DriveTask(goal: "Inspect document contents", application: "test.owned.editor", windowID: 7),
            session: "pinned-owner")
        guard case .blocked = result.status else { return XCTFail("\(result.status)") }
        XCTAssertTrue(driver.calls.allSatisfy { ["list_apps", "list_windows"].contains($0.tool) })
    }

    func testPinnedOwnerLeavesAppFreeMediaLaneFreeOfWindowReads() async {
        let driver = FakeDriver()
        var posts = 0
        let loop = multiInstanceLoop(driver, rows: [:], windowOnly: false,
                                    postMedia: { _ in posts += 1; return true },
                                    choose: { _, _ in XCTFail("media key must not infer"); return nil })
        let result = await loop.run(
            DriveTask(goal: "pause", application: "test.owned.editor", windowID: 7),
            session: "pinned-owner")
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(driver.calls.isEmpty)
    }

    func testPinnedOwnerFastLaneRefusesAContradictoryNamedApp() async {
        let driver = FakeDriver()
        let goal = "press escape in Foreign Editor"
        let loop = multiInstanceLoop(
            driver, rows: [42: [ownerRow(42, 8)], 99: [ownerRow(99)], 111: [ownerRow(111, 9)]],
            pids: [42, 99, 111], bundles: [111: "test.foreign.editor"],
            names: [111: "Foreign Editor"], windowOnly: false,
            choose: { _, _ in XCTFail("contradictory target must not infer"); return nil })
        let apps = driver.responses["list_apps"]?.first?["apps"]?.array ?? []
        XCTAssertEqual(DriveLoop.resolveFastLane(goal: goal, apps: apps,
            appHint: "test.owned.editor", frontmostBundle: "test.owned.editor")?.bundle, "test.foreign.editor")
        let result = await loop.run(
            DriveTask(goal: goal, application: "test.owned.editor", windowID: 7), session: "pinned-owner")
        guard case .blocked = result.status else { return XCTFail("\(result.status)") }
        XCTAssertTrue(driver.calls.allSatisfy { ["list_apps", "list_windows"].contains($0.tool) })
        XCTAssertFalse(driver.calls.contains { $0.args["pid"] == .number(111) })
    }

    func testDeicticBindingUsesForegroundProcessNotFirstSameBundleProcess() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([
            .object(["name": .string("Owned Editor"), "bundle_id": .string("test.owned.editor"),
                     "pid": .number(410001)]),
            .object(["name": .string("Owned Editor"), "bundle_id": .string("test.owned.editor"),
                     "pid": .number(410002)]),
        ])])]
        driver.responses["list_windows"] = [.object(["windows": .array([
            .object(["window_id": .number(7), "is_on_screen": .bool(true)]),
        ])])]
        let loop = DriveLoop(
            call: { try driver.call($0, $1) },
            choose: { _, _ in XCTFail("binding proof must not call inference"); return nil },
            ask: nil, granted: { true }, resolver: AppResolver(listApps: { [] }),
            activateApp: { _ in XCTFail("binding proof must not activate an app") },
            windowControlButtons: { _ in [] },
            frontmostBundleID: { "test.owned.editor" },
            frontmostPID: { 410002 }, frontmostWindowID: { 7 },
            resurrector: SessionResurrector(), nativeReadOnly: { _, _ in nil })
        let result = await loop.run(
            DriveTask(goal: "inspect this window", windowID: 7, scope: .open, foreground: false),
            session: "deictic-process-proof")
        XCTAssertEqual(result.status, .done)
        let targeted = driver.calls.filter { $0.args["pid"] != nil }
        XCTAssertFalse(targeted.isEmpty)
        XCTAssertTrue(targeted.allSatisfy { $0.args["pid"] == .number(410002) },
                      "the older same-bundle process must never become the captured target")
    }

    func testDefaultContinuesPastFourVerifiedSteps() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            FakeDriver.status(round >= 7 ? "Workflow complete" : "Stage \(round)")
        }
        let (loop, _, _) = makeLoop(driver, picks: Array(repeating: "key:return", count: 7) + ["done"])
        let result = await loop.run(DriveTask(goal: "submit each setup stage",
                                            pid: 42, windowID: 7,
                                            successContains: ["Workflow complete"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.calls.filter { $0.tool == "press_key" }.count, 7)
        XCTAssertNil(DriveLoop.Config.default.maxRounds)
    }

    private func readySessionDriver() -> FakeDriver {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in FakeDriver.status("Session ready") }
        return driver
    }

    func testUnverifiableActionsWithObservedProgressContinuePastEight() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            FakeDriver.status(round >= 10 ? "Workflow complete" : "Stage \(round)",
                              elements: [FakeDriver.element(3, label: "Continue")])
        }
        driver.responses["click"] = Array(repeating: .object([
            "effect": .string("unverifiable"),
        ]), count: 10)
        let (loop, _, _) = makeLoop(driver, picks: Array(repeating: "e3", count: 10) + ["done"])
        let result = await loop.run(DriveTask(goal: "complete every installer stage",
                                            pid: 42, windowID: 7,
                                            successContains: ["Workflow complete"]), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.calls.filter { $0.tool == "click" }.count, 10)
        XCTAssertFalse(result.dispatchedEffect)
    }

    func testUnverifiableActionThenObservedGoalIsDoneNotAlreadyTrue() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            FakeDriver.status(round == 0 ? "Setup" : "Workflow complete",
                              elements: [FakeDriver.element(3, label: "Continue")])
        }
        driver.responses["click"] = [.object(["effect": .string("unverifiable")])]
        let (loop, _, _) = makeLoop(driver, picks: ["e3", "done"])
        let result = await loop.run(DriveTask(goal: "complete setup", pid: 42, windowID: 7,
                                            successContains: ["Workflow complete"]), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.calls.filter { $0.tool == "click" }.count, 1)
        XCTAssertFalse(result.dispatchedEffect)
    }

    func testNativeTokenLoopRequestsReportDeferralAndStillObservesBeforeDone() async throws {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            FakeDriver.status(round == 0 ? "Setup" : "Workflow complete",
                elements: [FakeDriver.element(3, label: "Continue", token: "s00000001:3")])
        }
        driver.responses["click"] = [.object(["effect": .string("unverifiable")])]
        let (loop, _, _) = makeLoop(driver, picks: ["e3", "done"])
        let result = await loop.run(DriveTask(goal: "complete setup", pid: 42, windowID: 7,
            successContains: ["Workflow complete"]), session: "owned")
        let index = try XCTUnwrap(driver.calls.firstIndex { $0.tool == "click" })
        XCTAssertEqual(driver.calls[index].args["post_action_wait"], .string("none"))
        XCTAssertEqual(driver.calls[index].args["element_token"], .string("s00000001:3"))
        XCTAssertTrue(driver.calls.dropFirst(index + 1).contains { $0.tool == "get_window_state" })
        XCTAssertEqual(result.status, .done)
        XCTAssertFalse(result.dispatchedEffect)
    }

    func testLegacyElementLoopDoesNotRequestReportDeferral() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            FakeDriver.status(round == 0 ? "Setup" : "Workflow complete",
                elements: [FakeDriver.element(3, label: "Continue")])
        }
        let (loop, _, _) = makeLoop(driver, picks: ["e3", "done"])
        _ = await loop.run(DriveTask(goal: "complete setup", pid: 42, windowID: 7,
            successContains: ["Workflow complete"]), session: "owned")
        XCTAssertEqual(driver.calls.filter { $0.tool == "click" }.count, 1)
        XCTAssertTrue(driver.calls.allSatisfy { $0.args["post_action_wait"] == nil })
    }

    func testUnverifiableActionsWithoutObservedChangeStillStop() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            FakeDriver.snap([FakeDriver.element(3, label: "Continue")])
        }
        driver.responses["click"] = Array(repeating: .object([
            "effect": .string("unverifiable"),
        ]), count: 20)
        let (loop, _, _) = makeLoop(driver, picks: Array(repeating: "e3", count: 20))
        let result = await loop.run(DriveTask(goal: "complete setup", pid: 42, windowID: 7,
                                            successContains: ["Workflow complete"]), session: "t")
        guard case .blocked = result.status else { return XCTFail("stuck actions must stop") }
        XCTAssertLessThanOrEqual(driver.calls.filter { $0.tool == "click" }.count, 3)
    }

    private func readySessionTask() -> DriveTask {
        DriveTask(goal: "check session readiness", pid: 42, windowID: 7,
                  successContains: ["Session ready"])
    }

    /// The goal is already visible on screen → alreadySatisfied, and
    /// crucially `dispatchedEffect` stays false — we never claim "done"
    /// for something we didn't do.
    func testAlreadySatisfiedWhenDoneWithNoEffects() async {
        let driver = readySessionDriver()
        let (loop, _, _) = makeLoop(driver, picks: ["done", "done"])
        let result = await loop.run(readySessionTask(), session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        XCTAssertFalse(result.dispatchedEffect)
        XCTAssertEqual(driver.calls.map(\.tool),
                       ["list_apps", "list_windows", "get_window_state", "get_window_state"])
    }

    /// One confirmed click then done → `.done` with dispatchedEffect true.
    func testDoneAfterConfirmedEffect() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            let buttons = [FakeDriver.element(3, label: "Save")]
            return round == 0 ? FakeDriver.snap(buttons) : FakeDriver.status("File saved", elements: buttons)
        }
        let (loop, _, _) = makeLoop(driver, picks: ["e3", "done"])
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7,
                                             successContains: ["File saved"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(driver.calls.map(\.tool),
                       ["list_apps", "list_windows", "get_window_state", "click",
                        "get_window_state"])
    }

    /// A dead "voice" session label is revived in-band: the rejection
    /// triggers `start_session`, the failed call retries once, and the run
    /// proceeds — no task dies on a stale label.
    func testEndedSessionResurrectsAndRetries() async {
        let driver = readySessionDriver()
        driver.errorsOnce["list_apps"] = DriverConnectionError.refused(
            "session has ended; tool call 'list_apps' was rejected. " +
            "Call start_session with session 't' to start it again, " +
            "or use a new session label.")
        let (loop, _, _) = makeLoop(driver, picks: ["done", "done"])
        let result = await loop.run(readySessionTask(), session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        XCTAssertEqual(driver.calls.map(\.tool),
                       ["list_apps", "start_session", "list_apps",
                        "list_windows", "get_window_state", "get_window_state"])
    }

    /// The real failure shape: the daemon tombstoned 't' while its owner
    /// transport was dead, so `start_session` is REFUSED ("not available
    /// to this transport"). The retry must mint a fresh successor label —
    /// re-dispatching 't' would hit the same tombstone forever.
    func testRefusedResurrectionRotatesSessionLabel() async {
        let driver = readySessionDriver()
        driver.errorsOnce["list_apps"] = DriverConnectionError.refused(
            "session has ended; tool call 'list_apps' was rejected. " +
            "Call start_session with session 't' to start it again, " +
            "or use a new session label.")
        driver.errors["start_session"] = DriverConnectionError.refused(
            "session 't' is not available to this transport")
        let (loop, _, _) = makeLoop(driver, picks: ["done", "done"])
        let result = await loop.run(readySessionTask(), session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        let apps = driver.calls.filter { $0.tool == "list_apps" }
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].args["session"], .string("t"))
        XCTAssertNotEqual(apps[1].args["session"], .string("t"),
                          "a refused revival must rotate to a fresh label")
        // Every later call rides the same successor — the rotation is sticky.
        let windows = driver.calls.filter { $0.tool == "list_windows" }
        XCTAssertEqual(windows.first?.args["session"], apps[1].args["session"])
    }

    /// The owner-mismatch error on the call itself ("session is not
    /// available to this transport" — a live record bound to another
    /// transport) is the same class of death: restart, rotate, proceed.
    func testForeignOwnedSessionRotates() async {
        let driver = readySessionDriver()
        driver.errorsOnce["list_apps"] = DriverConnectionError.refused(
            "session 't' is not available to this transport")
        driver.errors["start_session"] = DriverConnectionError.refused(
            "session 't' is not available to this transport")
        let (loop, _, _) = makeLoop(driver, picks: ["done", "done"])
        let result = await loop.run(readySessionTask(), session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        let apps = driver.calls.filter { $0.tool == "list_apps" }
        XCTAssertNotEqual(apps.last?.args["session"], .string("t"))
    }

    /// Resurrection is bounded AND verified: `start_session` "succeeds"
    /// but every re-dispatch still says the label is dead. The loop gives
    /// up inside the budget and the settle carries the human restart
    /// line — never the daemon's tombstone text — with the marker reason
    /// that lets the coordinator re-run the task once.
    func testDeadSessionRetriesAreBounded() async {
        let driver = FakeDriver()
        driver.errors["list_windows"] = DriverConnectionError.refused(
            "session has ended; tool call 'list_windows' was rejected.")
        let (loop, _, _) = makeLoop(driver, picks: ["done"])
        let result = await loop.run(DriveTask(goal: "check", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked(let why) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(why, DriveLoop.sessionRestartedMessage)
        XCTAssertFalse(why.contains("session has ended"),
                       "raw daemon text never reaches the say")
        XCTAssertEqual(result.blockedReason, DriveLoop.sessionRestartedReason)
        // Original + two resurrection retries — the budget holds.
        XCTAssertEqual(driver.calls.filter { $0.tool == "list_windows" }.count, 3)
        XCTAssertEqual(driver.calls.filter { $0.tool == "start_session" }.count, 2)
    }

    /// A restart that can't reach the daemon (transport dead mid-task)
    /// still settles as the session-death class — the whole-task retry
    /// is the recovery, and the say stays human.
    func testUnreachableRestartSettlesHonestly() async {
        let driver = FakeDriver()
        driver.errorsOnce["list_windows"] = DriverConnectionError.refused(
            "session has ended; tool call 'list_windows' was rejected.")
        driver.errors["start_session"] = DriverConnectionError.closed
        let (loop, _, _) = makeLoop(driver, picks: ["done"])
        let result = await loop.run(DriveTask(goal: "check", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked(let why) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(why, DriveLoop.sessionRestartedMessage)
        XCTAssertEqual(result.blockedReason, DriveLoop.sessionRestartedReason)
    }

    /// Whole-task retry predicate: only a session-death block with NO
    /// confirmed effect is safe to re-run — anything else could
    /// double-apply an uncertain mutation.
    func testSessionDeathSettleIsTheOnlyRetryableOne() {
        let dead = DriveResult(status: .blocked("x"), history: [],
                               dispatchedEffect: false,
                               blockedReason: DriveLoop.sessionRestartedReason)
        XCTAssertTrue(VoiceTaskCoordinator.shouldRetrySessionDeath(dead))
        let deadButEffective = DriveResult(status: .blocked("x"), history: [],
                                           dispatchedEffect: true,
                                           blockedReason: DriveLoop.sessionRestartedReason)
        XCTAssertFalse(VoiceTaskCoordinator.shouldRetrySessionDeath(deadButEffective),
                       "a confirmed effect makes replay unsafe")
        let transport = DriveResult(status: .blocked("x"), history: [],
                                    blockedReason: "transport failure")
        XCTAssertFalse(VoiceTaskCoordinator.shouldRetrySessionDeath(transport))
        let honestRefusal = DriveResult(status: .blocked("no such app"),
                                        history: [], blockedReason: "no such app")
        XCTAssertFalse(VoiceTaskCoordinator.shouldRetrySessionDeath(honestRefusal))
        XCTAssertFalse(VoiceTaskCoordinator.shouldRetrySessionDeath(
            DriveResult(status: .done, history: [], dispatchedEffect: true)))
    }

    /// Resurrection is serialized per label: two waiters racing the same
    /// tombstone share ONE `start_session` — the second reuses the
    /// first's outcome rather than racing to re-bind the session.
    func testResurrectorSerializesRestartsPerLabel() async {
        let resurrector = SessionResurrector()
        let starts = StartGate()
        let first = Task {
            await resurrector.restart("t") { _ in
                await starts.run()
                return .live
            }
        }
        await starts.waitForEntry()
        let second = Task {
            await resurrector.restart("t") { _ in
                XCTFail("a second waiter must share the in-flight restart")
                return .refused
            }
        }
        try? await Task.sleep(for: .milliseconds(50)) // let the waiter attach
        await starts.release()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        let count = await starts.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(firstOutcome, .live)
        XCTAssertEqual(secondOutcome, .live, "the waiter reuses the finisher's outcome")
    }

    /// Rotations chain through the stem: 'voice' → 'voice-1' → 'voice-2',
    /// and every stale spelling resolves to the live successor.
    func testResurrectorRotatesThroughSuccessors() async {
        let resurrector = SessionResurrector()
        var live = await resurrector.effectiveLabel("voice")
        XCTAssertEqual(live, "voice")
        let first = await resurrector.rotate("voice")
        XCTAssertEqual(first, "voice-1")
        live = await resurrector.effectiveLabel("voice")
        XCTAssertEqual(live, "voice-1")
        // Rotating again — whether asked for the stem or the current
        // successor — advances the same counter, never nests a suffix.
        let second = await resurrector.rotate("voice-1")
        XCTAssertEqual(second, "voice-2")
        live = await resurrector.effectiveLabel("voice")
        XCTAssertEqual(live, "voice-2")
        let viaChain = await resurrector.effectiveLabel("voice-1")
        XCTAssertEqual(viaChain, "voice-2")
        // Re-rotating is a no-op — the live successor answers, never a
        // burned one.
        let again = await resurrector.rotate("voice")
        XCTAssertEqual(again, "voice-2")
    }

    /// A controllable `start_session` stand-in for the serialization
    /// test: counts invocations, signals entry, and holds until released
    /// so a second waiter provably overlaps in flight.
    private actor StartGate {
        private(set) var count = 0
        private var open = false
        func run() async {
            count += 1
            while !open { try? await Task.sleep(for: .milliseconds(1)) }
        }
        func waitForEntry() async {
            while count == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        func release() { open = true }
    }

    /// The judge abstains → blocked, nothing dispatched.
    func testAbstainSettlesBlocked() async {
        let driver = FakeDriver()
        let (loop, _, _) = makeLoop(driver, picks: ["stuck"])
        let result = await loop.run(DriveTask(goal: "x", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(driver.calls.map(\.tool),
                       ["list_apps", "list_windows", "get_window_state"])
    }

    /// An off-menu pick is an invalid answer — bounded retry, then
    /// handedBack(.untrustedAnswer). The invalid id is never dispatched.
    func testInvalidChoicesHandBack() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { i in
            FakeDriver.snap([FakeDriver.element(i + 10, label: "B\(i)")])
        }
        let (loop, _, _) = makeLoop(driver, picks: ["bogus", "also-bogus", "done"],
                                    config: DriveLoop.Config(maxInvalidChoices: 2))
        let result = await loop.run(DriveTask(goal: "x", pid: 42, windowID: 7),
                                    session: "t")
        guard case .handedBack(.untrustedAnswer) = result.status else {
            return XCTFail("expected untrustedAnswer, got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "bogus" })
    }

    /// One bad pick recovers — the very next valid pick is honored.
    func testInvalidChoiceThenRecovery() async {
        let driver = readySessionDriver()
        let (loop, _, _) = makeLoop(driver, picks: ["bogus", "done", "done"])
        let result = await loop.run(readySessionTask(), session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
    }

    /// The judge picking a denied element must surface blockedByConsent
    /// and the denied tool call must never reach the driver.
    func testDeniedElementNeverDispatched() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            FakeDriver.snap([FakeDriver.element(4, label: "Empty Trash")])
        }
        let (loop, _, _) = makeLoop(driver, picks: ["e4"], grant: true)
        let result = await loop.run(DriveTask(goal: "clean up", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertEqual(result.consentBlock, .permanent,
                       "a protected-list hit is a permanent refusal, not a grant gap")
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
    }

    /// No standing grant → the loop asks once; declined means refused.
    func testConsentDeclinedRefuses() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            FakeDriver.snap([FakeDriver.element(3, label: "Save")])
        }
        var asked: [DriveLoop.Ask] = []
        let (loop, _, _) = makeLoop(driver, picks: ["e3"], grant: false,
                                    ask: { ask in asked.append(ask); return "no" })
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertEqual(result.consentBlock, .declined)
        // Consent is one radial-shaped choice ask — Yes/No here because no
        // app is bound (a bound app adds "Always for <name>").
        XCTAssertEqual(asked, [.choice(prompt: "Allow computer control: click on 'Save'?",
                                      options: ["Yes", "No"])])
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
    }

    /// No grant and no ask channel — the agent path — classifies as a
    /// missing grant: the one consent block the settings toggle fixes.
    func testConsentWithoutAskChannelIsMissingGrant() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            FakeDriver.snap([FakeDriver.element(3, label: "Save")])
        }
        let (loop, _, _) = makeLoop(driver, picks: ["e3"], grant: false,
                                    ask: nil)
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertEqual(result.consentBlock, .missingGrant)
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
    }

    /// Approving once confirms the whole task — a second mutation in the
    /// same run doesn't re-ask.
    func testConsentApprovedConfirmsTask() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            let buttons = [FakeDriver.element(3, label: "Save"), FakeDriver.element(8, label: "OK")]
            // One extra identical observe: the loop re-reads a same-
            // fingerprint screen once after a dispatch (delivery lag)
            // before deciding again, so the status lands a round later.
            return round < 3 ? FakeDriver.snap(buttons) : FakeDriver.status("File saved", elements: buttons)
        }
        var asks = 0
        let (loop, _, _) = makeLoop(driver, picks: ["e3", "e8", "done"], grant: false,
                                    ask: { _ in asks += 1; return "yes" })
        let result = await loop.run(DriveTask(goal: "save and confirm", pid: 42, windowID: 7,
                                             successContains: ["File saved"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(asks, 1, "approval is once per task, not per action")
        XCTAssertEqual(driver.calls.filter { $0.tool == "click" }.count, 2)
    }

    /// A text-field pick with no supplied values and no ask → needsText.
    func testNeedsTextWhenNoValuesAndNoAsk() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            FakeDriver.snap([FakeDriver.element(5, role: "textfield", label: "Email")])
        }
        let (loop, _, _) = makeLoop(driver, picks: ["t5"])
        let result = await loop.run(DriveTask(goal: "fill email", pid: 42, windowID: 7),
                                    session: "t")
        guard case .needsText(let label) = result.status else {
            return XCTFail("expected needsText, got \(result.status)")
        }
        XCTAssertEqual(label, "Email")
        XCTAssertFalse(driver.calls.contains { $0.tool == "type_text" })
    }

    /// Supplied literal text lands verbatim in the type_text args —
    /// the model selected the field, it never generated the text.
    func testLiteralTextDispatchesVerbatim() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { i in
            FakeDriver.snap([FakeDriver.element(5 + i, role: "textfield", label: "Email",
                                                value: i == 0 ? nil : "me@example.com")])
        }
        let (loop, _, _) = makeLoop(driver, picks: ["t5", "done"], nativeReadOnly: { window, _ in
            .init(elements: [], complete: true, window: window, fieldValues: [
                .init(role: "textfield", label: "Email",
                      value: driver.round <= 1 ? "" : "me@example.com",
                      frame: CGRect(x: 10, y: 10, width: 80, height: 24)),
            ])
        })
        var task = DriveTask(goal: "fill email", pid: 42, windowID: 7)
        task.values["text"] = "me@example.com"
        task.successContains = ["me@example.com"]
        let result = await loop.run(task, session: "t")
        XCTAssertEqual(result.status, .done)
        let typed = driver.calls.first { $0.tool == "type_text" }
        XCTAssertEqual(typed?.args["text"]?.string, "me@example.com")
    }

    /// The same screen twice→thrice stalls the loop: blocked, not done.
    func testStaleScreenBlocks() async {
        let driver = FakeDriver()
        // Unchanging snapshot; the judge keeps asking to reobserve.
        let picks = Array(repeating: "reobserve" as String?, count: 12)
        let (loop, _, _) = makeLoop(driver, picks: picks,
                                    config: DriveLoop.Config(maxStaleRounds: 2))
        let result = await loop.run(DriveTask(goal: "x", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked on stale screen, got \(result.status)")
        }
    }

    /// A suspected_noop with px escalation re-dispatches at the element's
    /// coordinates — the ladder from the driver policy doc.
    func testPixelEscalationOnSuspectedNoop() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            let buttons = [FakeDriver.element(3, label: "Save")]
            return driver.calls.filter({ $0.tool == "click" }).count < 2
                ? FakeDriver.snap(buttons) : FakeDriver.status("File saved", elements: buttons)
        }
        driver.responses["click"] = [
            .object(["effect": .string("suspected_noop"),
                     "escalation": .object(["recommended": .string("px")])]),
            .object(["effect": .string("confirmed")]),
        ]
        let (loop, _, _) = makeLoop(driver, picks: ["e3", "done"])
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7,
                                             successContains: ["File saved"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        let clicks = driver.calls.filter { $0.tool == "click" }
        XCTAssertEqual(clicks.count, 2, "px escalation retries the same tool")
        XCTAssertNil(clicks[0].args["x"])
        // Element frame (10,10,80,24) → center (50, 22).
        XCTAssertEqual(clicks[1].args["x"]?.integer, 50)
        XCTAssertEqual(clicks[1].args["y"]?.integer, 22)
        XCTAssertNil(clicks[1].args["element_index"], "px delivery drops the index")
    }

    /// A transport failure mid-task is honest — blocked, never done, and
    /// the mutation is never replayed.
    func testTransportErrorIsBlockedNotDone() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            FakeDriver.snap([FakeDriver.element(3, label: "Save")])
        }
        driver.errors["click"] = DriverConnectionError.closed
        let (loop, _, _) = makeLoop(driver, picks: ["e3", "done"])
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked after transport drop, got \(result.status)")
        }
        XCTAssertEqual(driver.calls.filter { $0.tool == "click" }.count, 1,
                       "a mutation whose fate is unknown is never replayed")
    }

    /// Cancellation anywhere settles .cancelled.
    func testCancellationSettlesCancelled() async {
        let driver = FakeDriver()
        driver.errors["get_window_state"] = CancellationError()
        let (loop, _, _) = makeLoop(driver, picks: [])
        let result = await loop.run(DriveTask(goal: "x", pid: 42, windowID: 7),
                                    session: "t")
        XCTAssertEqual(result.status, .cancelled)
    }

    /// `.open` scope stops after independently verified foreground effect,
    /// not just after the driver accepts a raise request.
    func testOpenScopeSettlesImmediately() async {
        let driver = FakeDriver()
        driver.responses["list_windows"] = Array(repeating: .object(["windows": .array([
            .object(["window_id": .number(7), "is_on_screen": .bool(true)])
        ])]), count: 2)
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in XCTFail("open scope must not invoke a chooser"); return nil },
            ask: nil, granted: { true }, frontmostPID: { 42 }, frontmostWindowID: { 7 })
        let result = await loop.run(DriveTask(goal: "check something", pid: 42,
                                              windowID: 7, scope: .open,
                                              foreground: true),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(driver.calls.map(\.tool),
                       ["list_apps", "list_windows", "bring_to_front", "list_windows"])
    }

    func testNamedOpenNeverReopensOrSubstitutesDefaultWindow() async {
        let driver = FakeDriver()
        driver.responses["list_windows"] = [.object(["windows": .array([
            .object(["window_id": .number(7), "title": .string("Unrelated"),
                     "is_on_screen": .bool(true)])
        ])])]
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in XCTFail("missing named target must not invoke chooser"); return nil },
            ask: nil, granted: { true },
            activateRestoredApp: { _, _ in XCTFail("named window must not reopen whole app") })
        let result = await loop.run(DriveTask(goal: "check something", pid: 42,
            windowName: "Missing document", scope: .open, foreground: true), session: "t")
        guard case .blocked = result.status else {
            return XCTFail("must not satisfy a named window with the default window")
        }
        XCTAssertFalse(driver.calls.contains { ["launch_app", "bring_to_front"].contains($0.tool) })
    }

    /// The round budget is real — a judge that never settles hits maxSteps.
    func testMaxStepsBoundsTheLoop() async {
        let driver = FakeDriver()
        var i = 0
        driver.snapshotForRound = { _ in
            defer { i += 1 }
            // Fresh fingerprint every round so stale-detection can't rescue.
            return FakeDriver.snap([FakeDriver.element(100 + i, label: "B\(i)")])
        }
        let picks = Array(repeating: "reobserve" as String?, count: 40)
        var config = DriveLoop.Config(); config.maxRounds = 5
        let (loop, _, _) = makeLoop(driver, picks: picks, config: config)
        let result = await loop.run(DriveTask(goal: "x", pid: 42, windowID: 7),
                                    session: "t")
        guard case .maxSteps = result.status else {
            return XCTFail("expected maxSteps, got \(result.status)")
        }
        XCTAssertEqual(driver.calls.filter { $0.tool == "get_window_state" }.count, 5)
    }

    // MARK: - Model contract

    /// "press return" dispatches `press_key` with a `key:` string — the
    /// driver's `hotkey` tool takes a `keys` array for chords, not a bare
    /// key as a string.
    func testKeyPickDispatchesPressKeyShape() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            round == 0 ? FakeDriver.emptySnap : FakeDriver.status("Submitted")
        }
        let (loop, _, _) = makeLoop(driver, picks: ["key:return", "done"])
        let result = await loop.run(DriveTask(goal: "submit", pid: 42, windowID: 7,
                                             successContains: ["Submitted"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        let presses = driver.calls.filter { $0.tool == "press_key" }
        XCTAssertEqual(presses.count, 1)
        XCTAssertEqual(presses[0].args["key"]?.string, "return")
        XCTAssertNil(presses[0].args["keys"], "a bare key never becomes a keys array")
        XCTAssertFalse(driver.calls.contains { $0.tool == "hotkey" })
    }

    /// A `menu A > B` goal mints an `invoke_menu` candidate that the
    /// loop stamps with the bound window before dispatch — the path is
    /// caller text, never model-authored segments.
    func testMenuGoalDispatchesInvokeMenu() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            round == 0 ? FakeDriver.emptySnap : FakeDriver.status("Scientific")
        }
        let (loop, _, _) = makeLoop(driver, picks: ["menu:View > Scientific", "done"])
        let result = await loop.run(DriveTask(goal: "Run menu View > Scientific.",
                                              pid: 42, windowID: 7,
                                              successContains: ["Scientific"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        let calls = driver.calls.filter { $0.tool == "invoke_menu" }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].args["path"], .array([.string("View"), .string("Scientific")]))
        XCTAssertEqual(calls[0].args["pid"], .number(42))
        XCTAssertEqual(calls[0].args["window_id"], .number(7))
    }

    /// The menu parser needs the menu frame AND a clean `>`-joined path —
    /// prose arrows and bare item lists never mint a dispatch.
    func testMenuPathsParserContract() {
        XCTAssertEqual(DriveCandidates.menuPaths(in: "Run menu View > Scientific."),
                       [["View", "Scientific"]])
        XCTAssertEqual(DriveCandidates.menuPaths(in: "menu File > Export As > PDF"),
                       [["File", "Export As", "PDF"]])
        XCTAssertTrue(DriveCandidates.menuPaths(in: "open the file menu").isEmpty)
        XCTAssertTrue(DriveCandidates.menuPaths(in: "scroll left > right on the page").isEmpty)
        XCTAssertTrue(DriveCandidates.menuPaths(in: "press the > key twice").isEmpty)
        XCTAssertTrue(DriveCandidates.menuPaths(in: "menu File > ").isEmpty)
    }

    /// "display" contains "play" as a substring — the media gate's word
    /// boundary must keep this goal from growing media candidates.
    func testDisplayGoalGrowsNoMediaCandidates() async {
        let driver = FakeDriver()
        var offered: [String] = []
        let call: DriveLoop.Call = { tool, args in try driver.call(tool, args) }
        let choose: DriveLoop.Choose = { _, candidates in
            offered = candidates.map(\.id)
            return .pick("stuck")
        }
        let loop = DriveLoop(call: call, choose: choose, ask: nil, granted: { true })
        _ = await loop.run(DriveTask(goal: "open the display settings",
                                     pid: 42, windowID: 7), session: "t")
        XCTAssertFalse(offered.isEmpty, "the chooser ran — the goal reached the loop")
        XCTAssertFalse(offered.contains { $0.hasPrefix("media:") },
                       "media candidates offered: \(offered.filter { $0.hasPrefix("media:") })")
    }

    /// A value change between rounds is a real screen change — the
    /// fingerprint hashes `value`, so typing into a field never trips
    /// the stale-screen detector on an identical-looking tree.
    func testValueChangeKeepsScreenFromGoingStale() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { i in
            let fields = [FakeDriver.element(5, role: "textfield", label: "Email",
                                              value: "me\(i)@example.com")]
            return i < 2 ? FakeDriver.snap(fields) : FakeDriver.status("Domain validated", elements: fields)
        }
        var config = DriveLoop.Config(); config.maxStaleRounds = 1
        let (loop, _, _) = makeLoop(driver, picks: ["reobserve", "reobserve", "done", "done"],
                                    config: config, nativeReadOnly: { window, _ in
            .init(elements: [], complete: true, window: window, fieldValues: [
                .init(role: "textfield", label: "Email", value: "me\(driver.round - 1)@example.com",
                      frame: CGRect(x: 10, y: 10, width: 80, height: 24)),
            ])
        })
        let result = await loop.run(DriveTask(goal: "check email domain", pid: 42, windowID: 7,
                                             successContains: ["Domain validated"]),
                                    session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
    }

    /// Confidence below the floor re-observes once — the second
    /// get_window_state proves the loop looked again instead of acting
    /// on a guess.
    func testOneLowConfidencePickReObserves() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            let buttons = [FakeDriver.element(3, label: "Save")]
            return round == 0 ? FakeDriver.snap(buttons) : FakeDriver.status("File saved", elements: buttons)
        }
        let (loop, _, _) = makeLoop(driver, choices: [
            .pick("e3", confidence: 0.3),
            .pick("done"),
            .pick("done"),
        ])
        let result = await loop.run(DriveTask(goal: "verify file saved", pid: 42, windowID: 7,
                                             successContains: ["File saved"]),
                                    session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        XCTAssertEqual(driver.calls.filter { $0.tool == "get_window_state" }.count, 3)
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
    }

    /// Two consecutive low-confidence picks hand the task back — the
    /// loop never clicks through a guess.
    func testTwoLowConfidencePicksHandBack() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            FakeDriver.snap([FakeDriver.element(3, label: "Save")])
        }
        let (loop, _, _) = makeLoop(driver, choices: [
            .pick("e3", confidence: 0.3),
            .pick("e3", confidence: 0.3),
            .pick("done"),
        ])
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7),
                                    session: "t")
        guard case .handedBack(.lowConfidence) = result.status else {
            return XCTFail("expected handedBack(.lowConfidence), got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
    }

    /// A same-call done vote routes through the done candidate's gates —
    /// with a confirmed effect behind it the run settles done.
    func testDoneVoteWithConfirmedEffectSettlesDone() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            let buttons = [FakeDriver.element(3, label: "Save")]
            return round == 0 ? FakeDriver.snap(buttons) : FakeDriver.status("File saved", elements: buttons)
        }
        // Second pick is a non-done id with doneVote — proves the vote
        // routes to the done gates rather than acting on "reobserve".
        let (loop, _, _) = makeLoop(driver, choices: [
            .pick("e3"),
            .pick("reobserve", doneVote: true),
        ])
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7,
                                             successContains: ["File saved"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(driver.calls.filter { $0.tool == "click" }.count, 1)
    }

    /// A done vote with nothing dispatched is alreadySatisfied — the
    /// confirmed-effect gate applies to votes exactly as to picks.
    func testDoneVoteWithoutEffectIsAlreadySatisfied() async {
        let driver = readySessionDriver()
        let (loop, _, _) = makeLoop(driver, choices: [
            .pick("reobserve", doneVote: true),
            .pick("reobserve", doneVote: true),
        ])
        let result = await loop.run(readySessionTask(), session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("expected alreadySatisfied, got \(result.status)")
        }
        XCTAssertFalse(result.dispatchedEffect)
    }

    /// A chooser throw is a MODEL failure, not a driver failure — the
    /// blocked reason says which side died.
    func testChooserThrowBlocksAsModelFailure() async {
        let driver = FakeDriver()
        let call: DriveLoop.Call = { tool, args in try driver.call(tool, args) }
        let choose: DriveLoop.Choose = { _, _ in
            throw JevSelection.Failure.invalidAnswer
        }
        let loop = DriveLoop(call: call, choose: choose, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "x", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(result.blockedReason, "model failure")
    }

    // MARK: - Window controls + gaze

    /// A traffic-light pick presses the host-side button and verifies the
    /// window left the screen — the effect counts only when observed.
    func testWindowControlCloseVerifiesEffectFromWindowList() async {
        let driver = FakeDriver()
        var pressed: [WindowControls.Kind] = []
        let (loop, _, _) = makeLoop(
            driver, picks: ["wc:close", "done"],
            windowControlButtons: { _ in
                [WindowControls.Button(kind: .close,
                                       frame: CGRect(x: 5, y: 5, width: 12, height: 12))]
            },
            windowControlPress: { kind, _ in pressed.append(kind); return true })
        let result = await loop.run(DriveTask(goal: "close this window",
                                              pid: 42, windowID: 7), session: "t")
        XCTAssertNotEqual(result.status, .done, "verified effect alone is not task completion")
        XCTAssertEqual(pressed, [.close])
        XCTAssertTrue(result.dispatchedEffect)
    }

    /// A refused traffic-light press claims no effect — the loop notes
    /// it and keeps driving.
    func testWindowControlRefusalClaimsNoEffect() async {
        let driver = FakeDriver()
        let (loop, _, _) = makeLoop(
            driver, picks: ["wc:close", "stuck"],
            windowControlButtons: { _ in
                [WindowControls.Button(kind: .close,
                                       frame: CGRect(x: 5, y: 5, width: 12, height: 12))]
            },
            windowControlPress: { _, _ in false })
        let result = await loop.run(DriveTask(goal: "close this window",
                                              pid: 42, windowID: 7), session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertFalse(result.dispatchedEffect)
    }

    /// The gaze point tags the element under it — a hint in the
    /// candidate description, never a filter or reorder.
    func testGazeAnnotatesElementUnderEyes() async {
        let stateSeen = LockedBox<JSONValue?>(nil)
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in
            .object([
                "window_title": .string("Fixture"),
                "window_bounds": .object(["x": .number(0), "y": .number(0),
                                          "width": .number(800), "height": .number(600)]),
                "screenshot_scale": .number(2),
                "elements": .array([FakeDriver.element(3, label: "Save")]),
            ])
        }
        var offered: [(id: String, description: String)] = []
        let call: DriveLoop.Call = { tool, args in try driver.call(tool, args) }
        let choose: DriveLoop.Choose = { state, candidates in
            stateSeen.set(state)
            offered = candidates
            return .pick("stuck")
        }
        // Gaze is already in the native element's global screen-point space.
        let loop = DriveLoop(call: call, choose: choose, ask: nil,
                             granted: { true },
                             gaze: {
                                 GazeSample(x: 80, y: 20, confidence: 0.9,
                                            state: "fixation", updatedAt: Date())
                             },
                             windowControlButtons: { _ in [] })
        _ = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7), session: "t")
        XCTAssertTrue(offered.contains { $0.id == "e3"
            && $0.description.contains("(under your eyes)") })
        XCTAssertTrue(offered.contains { $0.id == "e3" },
                      "gaze never filters the candidate set")
        XCTAssertNil(stateSeen.value?["gaze"], "raw gaze coordinates must never reach a decider")
    }

    // MARK: - Consent classes (explicit vs autonomous)

    /// The spoken command IS its consent: "lock screen" on the voice path
    /// (explicitConsent, the default) dispatches with NO standing grant
    /// and NO ask — the deny scan is the only veto left.
    func testSpokenFastLaneNeedsNoGrant() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { false })
        let result = await loop.run(DriveTask(goal: "lock screen"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.calls.filter { $0.tool == "hotkey" }.count, 1,
                       "the spoken verb self-consents — no grant, no ask")
    }

    /// The same goal authored by an agent (explicitConsent off) is an
    /// autonomous effect: no grant + a declined ask means nothing
    /// dispatches.
    func testAgentFastLaneDeclineNeverDispatches() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil },
                             ask: { _ in "no" }, granted: { false },
                             explicitConsent: false)
        let result = await loop.run(DriveTask(goal: "lock screen"), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "hotkey" })
    }

    /// Approved once, the same agent goal dispatches — one per-task
    /// confirm covers the fast-lane dispatch.
    func testAgentFastLaneApprovalDispatches() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        var asks = 0
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil },
                             ask: { _ in asks += 1; return "yes" }, granted: { false },
                             explicitConsent: false)
        let result = await loop.run(DriveTask(goal: "lock screen"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(driver.calls.filter { $0.tool == "hotkey" }.count, 1)
    }

    /// The task's own deny rules bind the fast lane too: "open notes" with
    /// deny ["notes"] refuses before launch_app — grant or not.
    func testTaskDenyBindsFastLaneLaunch() async {
        for grant in [false, true] {
            let driver = FakeDriver()
            driver.responses["list_apps"] = [.object(["apps": .array([
                .object(["name": .string("Notes"),
                         "bundle_id": .string("com.apple.Notes")])])])]
            let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                                 choose: { _, _ in nil }, ask: nil,
                                 granted: { grant })
            let result = await loop.run(
                DriveTask(goal: "open notes", deny: ["notes"]), session: "t")
            guard case .blockedByConsent = result.status else {
                return XCTFail("expected blockedByConsent grant=\(grant), got \(result.status)")
            }
            XCTAssertFalse(driver.calls.contains { $0.tool == "launch_app" },
                           "grant=\(grant)")
        }
    }

    /// A model-authored goal keeps the deny scan on bind: the task rule
    /// fires inside the autonomous gate, before launch_app.
    func testAgentBindDenyRefusesWithGrant() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([
            .object(["name": .string("Notes"),
                     "bundle_id": .string("com.apple.Notes")])])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil,
                             granted: { true }, explicitConsent: false)
        let result = await loop.run(
            DriveTask(goal: "open notes", deny: ["notes"]), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "launch_app" })
    }

    /// The bind-phase raise is a mutation like any other: on the agent
    /// path a declined confirm means bring_to_front never dispatches.
    func testAgentBringToFrontDeclineNeverDispatches() async {
        let driver = FakeDriver()
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil },
                             ask: { _ in "no" }, granted: { false },
                             explicitConsent: false)
        let result = await loop.run(
            DriveTask(goal: "show the window", pid: 42, windowID: 7,
                      scope: .open, foreground: true), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "bring_to_front" })
    }

    /// A media key is a model-picked mutation on the loop path — the
    /// autonomous gate applies even on the voice lane. ("Adjust volume"
    /// deliberately doesn't parse as a named media key: the spoken
    /// "volume up" fast-lane self-consents and never reaches the picker.)
    func testMediaPickNeedsGrantOnLoopPath() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in FakeDriver.snap([]) }
        var posted = 0
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in .init(id: "media:volume_up") },
                             ask: { _ in "no" }, granted: { false },
                             postMediaKey: { _ in posted += 1; return true })
        let result = await loop.run(DriveTask(goal: "adjust volume", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertEqual(posted, 0, "a declined consent posts nothing")
    }

    /// A refused media post is reported, not claimed: the ledger carries
    /// the refusal and the run never counts it as an effect.
    func testMediaPostRefusalClaimsNoEffect() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in FakeDriver.snap([]) }
        var pickQueue: [DriveLoop.JevChoice] = [.init(id: "media:volume_up"),
                                              .init(id: "stuck")]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in pickQueue.isEmpty ? nil : pickQueue.removeFirst() },
                             ask: nil, granted: { true },
                             postMediaKey: { _ in false })
        let result = await loop.run(DriveTask(goal: "adjust volume", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertFalse(result.dispatchedEffect)
        XCTAssertTrue(result.history.contains { $0.contains("was not delivered") },
                      result.history.joined(separator: " | "))
    }

    // MARK: - Stale element token

    /// The stale-token remedy: re-observe and retry by element IDENTITY —
    /// the fresh token, never the dead one or a positional index.
    func testStaleTokenRetriesByIdentity() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { i in
            let buttons = [FakeDriver.element(3, label: "Save",
                                              token: i == 0 ? "tok-old" : "tok-fresh")]
            return i < 2 ? FakeDriver.snap(buttons) : FakeDriver.status("File saved", elements: buttons)
        }
        driver.errorsOnce["click"] = DriverConnectionError.toolRefused(
            tool: "click", code: "stale_element_token",
            detail: "element_token is stale; re-snapshot")
        let (loop, _, _) = makeLoop(driver, picks: ["e3", "done"])
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7,
                                             successContains: ["File saved"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        let clicks = driver.calls.filter { $0.tool == "click" }
        XCTAssertEqual(clicks.count, 2)
        XCTAssertEqual(clicks[0].args["element_token"], .string("tok-old"))
        XCTAssertEqual(clicks[1].args["element_token"], .string("tok-fresh"),
                       "the retry binds the re-observed element's token")
        XCTAssertNil(clicks[1].args["element_index"],
                     "a token retry never falls back to a positional index")
        XCTAssertNil(clicks[1].args["snapshot_id"],
                     "the dead snapshot's id never re-dispatches")
    }

    /// A second consecutive stale refusal means the screen is churning —
    /// refused, never replayed positionally.
    func testSecondStaleRefusesHonestly() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { i in
            FakeDriver.snap([FakeDriver.element(3, label: "Save",
                                                token: "tok-\(i)")])
        }
        driver.errors["click"] = DriverConnectionError.toolRefused(
            tool: "click", code: "stale_element_token",
            detail: "element_token is stale; re-snapshot")
        let (loop, _, _) = makeLoop(driver, picks: ["e3"])
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(driver.calls.filter { $0.tool == "click" }.count, 2,
                       "one identity retry, never a replay loop")
    }

    /// A stale element whose identity vanished from the fresh snapshot is
    /// an honest refusal — the loop never guesses a neighbor.
    func testStaleTokenVanishedElementRefuses() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { i in
            i == 0
                ? FakeDriver.snap([FakeDriver.element(3, label: "Save", token: "tok-old")])
                : FakeDriver.snap([FakeDriver.element(9, label: "Other", token: "tok-other")])
        }
        driver.errorsOnce["click"] = DriverConnectionError.toolRefused(
            tool: "click", code: "stale_element_token",
            detail: "element_token is stale; re-snapshot")
        let (loop, _, _) = makeLoop(driver, picks: ["e3"])
        let result = await loop.run(DriveTask(goal: "save", pid: 42, windowID: 7),
                                    session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(driver.calls.filter { $0.tool == "click" }.count, 1,
                       "the vanished element is never retried by position")
    }

    // MARK: - Clipboard gating

    /// Clipboard text the loop read itself rides to the remote chooser
    /// ONLY under the standing grant — without it the chooser learns the
    /// clipboard exists and its size, never its contents.
    func testClipboardContextWithheldWithoutGrant() async {
        let driver = FakeDriver()
        driver.responses["clipboard_read"] = [
            .object(["text": .string("s3cret-paste")])]
        var contexts: [String?] = []
        var pickQueue: [DriveLoop.JevChoice?] = [
            .init(id: "clipboard:read"), .init(id: "stuck")]
        let call: DriveLoop.Call = { t, a in try driver.call(t, a) }
        let choose: DriveLoop.Choose = { state, _ in
            contexts.append(state["clipboard_or_context"]?.string)
            return pickQueue.isEmpty ? nil : pickQueue.removeFirst()
        }
        let loop = DriveLoop(call: call, choose: choose, ask: nil,
                             granted: { false })
        _ = await loop.run(DriveTask(goal: "what's on the clipboard",
                                     pid: 42, windowID: 7), session: "t")
        let observed = contexts.compactMap { $0 }
        XCTAssertEqual(observed.count, 1)
        XCTAssertFalse(observed[0].contains("s3cret-paste"),
                       "clipboard contents never leave without the grant")
        XCTAssertTrue(observed[0].contains("withheld"), observed[0])
    }

    /// The same read under the grant travels as content — the consent
    /// that could act on it also exposes it.
    func testClipboardContextTravelsWithGrant() async {
        let driver = FakeDriver()
        driver.responses["clipboard_read"] = [
            .object(["text": .string("s3cret-paste")])]
        var contexts: [String?] = []
        var pickQueue: [DriveLoop.JevChoice?] = [
            .init(id: "clipboard:read"), .init(id: "stuck")]
        let call: DriveLoop.Call = { t, a in try driver.call(t, a) }
        let choose: DriveLoop.Choose = { state, _ in
            contexts.append(state["clipboard_or_context"]?.string)
            return pickQueue.isEmpty ? nil : pickQueue.removeFirst()
        }
        let loop = DriveLoop(call: call, choose: choose, ask: nil,
                             granted: { true })
        _ = await loop.run(DriveTask(goal: "what's on the clipboard",
                                     pid: 42, windowID: 7), session: "t")
        XCTAssertEqual(contexts.compactMap { $0 }.last, "s3cret-paste")
    }

    // MARK: - Window control verification

    /// A press whose verify read never succeeds reports unverifiable —
    /// the error is NOT folded into "window unchanged".
    func testWindowControlUnverifiableOnReadError() async {
        let driver = FakeDriver()
        driver.snapshotForRound = { _ in FakeDriver.snap([]) }
        // Bind's list_windows succeeds once; every later read dies.
        driver.errorsAfterNCalls["list_windows"] = (1, DriverConnectionError.remote("gone"))
        let (loop, _, _) = makeLoop(
            driver, picks: ["wc:close"],
            windowControlButtons: { _ in
                [WindowControls.Button(kind: .close,
                                       frame: CGRect(x: 5, y: 5, width: 12, height: 12))]
            },
            windowControlPress: { _, _ in true })
        let result = await loop.run(DriveTask(goal: "close this window",
                                              pid: 42, windowID: 7), session: "t")
        guard case .blocked(let why) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(why.contains("could not be verified"), why)
    }
}

private extension DriveLoop.Config {
    init(maxInvalidChoices: Int) {
        self = .default
        self.maxInvalidChoices = maxInvalidChoices
    }
    init(maxStaleRounds: Int) {
        self = .default
        self.maxStaleRounds = maxStaleRounds
    }
}

private extension DriveLoop.JevChoice {
    /// Fixture pick — nil confidence (ungated) and nil doneVote unless
    /// the test says otherwise.
    static func pick(_ id: String, confidence: Double? = nil,
                     doneVote: Bool? = nil) -> DriveLoop.JevChoice {
        DriveLoop.JevChoice(id: id, confidence: confidence, doneVote: doneVote)
    }
}
