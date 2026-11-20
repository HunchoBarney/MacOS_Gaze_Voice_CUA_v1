import ApplicationServices
import CoreGraphics
import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: the new fast-lane bodies dispatch deterministically —
/// desktop-scope chords need no app, menu paths ride invoke_menu,
/// snaps verify a bounds readback, locate hunts the global inventory,
/// and the display-scope qualifier resolves the app under the gaze point.
final class FastLaneExecutorTests: XCTestCase {

    func testVerifiedCapturedOwnerAvoidsResolverButMissingOrChangedOwnerDoesNot() async {
        let resolutions = LockedBox(0)
        let resolver = AppResolver(listApps: {
            resolutions.set(resolutions.value + 1)
            return [AppResolver.App(name: "BoundFixture", bundle: "fixture.bound", pid: 99)]
        })
        let loop = DriveLoop(call: { _, _ in
            XCTFail("App identity reads must not dispatch")
            return .null
        }, choose: { _, _ in
            XCTFail("A captured identity is not a model judgment")
            return nil
        }, ask: nil, granted: { true }, resolver: resolver)
        let task = DriveTask(goal: "type fixture", application: "fixture.bound", pid: 42, windowID: 7)
        let native = AppResolver.App(name: "Different display name", bundle: "fixture.bound", pid: 42)
        let bound = await loop.resolveTaskApplication(task, capturedOwner: { _ in native })
        XCTAssertEqual(bound.app?.bundle, "fixture.bound")
        XCTAssertEqual(bound.app?.pid, 42)
        XCTAssertEqual(bound.app?.name, "Different display name")
        XCTAssertEqual(bound.matches.count, 1)
        XCTAssertEqual(resolutions.value, 0)
        for owner in [nil, 99] as [Int?] {
            let changed = await loop.resolveTaskApplication(task, capturedOwner: { _ in
                owner.map { AppResolver.App(name: "Other", bundle: "fixture.bound", pid: $0) }
            })
            XCTAssertEqual(changed.app?.pid, 99)
        }
        let unpinned = DriveTask(goal: "type fixture", application: "fixture.bound", pid: 42)
        let missing = await loop.resolveTaskApplication(unpinned, capturedOwner: { _ in
            XCTFail("A missing window cannot receive a native owner shortcut")
            return native
        })
        XCTAssertEqual(missing.app?.pid, 99)
        XCTAssertGreaterThan(resolutions.value, 0)
    }

    private final class FakeDriver {
        var calls: [(tool: String, args: [String: JSONValue])] = []
        var responses: [String: [JSONValue]] = [:]
        var thrown: [String: Error] = [:]
        var modelCalls = 0
        func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
            calls.append((tool, args))
            if let error = thrown[tool] { throw error }
            if var queue = responses[tool], !queue.isEmpty {
                let first = queue.removeFirst()
                responses[tool] = queue
                return first
            }
            return .object(["effect": .string("confirmed")])
        }
    }

    private func appRow(_ name: String, _ bundle: String, pid: Int? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["name": .string(name), "bundle_id": .string(bundle)]
        if let pid { row["pid"] = .number(Double(pid)) }
        return .object(row)
    }

    private func apps(_ rows: [JSONValue]) -> JSONValue {
        .object(["apps": .array(rows)])
    }

    private func windowRow(id: Int, pid: Int, app: String, title: String,
                           x: Double, y: Double, w: Double, h: Double,
                           z: Int = 1, onScreen: Bool = true) -> JSONValue {
        .object(["window_id": .number(Double(id)), "pid": .number(Double(pid)),
                 "app_name": .string(app), "title": .string(title),
                 "bounds": .object(["x": .number(x), "y": .number(y),
                                    "width": .number(w), "height": .number(h)]),
                 "z_index": .number(Double(z)), "is_on_screen": .bool(onScreen)])
    }

    private func windows(_ rows: [JSONValue]) -> JSONValue {
        .object(["windows": .array(rows)])
    }

    private func gaze(_ x: Double, _ y: Double) -> () async throws -> GazeSample {
        { GazeSample(x: x, y: y, confidence: 0.9, state: "dwell",
                     updatedAt: Date()) }
    }

    private func verifiedScrollLoop(_ driver: FakeDriver, rows: [JSONValue]? = nil,
                                    grant: Bool = true, allowParsedScroll: Bool = true,
                                    sample: (@Sendable (NativeWindowObservation.ScrollViewport, Bool)
                                        -> NativeWindowObservation.ScrollViewport?)? = nil,
                                    authorization: (@Sendable () async -> Bool)? = nil,
                                    nativeControl: NativeWindowObservation.ScrollControl? = nil) -> DriveLoop {
        let moved = LockedBox(false)
        let identity = NativeFieldIdentity(AXUIElementCreateApplication(424242))
        let window = WindowRef(pid: 424242, windowID: 7)
        let anchor = NativeWindowObservation.ScrollViewport(
            window: window, root: identity, region: identity, meter: identity,
            content: identity, document: NativeWindowObservation.documentSubject(
                window: window, identifier: "file:///owned.txt"),
            title: Data("Owned".utf8), frame: CGRect(x: 0, y: 30, width: 400, height: 270),
            windowFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentSize: CGSize(width: 400, height: 2000), contentDigest: Data("body".utf8),
            point: CGPoint(x: 200, y: 165), metric: .verticalBar, position: 0.2,
            minimum: 0, maximum: 1, capturedAt: 0, tokenCenterMatches: true)
        let owned = rows ?? [windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Owned",
            x: 0, y: 0, w: 400, h: 300)]
        let state: JSONValue = .object([
            "pid": .number(424242), "window_id": .number(7), "window_title": .string("Owned"),
            "snapshot_id": .string("owned-scroll-snapshot"),
            "elements": .array([.object([
                "element_index": .number(1), "element_token": .string("owned-scroll-region"),
                "role": .string("AXScrollArea"), "label": .string("Owned viewport"),
                "frame": .object(["x": .number(0), "y": .number(30), "w": .number(400), "h": .number(270)]),
                "actions": .array([]),
            ])]),
        ])
        return DriveLoop(call: { tool, args in
            let response = try driver.call(tool, args)
            switch tool {
            case "list_apps": return self.apps([self.appRow("AuditFixture", "fixture.audit", pid: 424242)])
            case "list_windows": return self.windows(owned)
            case "get_window_state": return state
            case "scroll":
                moved.set(true)
                return .object(["effect": .string("unverifiable")])
            default: return response
            }
        }, choose: { _, _ in
            driver.modelCalls += 1
            return .init(id: "stuck")
        }, ask: nil, granted: { grant }, explicitConsent: false,
        resolver: AppResolver(listApps: { [.init(name: "AuditFixture", bundle: "fixture.audit", pid: 424242)] }),
        config: .init(maxRounds: 2, maxInvalidChoices: 1, maxStaleRounds: 1,
                      windowOnly: true, allowParsedScroll: allowParsedScroll),
        nativeReadOnly: { _, _ in nil }, nativeScrollRead: { _, _, _, _ in
            var result = anchor
            result.position = moved.value ? 0.4 : 0.2
            result.capturedAt = ProcessInfo.processInfo.systemUptime
            result.readGeneration = UUID()
            return sample.map { $0(result, moved.value) } ?? result
        }, nativeScrollControl: { viewport, direction, lines in
            guard let nativeControl else { return .unavailable }
            let outcome = try await nativeControl(viewport, direction, lines)
            if outcome == .sent { moved.set(true) }
            return outcome
        }, scrollContinuationIsCurrent: authorization)
    }

    func testR8NativeScrollNeedsIndependentMovementAndNoDriverOrModel() async {
        for moves in [true, false] {
            let driver = FakeDriver()
            let calls = LockedBox(0)
            let loop = verifiedScrollLoop(driver, sample: { original, _ in
                var result = original
                if !moves { result.position = 0.2 }
                return result
            }, nativeControl: { viewport, direction, lines in
                calls.set(calls.value + 1)
                XCTAssertEqual(viewport.window, WindowRef(pid: 424242, windowID: 7))
                XCTAssertEqual(direction, "down")
                XCTAssertEqual(lines, 3)
                return .sent
            })
            let result = await loop.run(
                DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
                session: "r8-native-scroll")
            XCTAssertEqual(result.status == .done, moves)
            XCTAssertEqual(result.dispatchedEffect, moves)
            XCTAssertEqual(calls.value, 1)
            XCTAssertEqual(driver.modelCalls, 0)
            XCTAssertFalse(driver.calls.contains { ["scroll", "get_window_state"].contains($0.tool) })
        }
    }

    func testR8OnlyUnsupportedNativeScrollCanUseBoundDriverFallback() async {
        for mode in ["unsupported", "uncertain", "failed"] {
            let driver = FakeDriver()
            let calls = LockedBox(0)
            let loop = verifiedScrollLoop(driver, nativeControl: { _, _, _ in
                calls.set(calls.value + 1)
                if mode == "failed" { throw DriverConnectionError.remote("uncertain native reply") }
                return mode == "unsupported" ? .unavailable : .uncertain
            })
            let result = await loop.run(
                DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
                session: "r8-native-fallback")
            XCTAssertEqual(calls.value, 1)
            XCTAssertEqual(result.status == .done, mode == "unsupported")
            XCTAssertEqual(driver.calls.filter { $0.tool == "scroll" }.count, mode == "unsupported" ? 1 : 0)
            XCTAssertEqual(driver.modelCalls, 0)
            XCTAssertFalse(driver.calls.contains { $0.tool == "start_session" })
        }
    }

    func testR8RevokedCurrentnessCannotReachNativeScroll() async {
        let driver = FakeDriver()
        let loop = verifiedScrollLoop(driver, authorization: { false }, nativeControl: { _, _, _ in
            XCTFail("Currentness must be checked before native input")
            return .sent
        })
        let result = await loop.run(
            DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
            session: "r8-native-revoked")
        XCTAssertNotEqual(result.status, .done)
        XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" })
    }

    func testR7PinnedScrollUsesIndependentViewportOnce() async {
        let driver = FakeDriver()
        let result = await verifiedScrollLoop(driver).run(
            DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
            session: "r7-owned-scroll")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(driver.calls.filter { $0.tool == "scroll" }.count, 1)
        XCTAssertEqual(driver.modelCalls, 0)
    }

    func testR7SemanticFallbackCannotReenterParsedScroll() async {
        for goal in ["scroll down", "scroll down 100 times"] {
            let driver = FakeDriver()
            let result = await verifiedScrollLoop(driver, allowParsedScroll: false).run(
                DriveTask(goal: goal, application: "fixture.audit", pid: 424242, windowID: 7),
                session: "r7-no-parser")
            XCTAssertNotEqual(result.status, .done)
            XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" })
            XCTAssertGreaterThan(driver.modelCalls, 0)
        }
    }

    func testR7TypedContinuationCannotLoseItsNativeSubject() async throws {
        let identity = NativeFieldIdentity(AXUIElementCreateApplication(424242))
        let window = WindowRef(pid: 424242, windowID: 7)
        let anchor = NativeWindowObservation.ScrollViewport(
            window: window, root: identity, region: identity, meter: identity,
            content: identity, document: NativeWindowObservation.documentSubject(
                window: window, identifier: "file:///different-document.txt"),
            title: Data("Owned".utf8), frame: CGRect(x: 0, y: 30, width: 400, height: 270),
            windowFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentSize: CGSize(width: 400, height: 2000), contentDigest: Data("other body".utf8),
            point: CGPoint(x: 200, y: 165), metric: .verticalBar, position: 0.2,
            minimum: 0, maximum: 1, capturedAt: ProcessInfo.processInfo.systemUptime)
        let request = try XCTUnwrap(WindowScrollRequest(goal: "A little more.",
            application: "fixture.audit", windowID: 7, direction: "down", small: true,
            continuation: anchor))
        let driver = FakeDriver()
        let result = await verifiedScrollLoop(driver).runWindowScroll(request,
            task: DriveTask(goal: request.goal, application: request.application, pid: 424242, windowID: 7),
            session: "r7-native-subject")
        XCTAssertNotEqual(result.status, .done)
        XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" })
        XCTAssertEqual(driver.modelCalls, 0)
    }

    func testR7DisablingScrollParserDoesNotDisableOtherFastActions() async {
        let posted = LockedBox(0)
        let loop = DriveLoop(call: { _, _ in XCTFail("Media needs no driver"); return .null },
            choose: { _, _ in XCTFail("Media needs no chooser"); return nil },
            ask: nil, granted: { true }, config: .init(allowParsedScroll: false),
            postMediaKey: { _ in posted.set(posted.value + 1); return true })
        let result = await loop.run(DriveTask(goal: "mute"), session: "r7-other-fast")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(posted.value, 1)
    }

    func testR7NaturalScrollPreservesWholeRequestAndTypedAmount() async throws {
        for small in [false, true] {
            let goal = small ? "A tiny scroll toward the bottom, please." : "Please move the page farther down."
            let request = try XCTUnwrap(WindowScrollRequest(goal: goal, application: "fixture.audit",
                windowID: 7, direction: "down", small: small))
            let driver = FakeDriver()
            let task = DriveTask(goal: goal, application: "fixture.audit", pid: 424242, windowID: 7)
            let result = await verifiedScrollLoop(driver).runWindowScroll(request, task: task, session: "r7-natural")
            XCTAssertEqual(result.status, .done)
            XCTAssertTrue(result.dispatchedEffect)
            XCTAssertEqual(request.goal, goal)
            XCTAssertEqual(driver.modelCalls, 0)
            let scrolls = driver.calls.filter { $0.tool == "scroll" }
            XCTAssertEqual(scrolls.count, 1)
            XCTAssertEqual(scrolls.first?.args["direction"], .string("down"))
            XCTAssertEqual(scrolls.first?.args["by"], .string("line"))
            XCTAssertEqual(scrolls.first?.args["amount"], .number(small ? 1 : 3))
        }
    }

    func testR7TypedScrollCannotBeRetargetedOrLoseExtraConditions() async throws {
        let goal = "Please move the page farther down."
        let request = try XCTUnwrap(WindowScrollRequest(goal: goal, application: "fixture.audit",
            windowID: 7, direction: "down", small: false))
        for variant in ["goal", "app", "window", "missingWindow", "pid", "values", "postcondition", "scope", "context", "title"] {
            var task = DriveTask(goal: goal, application: "fixture.audit", pid: 424242, windowID: 7)
            switch variant {
            case "goal": task.goal += " until Cedar is visible."
            case "app": task.application = "fixture.other"
            case "window": task.windowID = 8
            case "missingWindow": task.windowID = nil
            case "pid": task.pid = 999
            case "values": task.values["text"] = "literal"
            case "postcondition": task.successContains = ["Cedar"]
            case "scope": task.scope = .open
            case "context": task.previousContext = "Only scroll after Cedar is visible."
            default: task.windowName = "Another document"
            }
            let driver = FakeDriver()
            let result = await verifiedScrollLoop(driver).runWindowScroll(request, task: task, session: "r7-changed")
            XCTAssertNotEqual(result.status, .done, variant)
            XCTAssertFalse(result.dispatchedEffect, variant)
            XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" }, variant)
            XCTAssertEqual(driver.modelCalls, 0, variant)
        }
    }

    func testR7PinnedScrollRequiresUniqueOwnedRowAndConsent() async {
        let row = windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Owned",
            x: 0, y: 0, w: 400, h: 300)
        let foreign = windowRow(id: 7, pid: 999, app: "Other", title: "Owned",
            x: 0, y: 0, w: 400, h: 300)
        for variant in ["empty", "foreign", "duplicate", "grant", "deny"] {
            let rows = variant == "empty" ? [] : variant == "foreign" ? [foreign]
                : variant == "duplicate" ? [row, row] : [row]
            let driver = FakeDriver()
            let result = await verifiedScrollLoop(driver, rows: rows, grant: variant != "grant").run(
                DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242,
                    windowID: 7, deny: variant == "deny" ? ["Owned"] : []), session: "r7-refusal")
            XCTAssertNotEqual(result.status, .done, variant)
            XCTAssertFalse(result.dispatchedEffect, variant)
            XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" }, variant)
        }
    }

    func testR7TypedScrollCannotCompleteWithWrongDirectionOrChangedSubject() async throws {
        let goal = "A tiny scroll toward the bottom, please."
        let request = try XCTUnwrap(WindowScrollRequest(goal: goal, application: "fixture.audit",
            windowID: 7, direction: "down", small: true))
        for variant in ["direction", "subject", "missing", "unchanged"] {
            let driver = FakeDriver()
            let loop = verifiedScrollLoop(driver, sample: { value, dispatched in
                guard dispatched else { return value }
                var changed = value
                switch variant {
                case "direction": changed.position = 0.1
                case "subject": changed.contentDigest = Data("other".utf8)
                case "missing": return nil
                default: changed.position = 0.2
                }
                return changed
            })
            let result = await loop.runWindowScroll(request,
                task: DriveTask(goal: goal, application: "fixture.audit", pid: 424242, windowID: 7),
                session: "r7-unverified")
            XCTAssertNotEqual(result.status, .done, variant)
            XCTAssertFalse(result.dispatchedEffect, variant)
            XCTAssertEqual(driver.calls.filter { $0.tool == "scroll" }.count, 1, variant)
            XCTAssertEqual(driver.modelCalls, 0, variant)
        }
    }

    func testR7TypedScrollCancellationDuringAuthorizationSendsNothing() async throws {
        let request = try XCTUnwrap(WindowScrollRequest(goal: "Move the page down a little.",
            application: "fixture.audit", windowID: 7, direction: "down", small: true))
        let reached = LockedBox(false)
        let driver = FakeDriver()
        let loop = verifiedScrollLoop(driver, authorization: {
            reached.set(true)
            try? await Task.sleep(for: .seconds(5))
            return true
        })
        let attempt = Task {
            await loop.runWindowScroll(request,
                task: DriveTask(goal: request.goal, application: "fixture.audit", pid: 424242, windowID: 7),
                session: "r7-cancelled")
        }
        for _ in 0..<200 where !reached.value { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(reached.value)
        attempt.cancel()
        let result = await attempt.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" })
    }

    func testC1ScrollWithoutViewportEvidenceSendsNoInput() async throws {
        for acknowledgement in [JSONValue.null, .object(["effect": .string("confirmed")])] {
            let driver = FakeDriver()
            driver.responses["scroll"] = [acknowledgement]
            driver.responses["list_windows"] = [windows([
                windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Owned",
                          x: 0, y: 0, w: 400, h: 300),
            ])]
            let loop = DriveLoop(call: { try driver.call($0, $1) },
                choose: { _, _ in XCTFail("A primitive scroll needs no model"); return nil },
                ask: nil, granted: { true })
            var history: [String] = [], confirmed = false
            let resolved = DriveLoop.FastResolution(action: try XCTUnwrap(FastAction.parse("scroll down")).action,
                openVerb: nil, name: "AuditFixture", bundle: "fixture.audit", pid: 424242)
            let value = try await loop.runFastLane(resolved,
                task: DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
                session: "scroll-without-witness", history: &history, confirmed: &confirmed)
            let result = try XCTUnwrap(value)
            XCTAssertNotEqual(result.status, .done)
            XCTAssertFalse(result.dispatchedEffect)
            XCTAssertEqual(driver.calls.filter { $0.tool == "scroll" }.count, 0)
        }
    }

    func testC1ScrollWithoutAnOwnedRegionBindingSendsNoInput() async throws {
        let driver = FakeDriver()
        let identity = NativeFieldIdentity(AXUIElementCreateApplication(424242))
        let anchor = NativeWindowObservation.ScrollViewport(
            window: WindowRef(pid: 424242, windowID: 7), root: identity, region: identity,
            meter: identity, content: identity, document: nil, title: Data("Owned".utf8),
            frame: CGRect(x: 0, y: 30, width: 400, height: 270),
            windowFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentSize: CGSize(width: 400, height: 2000), contentDigest: Data("body".utf8),
            point: CGPoint(x: 200, y: 165), metric: .verticalBar, position: 0.2,
            minimum: 0, maximum: 1, capturedAt: 0, tokenCenterMatches: true)
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Owned",
                      x: 0, y: 0, w: 400, h: 300),
        ])]
        driver.responses["get_window_state"] = [.object([
            "pid": .number(424243), "window_id": .number(7),
            "elements": .array([.object([
                "role": .string("AXScrollArea"), "element_token": .string("other-owner"),
                "frame": .object(["x": .number(0), "y": .number(30),
                                  "w": .number(400), "h": .number(270)]),
            ])]),
        ])]
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in XCTFail("An unbound scroll cannot reach a planner"); return nil },
            ask: nil, granted: { true },
            nativeScrollRead: { _, _, _, _ in
                var result = anchor
                result.capturedAt = ProcessInfo.processInfo.systemUptime
                result.readGeneration = UUID()
                return result
            })
        var history: [String] = [], confirmed = false
        let resolved = DriveLoop.FastResolution(action: try XCTUnwrap(FastAction.parse("scroll down")).action,
            openVerb: nil, name: "AuditFixture", bundle: "fixture.audit", pid: 424242)
        let result = try await loop.runFastLane(resolved,
            task: DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
            session: "scroll-unbound-region", history: &history, confirmed: &confirmed)
        XCTAssertNotEqual(result?.status, .done)
        XCTAssertEqual(driver.calls.filter { $0.tool == "scroll" }.count, 0)
    }

    func testC1ScrollCannotFollowGazeOutsideCapturedWindow() async throws {
        let driver = FakeDriver()
        driver.responses["list_windows"] = Array(repeating: windows([
            windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Owned",
                      x: 0, y: 0, w: 400, h: 300),
            windowRow(id: 8, pid: 424243, app: "Other", title: "Decoy",
                      x: 600, y: 600, w: 400, h: 300),
        ]), count: 4)
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in XCTFail("A scope refusal needs no model"); return nil },
            ask: nil, granted: { true }, gaze: gaze(700, 700))
        var history: [String] = [], confirmed = false
        let resolved = DriveLoop.FastResolution(action: try XCTUnwrap(FastAction.parse("scroll down")).action,
            openVerb: nil, name: "AuditFixture", bundle: "fixture.audit", pid: 424242)
        let result = try await loop.runFastLane(resolved,
            task: DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
            session: "scroll-wrong-gaze", history: &history, confirmed: &confirmed)
        XCTAssertNotEqual(result?.status, .done)
        XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" })
    }

    func testC1ScrollWitnessRequiresFreshDirectionAndIdenticalSubject() {
        let identity = NativeFieldIdentity(AXUIElementCreateApplication(424242))
        let other = NativeFieldIdentity(AXUIElementCreateApplication(424243))
        let window = WindowRef(pid: 424242, windowID: 7)
        let before = NativeWindowObservation.ScrollViewport(
            window: window, root: identity, region: identity, meter: identity,
            content: identity, document: NativeWindowObservation.documentSubject(
                window: window, identifier: "file:///owned.txt"),
            title: Data("Owned".utf8), frame: CGRect(x: 0, y: 30, width: 400, height: 270),
            windowFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentSize: CGSize(width: 400, height: 2000), contentDigest: Data("body".utf8),
            point: CGPoint(x: 200, y: 150), metric: .verticalBar, position: 0.2,
            minimum: 0, maximum: 1, capturedAt: 1)
        var moved = before
        moved.position = 0.4
        moved.capturedAt = 3
        moved.readGeneration = UUID()
        XCTAssertTrue(moved.moved(from: before, direction: "down", dispatchedAt: 2))
        XCTAssertFalse(moved.moved(from: before, direction: "up", dispatchedAt: 2))
        XCTAssertFalse(moved.moved(from: before, direction: "right", dispatchedAt: 2))
        for variant in ["window", "region", "meter", "document", "content", "geometry",
                        "point", "generation", "clock", "unchanged", "nonfinite"] {
            var changed = moved
            switch variant {
            case "window": changed.window = WindowRef(pid: 424243, windowID: 7)
            case "region": changed.region = other
            case "meter": changed.meter = other
            case "document":
                changed.document = NativeWindowObservation.documentSubject(
                    window: window, identifier: "file:///different.txt")
            case "content": changed.contentDigest = Data("different body".utf8)
            case "geometry": changed.frame.origin.y += 1
            case "point": changed.point.x += 50
            case "generation": changed.readGeneration = before.readGeneration
            case "clock": changed.capturedAt = 1.9
            case "unchanged": changed.position = before.position
            default: changed.position = .nan
            }
            XCTAssertFalse(changed.moved(from: before, direction: "down", dispatchedAt: 2), variant)
        }
        var rtl = before
        rtl.metric = .horizontalBar
        rtl.position = -0.8
        rtl.minimum = -1
        rtl.maximum = 0
        var right = rtl
        right.position = -0.2
        right.readGeneration = UUID()
        right.capturedAt = 3
        XCTAssertTrue(right.moved(from: rtl, direction: "right", dispatchedAt: 2))
        XCTAssertFalse(right.moved(from: rtl, direction: "left", dispatchedAt: 2))
        right.position = 0
        XCTAssertTrue(right.atEdge(direction: "right"))
        XCTAssertFalse(right.atEdge(direction: "left"))
    }

    func testConversationScrollKeepsItsRegionAndRejectsChangedSubject() async throws {
        let identity = NativeFieldIdentity(AXUIElementCreateApplication(424242))
        let window = WindowRef(pid: 424242, windowID: 7)
        let anchor = NativeWindowObservation.ScrollViewport(
            window: window, root: identity, region: identity, meter: identity,
            content: identity, document: NativeWindowObservation.documentSubject(
                window: window, identifier: "file:///owned.txt"),
            title: Data("Owned".utf8), frame: CGRect(x: 0, y: 30, width: 400, height: 270),
            windowFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentSize: CGSize(width: 400, height: 2000), contentDigest: Data("body".utf8),
            point: CGPoint(x: 200, y: 150), metric: .verticalBar, position: 0.2,
            minimum: 0, maximum: 1, capturedAt: 1)
        let driver = FakeDriver()
        driver.responses["list_windows"] = Array(repeating: windows([
            windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Owned",
                      x: 0, y: 0, w: 400, h: 300),
        ]), count: 4)
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in XCTFail("Changed subject must stop before model choice"); return nil },
            ask: nil, granted: { true }, gaze: {
                XCTFail("A continuation cannot choose a new gaze region")
                throw CancellationError()
            }, nativeScrollRead: { _, point, _, previous in
                XCTAssertEqual(point, anchor.point)
                XCTAssertNotNil(previous)
                var changed = anchor
                changed.contentDigest = Data("another document".utf8)
                return changed
            }, scrollContinuation: anchor)
        var history: [String] = [], confirmed = false
        let resolved = DriveLoop.FastResolution(action: try XCTUnwrap(FastAction.parse("scroll down")).action,
            openVerb: nil, name: "AuditFixture", bundle: "fixture.audit", pid: 424242)
        let result = try await loop.runFastLane(resolved,
            task: DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
            session: "continuation-region", history: &history, confirmed: &confirmed)
        XCTAssertNotEqual(result?.status, .done)
        XCTAssertFalse(driver.calls.contains { $0.tool == "scroll" })
    }

    func testC1UncertainScrollDispatchIsNotResurrectedOrRetried() async throws {
        let driver = FakeDriver()
        driver.thrown["scroll"] = DriverConnectionError.remote("session has ended")
        let loop = verifiedScrollLoop(driver)
        var history: [String] = [], confirmed = false
        let resolved = DriveLoop.FastResolution(action: try XCTUnwrap(FastAction.parse("scroll down")).action,
            openVerb: nil, name: "AuditFixture", bundle: "fixture.audit", pid: 424242)
        let result = try await loop.runFastLane(resolved,
            task: DriveTask(goal: "scroll down", application: "fixture.audit", pid: 424242, windowID: 7),
            session: "scroll-uncertain", history: &history, confirmed: &confirmed)
        XCTAssertNotEqual(result?.status, .done)
        XCTAssertEqual(result?.blockedReason, "scroll_outcome_unverified")
        XCTAssertEqual(driver.calls.filter { $0.tool == "scroll" }.count, 1)
        XCTAssertFalse(driver.calls.contains { $0.tool == "start_session" })
    }

    // MARK: - appHint merge

    private func boundTypeLoop(_ driver: FakeDriver, available: Bool = true,
                               frontmost: String? = "fixture.bound",
                               expectedText: String = "Jev audit alpha") -> DriveLoop {
        let app = AppResolver.App(name: "BoundFixture", bundle: "fixture.bound", pid: 42)
        driver.responses["list_windows"] = Array(repeating: windows([
            windowRow(id: 7, pid: 42, app: app.name, title: "Owned",
                      x: 0, y: 0, w: 400, h: 300)
        ]), count: 8)
        func state(_ value: String) -> JSONValue {
            .object(["elements": .array([.object([
                "element_index": .number(1), "element_token": .string("owned-field"),
                "role": .string("AXTextArea"), "label": .string("Owned"),
                "value": .string(value)
            ])])])
        }
        driver.responses["get_window_state"] = [state(""), state(expectedText)]
        driver.thrown["list_apps"] = DriverConnectionError.refused("global inventory unavailable")
        return DriveLoop(call: { tool, args in
                             if tool == "get_window_state", args["tree_format"] != .string("elements") {
                                 return .object(["tree_markdown": .string("fixture")])
                             }
                             return try driver.call(tool, args)
                         }, choose: { _, _ in driver.modelCalls += 1; return nil },
                         ask: nil, granted: { true }, explicitConsent: false,
                         resolver: AppResolver(listApps: { available ? [app] : [] }),
                         activateApp: { _ in }, activateRestoredApp: { _, _ in },
                         frontmostBundleID: { frontmost })
    }

    func testBoundLiteralTypesWithoutGlobalInventory() async {
        let driver = FakeDriver(), payload = "Jev audit alpha"
        let loop = boundTypeLoop(driver)
        var task = DriveTask(goal: "type \"\(payload)\"", application: "fixture.bound", pid: 42, windowID: 7)
        task.values["text"] = payload
        let result = await loop.run(task, session: "bound-type")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.modelCalls, 0)
        XCTAssertFalse(driver.calls.contains { $0.tool == "list_apps" })
        let mutations = driver.calls.filter { $0.tool == "type_text" }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.args["text"], .string(payload))
        XCTAssertEqual(mutations.first?.args["window_id"], .number(7))
        XCTAssertTrue(driver.calls.contains { $0.tool == "get_window_state" },
                      "the exact field must still be observed and verified")
        let observations = driver.calls.filter { $0.tool == "get_window_state" }
        XCTAssertEqual(observations.count, 2)
        XCTAssertTrue(observations.allSatisfy { $0.args["tree_format"] == .string("elements") })
    }

    func testBoundLiteralMissingOrWrongCaseReadbackNeverClaimsDone() async {
        let payload = "Jev audit alpha"
        for observed in ["", payload.uppercased()] {
            let driver = FakeDriver()
            let loop = boundTypeLoop(driver, expectedText: observed)
            let task = DriveTask(goal: "type \"\(payload)\"", application: "fixture.bound",
                                 pid: 42, windowID: 7, values: ["text": payload])
            let result = await loop.run(task, session: "unverified-native")
            XCTAssertNotEqual(result.status, .done)
            XCTAssertFalse(result.dispatchedEffect)
            XCTAssertEqual(driver.calls.filter { $0.tool == "type_text" }.count, 1)
        }
    }

    func testBoundLiteralInventoryShortcutRejectsExcludedConditions() async {
        for variant in ["missing", "mismatch", "qualified", "unavailable", "deictic", "named", "risk"] {
            let driver = FakeDriver()
            let loop = boundTypeLoop(driver, available: variant != "unavailable")
            let payload = variant == "risk" ? "literal payload" : "Jev audit alpha"
            let goal = variant == "qualified" ? "type \"\(payload)\" in BoundFixture"
                : (variant == "deictic" ? "type \"\(payload)\" here" : "type \"\(payload)\"")
            var task = DriveTask(goal: goal, application: variant == "named" ? "BoundFixture" : "fixture.bound",
                                 pid: 42, windowID: 7)
            if variant != "missing" { task.values["text"] = variant == "mismatch" ? "different" : payload }
            _ = await loop.run(task, session: "bound-type-\(variant)")
            XCTAssertTrue(driver.calls.contains { $0.tool == "list_apps" }, variant)
            XCTAssertFalse(driver.calls.contains { $0.tool == "type_text" }, variant)
        }
    }

    func testBoundQuotedLiteralRetainsWhitespaceAndQuotes() async {
        for text in [" Jev audit alpha", "  Case, punctuation!  ", "\"inner quotes\"",
                     " do not open Calculator", " type the word stop"] {
            let driver = FakeDriver()
            let loop = boundTypeLoop(driver, expectedText: text)
            var task = DriveTask(goal: "type \"\(text)\"", application: "fixture.bound", pid: 42, windowID: 7)
            task.values["text"] = text
            let result = await loop.run(task, session: "bound-quoted")
            XCTAssertEqual(result.status, .done)
            XCTAssertFalse(driver.calls.contains { $0.tool == "list_apps" })
            XCTAssertEqual(driver.modelCalls, 0)
            let writes = driver.calls.filter { $0.tool == "type_text" }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?.args["text"], .string(text))
            XCTAssertEqual(writes.first?.args["window_id"], .number(7))
        }
    }

    func testBoundQuotedDangerousPayloadStillRefusesBeforeMutation() async {
        let text = "  rm -rf /tmp/jev-not-executed  "
        let driver = FakeDriver()
        let protectedLoop = boundTypeLoop(driver)
        var task = DriveTask(goal: "type \"\(text)\"", application: "fixture.bound", pid: 42, windowID: 7)
        task.values["text"] = text
        let result = await protectedLoop.run(task, session: "bound-dangerous")
        XCTAssertNotEqual(result.status, .done)
        XCTAssertFalse(driver.calls.contains { ["type_text", "hotkey"].contains($0.tool) })
    }

    func testBoundEditingHotkeysDoNotNeedGlobalInventory() async {
        for (goal, keys) in [("undo", ["cmd", "z"]), ("redo", ["cmd", "shift", "z"]),
                             ("select all", ["cmd", "a"])] {
            let driver = FakeDriver(), loop = boundTypeLoop(driver)
            let result = await loop.run(DriveTask(goal: goal, application: "fixture.bound", pid: 42, windowID: 7),
                                        session: "bound-edit")
            XCTAssertEqual(result.status, .done, goal)
            XCTAssertFalse(driver.calls.contains { $0.tool == "list_apps" }, goal)
            let mutations = driver.calls.filter { $0.tool == "hotkey" }
            XCTAssertEqual(mutations.count, 1, goal)
            XCTAssertEqual(mutations.first?.args["keys"], .array(keys.map(JSONValue.string)), goal)
            XCTAssertEqual(mutations.first?.args["window_id"], .number(7), goal)
            XCTAssertEqual(driver.modelCalls, 0, goal)
            XCTAssertTrue(driver.calls.contains { $0.tool == "list_windows" }, goal)
        }
    }

    func testBoundEditingShortcutPreservesExcludedScope() async {
        for variant in ["qualified", "deictic", "named", "nonfrontmost", "unavailable", "risk"] {
            let driver = FakeDriver()
            let loop = boundTypeLoop(driver, available: variant != "unavailable",
                                     frontmost: variant == "nonfrontmost" ? "fixture.other" : "fixture.bound")
            let goal = variant == "qualified" ? "undo in BoundFixture"
                : (variant == "deictic" ? "undo here" : (variant == "risk" ? "press enter to send" : "undo"))
            let result = await loop.run(DriveTask(goal: goal,
                application: variant == "named" ? "BoundFixture" : "fixture.bound",
                pid: 42, windowID: 7), session: "bound-edit-\(variant)")
            XCTAssertTrue(driver.calls.contains { $0.tool == "list_apps" } || result.status != .done, variant)
            XCTAssertFalse(driver.calls.contains { $0.tool == "hotkey" }, variant)
        }
    }

    private func coldFocusLoop(_ driver: FakeDriver, lease: AsyncLease? = nil,
                               observed: ((String) async -> Int?)? = nil,
                               nativeWindow: Int? = nil,
                               nativeWindowReads: LockedBox<Int>? = nil,
                               restored: ((Int, String?) -> Void)? = nil,
                               frontPID: Int? = 424242, frontWindow: Int? = 7,
                               frontWindowProbe: (() -> Int?)? = nil,
                               nativeProof: @escaping @Sendable (Int) async -> Int? = { _ in nil },
                               nativeEvents: @escaping @Sendable (VoiceCommandTrace.Stage) async -> Void = { _ in },
                               native: @escaping (String) async throws -> Int) -> DriveLoop {
        driver.responses["launch_app"] = [.object(["pid": .number(424242)])]
        driver.responses["list_windows"] = Array(repeating: windows([
            windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Owned",
                      x: 0, y: 0, w: 400, h: 400)
        ]), count: 8)
        driver.responses["bring_to_front"] = [
            .object(["activated": .bool(true), "exact_window_effect": .object(["verified": .bool(true)])])]
        return DriveLoop(call: { try driver.call($0, $1) }, choose: { _, _ in
            XCTFail("app focus must not invoke a model"); return nil
        }, ask: { _ in XCTFail("instruction supplies consent"); return nil }, granted: { false }, focusLease: lease,
        nativeFocusedWindowID: { _ in
            if let nativeWindowReads { nativeWindowReads.set(nativeWindowReads.value + 1) }
            return nativeWindow
        },
        nativeForegroundWindow: nativeProof,
        nativeEvent: nativeEvents,
        activateApp: { _ in }, appIsHidden: { _ in false }, unhideApp: { _ in true },
        activateRestoredApp: restored ?? { _, _ in XCTFail("a completed native launch must not be reopened again") },
        foregroundAppLauncher: native,
        observeLaunchedPID: observed ?? { await DriveLoop.observedPID(bundle: $0) },
        frontmostBundleID: { "fixture.audit" }, frontmostPID: { frontPID },
        frontmostWindowID: frontWindowProbe ?? { frontWindow })
    }

    func testExactNativeForegroundProofAvoidsInventoryRPC() async throws {
        let driver = FakeDriver()
        let loop = coldFocusLoop(driver, nativeProof: { _ in 7 }) { _ in 424242 }
        var history: [String] = [], confirmed = false
        let result = try await loop.runFastLane(
            DriveLoop.FastResolution(action: nil, openVerb: "open", name: "AuditFixture", bundle: "fixture.audit"),
            task: DriveTask(goal: "open AuditFixture", foreground: true),
            session: "native-fresh-proof", history: &history, confirmed: &confirmed)
        XCTAssertEqual(result?.status, .done)
        XCTAssertTrue(driver.calls.isEmpty, "Fresh exact native proof must not wait for redundant SDK inventory.")
    }

    func testNativeActivationFailureClosesTraceWithoutRetry() async throws {
        for cancelled in [false, true] {
            let driver = FakeDriver(), stages = LockedBox([String]())
            let loop = coldFocusLoop(driver, observed: { _ in nil },
                nativeEvents: { stage in stages.set(stages.value + [stage.rawValue]) }) { _ in
                if cancelled { throw CancellationError() }
                throw DriverConnectionError.refused("Owned fixture failure")
            }
            var history: [String] = [], confirmed = false
            do {
                let result = try await loop.runFastLane(
                    DriveLoop.FastResolution(action: nil, openVerb: "open", name: "AuditFixture", bundle: "fixture.audit"),
                    task: DriveTask(goal: "open AuditFixture", foreground: true),
                    session: "native-failure", history: &history, confirmed: &confirmed)
                XCTAssertNotEqual(result?.status, .done)
                XCTAssertFalse(cancelled)
            } catch is CancellationError {
                XCTAssertTrue(cancelled)
            }
            XCTAssertEqual(stages.value, ["nativeActivationBegin", "nativeActivationFailed"])
            XCTAssertTrue(driver.calls.isEmpty, "An uncertain native request must never be retried through the SDK.")
        }
    }

    func testNativeSemanticFocusKeepsTraceScopedToTheRun() async {
        let stages = LockedBox([String]())
        let loop = DriveLoop(call: { _, _ in XCTFail("Exact native focus needs no SDK read"); return .object([:]) },
            choose: { _, _ in XCTFail("No model"); return nil }, ask: nil, granted: { true },
            resolver: AppResolver(listApps: {
                [.init(name: "Owned fixture", bundle: "fixture.target", pid: 424242)]
            }), nativeForegroundWindow: { _ in 7 }, activateRestoredApp: { _, _ in })
        let task = DriveTask(goal: "Focus confirmed application", application: "fixture.target",
                             scope: .open, foreground: true)
        let result = await loop.runAppFocus(bundleID: "fixture.target", task: task,
            session: "native-semantic", nativeEvents: { stage in
                stages.set(stages.value + [stage.rawValue])
            })
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(stages.value, ["nativeActivationBegin", "nativeActivationEnd",
            "nativeForegroundReadBegin", "nativeForegroundReadEnd", "nativeForegroundVerified"])
    }

    /// "click open in maps": a control called Open in Maps in the front
    /// window is clicked there, and Maps is never launched.
    func testWholeNameInTheFrontWindowBeatsTheAppScope() async throws {
        guard FastAction.isAppOnThisMac("maps") else { throw XCTSkip("Maps isn't installed") }
        let parsed = try XCTUnwrap(FastAction.parse("click open in maps"))
        let driver = FakeDriver()
        driver.responses["get_window_state"] = [.object([
            "pid": .number(4242), "window_id": .number(9),
            "elements": .array([.object([
                "element_index": .number(1), "role": .string("AXButton"),
                "label": .string("Open in Maps"), "element_token": .string("front-open"),
                "actions": .array([.string("AXPress")]),
                "frame": .object(["x": .number(10), "y": .number(10), "w": .number(120), "h": .number(30)]),
            ])]),
        ])]
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in XCTFail("a named click needs no model"); return nil },
            ask: nil, granted: { true },
            frontmostBundleID: { "fixture.front" }, frontmostPID: { 4242 }, frontmostWindowID: { 9 })
        var history: [String] = [], confirmed = false
        let result = try await loop.runFastLane(
            DriveLoop.FastResolution(action: parsed.action, openVerb: nil, name: "Maps", bundle: "com.apple.Maps"),
            task: DriveTask(goal: "click open in maps"), session: "whole-name", history: &history,
            confirmed: &confirmed)
        XCTAssertEqual(result?.status, .done)
        let click = try XCTUnwrap(driver.calls.first { $0.tool == "click" })
        XCTAssertEqual(click.args["element_token"], .string("front-open"))
        XCTAssertEqual(click.args["pid"], .number(4242))
        XCTAssertFalse(driver.calls.contains { $0.tool == "launch_app" })
    }

    /// "click Save in Pages": a front-window link that only mentions the
    /// phrase ("How to save in Pages documents") is never clicked for it.
    func testWholeNameNeedsAnExactOrLeadingLabel() async throws {
        var action = try XCTUnwrap(FastAction.parse("click save")).action
        action.wholeName = "save in pages"
        let driver = FakeDriver()
        driver.responses["get_window_state"] = [.object([
            "pid": .number(4242), "window_id": .number(9),
            "elements": .array([.object([
                "element_index": .number(1), "role": .string("AXLink"),
                "label": .string("How to save in Pages documents"), "element_token": .string("front-help"),
                "actions": .array([.string("AXPress")]),
                "frame": .object(["x": .number(10), "y": .number(10), "w": .number(240), "h": .number(20)]),
            ])]),
        ])]
        let loop = DriveLoop(call: { try driver.call($0, $1) },
            choose: { _, _ in nil }, ask: nil, granted: { true },
            frontmostBundleID: { "fixture.front" }, frontmostPID: { 4242 }, frontmostWindowID: { 9 })
        var history: [String] = [], confirmed = false
        _ = try await loop.runFastLane(
            DriveLoop.FastResolution(action: action, openVerb: nil, name: "Pages", bundle: "com.apple.iWork.Pages"),
            task: DriveTask(goal: "click save in pages"), session: "whole-name-strict", history: &history,
            confirmed: &confirmed)
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" && $0.args["element_token"] == .string("front-help") })
        XCTAssertTrue(history.contains("No control called save in pages in this window."))
    }

    func testNativeProofCannotBypassNamedOrPinnedWindowInventory() async throws {
        for named in [false, true] {
            let driver = FakeDriver(), proofs = LockedBox(0)
            let loop = coldFocusLoop(driver, nativeWindow: 7, restored: { _, _ in },
                nativeProof: { _ in proofs.set(proofs.value + 1); return 7 }) { _ in 424242 }
            var task = DriveTask(goal: "open AuditFixture", pid: 424242, foreground: true)
            if named { task.windowName = "Owned" } else { task.windowID = 7 }
            var history: [String] = [], confirmed = false
            _ = try await loop.runFastLane(
                DriveLoop.FastResolution(action: nil, openVerb: "open", name: "AuditFixture", bundle: "fixture.audit"),
                task: task, session: "native-qualified", history: &history, confirmed: &confirmed)
            XCTAssertEqual(proofs.value, 0)
            XCTAssertTrue(driver.calls.contains { $0.tool == "list_windows" })
        }
    }

    func testNativeForegroundValidatorRequiresIndependentExactProofs() {
        func row(_ id: Int, pid: Int = 42, layer: Int = 0, visible: Bool = true) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: layer, kCGWindowIsOnscreen as String: visible]
        }
        for variant in ["valid", "pid", "missing_focus", "missing_row", "different_window",
                        "offscreen", "layer", "wrong_owner", "different_owner_first",
                        "foreign_front", "offscreen_before_valid"] {
            var rows = [row(7), row(99, pid: 99)]
            if variant == "missing_row" { rows = [] }
            if variant == "different_window" { rows = [row(8)] }
            if variant == "offscreen" { rows = [row(7, visible: false)] }
            if variant == "layer" { rows = [row(7, layer: 3)] }
            if variant == "wrong_owner" { rows = [row(7, pid: 99)] }
            if variant == "different_owner_first" { rows = [row(8), row(7)] }
            if variant == "foreign_front" { rows = [row(99, pid: 99), row(7)] }
            if variant == "offscreen_before_valid" { rows = [row(8, visible: false), row(7)] }
            let verified = DriveLoop.verifiedForegroundWindowID(
                pid: 42, frontmost: variant == "pid" ? 99 : 42,
                focused: variant == "missing_focus" ? nil : 7, rows: rows)
            XCTAssertEqual(verified, ["valid", "offscreen_before_valid"].contains(variant) ? 7 : nil, variant)
        }
    }

    @MainActor
    func testNativeForegroundProbeRejectsImpossibleCandidateBeforeFocusedRead() {
        func row(_ pid: Int, visible: Bool = true) -> [String: Any] {
            [kCGWindowNumber as String: 7, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: visible]
        }
        for variant in ["foreign", "empty", "offscreen", "wrong_pid"] {
            var reads = 0
            let rows = variant == "empty" ? [] : [row(variant == "foreign" ? 99 : 42,
                                                      visible: variant != "offscreen")]
            let result = DriveLoop.observeForegroundWindow(pid: 42,
                frontmost: { variant == "wrong_pid" ? 99 : 42 },
                focusedWindow: { _ in reads += 1; return 7 }, windows: { rows })
            XCTAssertNil(result, variant)
            XCTAssertEqual(reads, 0, variant)
        }
    }

    @MainActor
    func testNativeForegroundProbeKeepsFreshProofAndFinalRechecks() {
        func row(_ pid: Int, visible: Bool = true) -> [String: Any] {
            [kCGWindowNumber as String: 7, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: visible]
        }
        for variant in ["valid", "foreign_during_ax", "focus_changed", "pid_changed", "offscreen_first"] {
            var focusedReads = 0
            var foreign = false
            let result = DriveLoop.observeForegroundWindow(pid: 42,
                frontmost: { variant == "pid_changed" && focusedReads > 0 ? 99 : 42 },
                focusedWindow: { _ in
                    focusedReads += 1
                    if variant == "foreign_during_ax" { foreign = true }
                    return variant == "focus_changed" && focusedReads > 1 ? 8 : 7
                },
                windows: {
                    if foreign { return [row(99), row(42)] }
                    return variant == "offscreen_first" ? [row(99, visible: false), row(42)] : [row(42)]
                })
            XCTAssertEqual(result, ["valid", "offscreen_first"].contains(variant) ? 7 : nil, variant)
        }
    }

    func testVerifiedNativeForegroundEffectDoesNotIssueRedundantDriverRaise() async throws {
        let driver = FakeDriver(), reads = LockedBox(0), restores = LockedBox(0)
        let loop = coldFocusLoop(driver, nativeWindow: 7, nativeWindowReads: reads,
                                restored: { _, _ in restores.set(restores.value + 1) }) { _ in
            XCTFail("Existing app must not be relaunched"); return 424242
        }
        driver.thrown["bring_to_front"] = DriverConnectionError.toolRefused(
            tool: "bring_to_front", code: "tool_invocation_failed", detail: "No running application for pid 424242")
        let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
            name: "AuditFixture", bundle: "fixture.audit")
        var history: [String] = [], confirmed = false
        do {
            let result = try await loop.runFastLane(resolved,
                task: DriveTask(goal: "open AuditFixture", pid: 424242, foreground: true),
                session: "native-already-front", history: &history, confirmed: &confirmed)
            XCTAssertEqual(result?.status, .done)
            XCTAssertTrue(result?.dispatchedEffect ?? false)
        } catch { XCTFail("An independently verified native effect must not be replaced by a redundant raise error") }
        XCTAssertEqual(restores.value, 1)
        XCTAssertEqual(reads.value, 1)
        XCTAssertFalse(driver.calls.contains { $0.tool == "bring_to_front" })
    }

    func testNativeForegroundShortcutRequiresEveryExactProofAndUnqualifiedRequest() async throws {
        for variant in ["pid", "window", "native", "offscreen", "pinned", "named", "exited"] {
            let driver = FakeDriver()
            let loop = coldFocusLoop(driver, nativeWindow: variant == "native" ? 8 : (variant == "exited" ? nil : 7),
                restored: { _, _ in },
                frontPID: variant == "pid" ? 123 : (variant == "exited" ? nil : 424242),
                frontWindow: variant == "window" ? 123 : 7) { _ in 424242 }
            if variant == "offscreen" {
                driver.responses["list_windows"] = Array(repeating: windows([
                    windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Owned",
                              x: 0, y: 0, w: 400, h: 400, onScreen: false)
                ]), count: 16)
            }
            driver.thrown["bring_to_front"] = DriverConnectionError.toolRefused(
                tool: "bring_to_front", code: "tool_invocation_failed", detail: "No running application for pid 424242")
            let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
                name: "AuditFixture", bundle: "fixture.audit")
            var task = DriveTask(goal: "open AuditFixture", pid: 424242, foreground: true)
            if variant == "pinned" { task.windowID = 7 }
            if variant == "named" { task.windowName = "Owned" }
            var history: [String] = [], confirmed = false
            do {
                let result = try await loop.runFastLane(resolved, task: task, session: "proof-\(variant)",
                    history: &history, confirmed: &confirmed)
                XCTAssertNotEqual(result?.status, .done, variant)
            } catch is DriverConnectionError {}
            XCTAssertEqual(driver.calls.filter { $0.tool == "bring_to_front" }.count, 1, variant)
        }
    }

    func testNativeForegroundSettlesAsyncActivationBeforeRedundantRaise() async throws {
        let driver = FakeDriver(), checks = LockedBox(0)
        let loop = coldFocusLoop(driver, nativeWindow: 7, restored: { _, _ in },
                                frontWindowProbe: {
            checks.set(checks.value + 1)
            return checks.value >= 2 ? 7 : nil
        }) { _ in 424242 }
        driver.thrown["bring_to_front"] = DriverConnectionError.toolRefused(
            tool: "bring_to_front", code: "tool_invocation_failed", detail: "No running application for pid 424242")
        let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
            name: "AuditFixture", bundle: "fixture.audit")
        var history: [String] = [], confirmed = false
        do {
            let result = try await loop.runFastLane(resolved,
                task: DriveTask(goal: "open AuditFixture", pid: 424242, foreground: true),
                session: "native-settle", history: &history, confirmed: &confirmed)
            XCTAssertEqual(result?.status, .done)
        } catch { XCTFail("Native asynchronous activation must receive bounded read-only settlement") }
        XCTAssertFalse(driver.calls.contains { $0.tool == "bring_to_front" })
        XCTAssertGreaterThanOrEqual(checks.value, 2)
    }

    func testColdRequestedFocusUsesNativeForegroundLaunchOnce() async throws {
        let driver = FakeDriver()
        var launches = 0
        let loop = coldFocusLoop(driver) { bundle in
            XCTAssertEqual(bundle, "fixture.audit"); launches += 1; return 424242
        }
        let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
            name: "AuditFixture", bundle: "fixture.audit")
        var history: [String] = [], confirmed = false
        let result = try await loop.runFastLane(resolved,
            task: DriveTask(goal: "open AuditFixture", scope: .open, foreground: true), session: "audit",
            history: &history, confirmed: &confirmed)
        XCTAssertEqual(result?.status, .done)
        XCTAssertEqual(launches, 1)
        XCTAssertFalse(driver.calls.contains { $0.tool == "launch_app" })
        XCTAssertEqual(driver.calls.filter { $0.tool == "bring_to_front" }.count, 1)
    }

    func testForegroundUntitledOffscreenWindowUsesNativeIdentityNotTitle() async throws {
        for ids in [[7], [7, 8]] {
            let driver = FakeDriver()
            let loop = coldFocusLoop(driver, nativeWindow: 7) { _ in 424242 }
            driver.responses["list_windows"] = [windows(ids.map { id in
                windowRow(id: id, pid: 424242, app: "AuditFixture", title: "",
                          x: 0, y: 0, w: 400, h: 400, onScreen: false)
            })]
            let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
                name: "AuditFixture", bundle: "fixture.audit")
            var history: [String] = [], confirmed = false
            let result = try await loop.runFastLane(resolved,
                task: DriveTask(goal: "open AuditFixture", scope: .open, foreground: true),
                session: "untitled-native", history: &history, confirmed: &confirmed)
            XCTAssertEqual(result?.status, .done)
            let raises = driver.calls.filter { $0.tool == "bring_to_front" }
            XCTAssertEqual(raises.count, 1)
            XCTAssertEqual(raises.first?.args["window_id"], .number(7))
        }
    }

    func testForegroundUnknownNativeWindowCannotInventOrClaimEffect() async throws {
        for nativeWindow in [nil, 999] as [Int?] {
            let driver = FakeDriver()
            let loop = coldFocusLoop(driver, nativeWindow: nativeWindow) { _ in 424242 }
            driver.responses["list_windows"] = [windows([
                windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "",
                          x: 0, y: 0, w: 400, h: 400, onScreen: false)
            ])]
            let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
                name: "AuditFixture", bundle: "fixture.audit")
            var history: [String] = [], confirmed = false
            let result = try await loop.runFastLane(resolved,
                task: DriveTask(goal: "open AuditFixture", scope: .open, foreground: true),
                session: "unknown-native", history: &history, confirmed: &confirmed)
            XCTAssertNotEqual(result?.status, .done)
            XCTAssertFalse(result?.dispatchedEffect ?? true)
            XCTAssertFalse(driver.calls.contains { $0.tool == "bring_to_front" })
        }
    }

    func testPinnedOrNamedOpenNeverUsesNativeFallbackToSubstituteWindow() async throws {
        for (named, invalidMatch) in [(false, false), (true, false), (true, true)] {
            let driver = FakeDriver(), reads = LockedBox(0)
            let loop = coldFocusLoop(driver, nativeWindow: 7, nativeWindowReads: reads) { _ in
                XCTFail("A bound existing app must not be relaunched"); return 424242
            }
            var task = DriveTask(goal: "show AuditFixture", pid: 424242, foreground: true)
            if named { task.windowName = invalidMatch ? "Desired" : "Missing named window" }
            else { task.windowID = 999 }
            if invalidMatch {
                driver.responses["list_windows"] = [windows([
                    windowRow(id: 0, pid: 424242, app: "AuditFixture", title: "Desired",
                              x: 0, y: 0, w: 400, h: 400),
                    windowRow(id: 7, pid: 424242, app: "AuditFixture", title: "Other",
                              x: 0, y: 0, w: 400, h: 400)
                ])]
            }
            let resolved = DriveLoop.FastResolution(action: nil, openVerb: "show",
                name: "AuditFixture", bundle: "fixture.audit")
            var history: [String] = [], confirmed = false
            do {
                let result = try await loop.runFastLane(resolved, task: task, session: "bound-open",
                    history: &history, confirmed: &confirmed)
                XCTAssertNotEqual(result?.status, .done)
            } catch let error as DriverConnectionError {
                guard case .refused = error else { return XCTFail("Expected target refusal") }
            }
            XCTAssertEqual(reads.value, 0)
            XCTAssertFalse(driver.calls.contains { $0.tool == "bring_to_front" || $0.tool == "launch_app" })
        }
    }

    func testNativeLaunchErrorNeverRetriesBackgroundPrimitive() async throws {
        let driver = FakeDriver()
        var launches = 0
        let loop = coldFocusLoop(driver) { _ in
            launches += 1
            throw DriverConnectionError.refused("request may have reached the OS")
        }
        let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
            name: "AuditFixture", bundle: "fixture.audit")
        var history: [String] = [], confirmed = false
        let result = try await loop.runFastLane(resolved,
            task: DriveTask(goal: "open AuditFixture", scope: .open, foreground: true), session: "audit",
            history: &history, confirmed: &confirmed)
        XCTAssertNotEqual(result?.status, .done)
        XCTAssertEqual(launches, 1)
        XCTAssertFalse(driver.calls.contains { $0.tool == "launch_app" })
    }

    func testNativeErrorObservedProcessStillRequiresVerifiedWindow() async throws {
        let driver = FakeDriver()
        var launches = 0
        let loop = coldFocusLoop(driver, observed: { _ in 424242 }) { _ in
            launches += 1
            throw DriverConnectionError.refused("native dispatch uncertain")
        }
        let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
            name: "AuditFixture", bundle: "fixture.audit")
        var history: [String] = [], confirmed = false
        let result = try await loop.runFastLane(resolved,
            task: DriveTask(goal: "open AuditFixture", scope: .open, foreground: true), session: "audit",
            history: &history, confirmed: &confirmed)
        XCTAssertEqual(result?.status, .done)
        XCTAssertEqual(launches, 1)
        XCTAssertFalse(driver.calls.contains { $0.tool == "launch_app" })
        XCTAssertEqual(driver.calls.filter { $0.tool == "bring_to_front" }.count, 1)
    }

    func testNativeLaunchCancelledWhileQueuedNeverDispatches() async throws {
        let lease = AsyncLease(), driver = FakeDriver()
        await lease.acquire()
        var launches = 0
        let loop = coldFocusLoop(driver, lease: lease) { _ in launches += 1; return 424242 }
        let worker = Task {
            var history: [String] = [], confirmed = false
            let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
                name: "AuditFixture", bundle: "fixture.audit")
            return try await loop.runFastLane(resolved,
                task: DriveTask(goal: "open AuditFixture", scope: .open, foreground: true), session: "audit",
                history: &history, confirmed: &confirmed)
        }
        for _ in 0..<100 {
            if await lease.queuedCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let queued = await lease.queuedCount
        XCTAssertEqual(queued, 1)
        worker.cancel()
        await lease.release()
        _ = try? await worker.value
        XCTAssertEqual(launches, 0)
        XCTAssertFalse(driver.calls.contains { $0.tool == "launch_app" })
        let acquired = await lease.tryAcquire()
        XCTAssertTrue(acquired, "cancelled waiter must release its handed-off lease")
        if acquired { await lease.release() }
    }

    func testForegroundNativeLaunchDoesNotBypassDeny() async throws {
        let driver = FakeDriver()
        let loop = coldFocusLoop(driver) { _ in XCTFail("denied request"); return 424242 }
        let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
            name: "AuditFixture", bundle: "fixture.audit")
        var history: [String] = [], confirmed = false
        do {
            _ = try await loop.runFastLane(resolved,
                task: DriveTask(goal: "open AuditFixture", scope: .open, deny: ["auditfixture"],
                                foreground: true), session: "audit",
                history: &history, confirmed: &confirmed)
            XCTFail("deny must refuse before launch")
        } catch {
            XCTAssertTrue(String(describing: error).contains("denied"))
        }
        XCTAssertTrue(driver.calls.isEmpty)
    }

    func testColdBackgroundOpenRetainsDriverPrimitive() async throws {
        let driver = FakeDriver()
        let loop = coldFocusLoop(driver) { _ in XCTFail("not a foreground focus request"); return 424242 }
        let resolved = DriveLoop.FastResolution(action: nil, openVerb: "open",
            name: "AuditFixture", bundle: "fixture.audit", launchURLs: ["https://example.com"])
        var history: [String] = [], confirmed = false
        _ = try await loop.runFastLane(resolved,
            task: DriveTask(goal: "open AuditFixture", scope: .open), session: "audit",
            history: &history, confirmed: &confirmed)
        XCTAssertEqual(driver.calls.filter { $0.tool == "launch_app" }.count, 1)
        XCTAssertEqual(driver.calls.first { $0.tool == "launch_app" }?.args["urls"],
                       .array([.string("https://example.com")]))
    }

    func testColdPinnedWindowCannotLaunchReplacementApp() async throws {
        let driver = FakeDriver()
        let loop = coldFocusLoop(driver) { _ in XCTFail("pinned target is gone"); return 424242 }
        let resolved = DriveLoop.FastResolution(action: nil, openVerb: "show",
            name: "AuditFixture", bundle: "fixture.audit")
        var history: [String] = [], confirmed = false
        do {
            let result = try await loop.runFastLane(resolved,
                task: DriveTask(goal: "show AuditFixture", windowID: 999, scope: .open, foreground: true),
                session: "audit", history: &history, confirmed: &confirmed)
            XCTAssertNotEqual(result?.status, .done)
        } catch {
            XCTAssertTrue(String(describing: error).contains("refused"))
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "launch_app" })
    }

    /// A goal that doesn't parse alone completes against the model's `app`
    /// arg: "quit" + app:"Devin" reads as "quit devin" and lanes as app
    /// control — the bare utterance resolving nothing is the only time the
    /// merge runs.
    func testAppHintMergeResolvesAppControl() {
        let devin = appRow("Devin", "com.devin.app", pid: 5)
        let r = DriveLoop.resolveFastLane(goal: "quit", apps: [devin],
                                          appHint: "Devin", frontmostBundle: nil)
        guard case .appControl(.quit)? = r?.action?.body else {
            return XCTFail("expected quit, got \(String(describing: r?.action?.body))")
        }
        XCTAssertEqual(r?.bundle, "com.devin.app")
    }

    /// The same merge completes open verbs: "focus" + app:"Devin" opens it.
    func testAppHintMergeResolvesOpenVerb() {
        let devin = appRow("Devin", "com.devin.app", pid: 5)
        let r = DriveLoop.resolveFastLane(goal: "focus", apps: [devin],
                                          appHint: "Devin", frontmostBundle: nil)
        XCTAssertEqual(r?.openVerb, "focus")
        XCTAssertEqual(r?.bundle, "com.devin.app")
    }

    /// A spoken qualifier always wins — the hint never re-parses over a
    /// resolved lane.
    func testSpokenQualifierOutranksAppHint() {
        let notes = appRow("Notes", "com.apple.Notes", pid: 42)
        let devin = appRow("Devin", "com.devin.app", pid: 5)
        let r = DriveLoop.resolveFastLane(goal: "hide notes", apps: [notes, devin],
                                          appHint: "Devin", frontmostBundle: nil)
        guard case .appControl(.hide)? = r?.action?.body else {
            return XCTFail("expected hide, got \(String(describing: r?.action?.body))")
        }
        XCTAssertEqual(r?.bundle, "com.apple.Notes")
    }

    // MARK: - systemHotkey

    /// A desktop chord posts scope:"desktop" with the keys array and no
    /// pid — "lock screen" never binds a window.
    func testSystemHotkeyPostsDesktopScope() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "lock screen"), session: "t")
        XCTAssertEqual(result.status, .done)
        let hotkeys = driver.calls.filter { $0.tool == "hotkey" }
        XCTAssertEqual(hotkeys.count, 1)
        XCTAssertEqual(hotkeys[0].args["keys"]?.array?.compactMap(\.string),
                       ["ctrl", "cmd", "q"])
        XCTAssertEqual(hotkeys[0].args["scope"], .string("desktop"))
        XCTAssertNil(hotkeys[0].args["pid"], "a desktop chord needs no pid")
    }

    // MARK: - menu path

    /// "file menu save as" invokes the menu path on the bound window —
    /// segments pass through as the driver resolves them one at a time.
    func testMenuPostsInvokeMenuPath() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600)])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "file menu save as"), session: "t")
        XCTAssertEqual(result.status, .done)
        let menus = driver.calls.filter { $0.tool == "invoke_menu" }
        XCTAssertEqual(menus.count, 1)
        XCTAssertEqual(menus[0].args["path"]?.array?.compactMap(\.string),
                       ["file", "save as"])
        XCTAssertEqual(menus[0].args["pid"], .number(42))
        XCTAssertEqual(menus[0].args["window_id"], .number(7))
    }

    /// A failed-closed menu lookup asks which menu — never a guess.
    func testMenuRefusalAsksWhichMenu() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600)])]
        driver.thrown["invoke_menu"] = DriverConnectionError.toolRefused(
            tool: "invoke_menu", code: "menu_not_found", detail: "")
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "file menu save as"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("which menu"), reason)
    }

    // MARK: - window snap

    /// "snap left" writes the left half of the window's containing display
    /// and verifies the bounds actually moved.
    func testSnapLeftSetsWindowFrame() async {
        let old = DriveLoop.displayFrames
        defer { DriveLoop.displayFrames = old }
        DriveLoop.displayFrames = { [(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      scale: 2)] }
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        driver.responses["list_windows"] = [
            windows([windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                               x: 0, y: 0, w: 800, h: 600)]),
            windows([windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                               x: 0, y: 0, w: 800, h: 600)]),
            windows([windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                               x: 0, y: 0, w: 720, h: 900)]),
        ]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "snap left"), session: "t")
        XCTAssertEqual(result.status, .done)
        let frames = driver.calls.filter { $0.tool == "set_window_frame" }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].args["x"], .number(0))
        XCTAssertEqual(frames[0].args["y"], .number(0))
        XCTAssertEqual(frames[0].args["width"], .number(720))
        XCTAssertEqual(frames[0].args["height"], .number(900))
        XCTAssertEqual(frames[0].args["window_id"], .number(7))
    }

    // MARK: - locate

    /// An off-screen row activates its app and a verified return to screen
    /// is the honest "brought it back" — never a claim without the readback.
    func testLocateRestoresOffscreenWindow() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        driver.responses["list_windows"] = [
            windows([windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                               x: 0, y: 0, w: 800, h: 600, onScreen: false)]),
            windows([windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                               x: 0, y: 0, w: 800, h: 600, onScreen: true)]),
        ]
        var activated: [Int] = []
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             activateApp: { activated.append($0) })
        let result = await loop.run(DriveTask(goal: "where did my notes go"),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(activated, [42])
        XCTAssertTrue((result.history.last ?? "").contains("brought it back"),
                      result.history.last ?? "")
    }

    /// No matching row is an honest "I can't find it" — the refusal names
    /// the query and offers the capability surface, never a guess.
    func testLocateNoMatchBlocksHonestly() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600)])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "where did floober go"),
                                    session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("floober"), reason)
        XCTAssertTrue(reason.contains("what can I say"), reason)
    }

    /// Several distinct matching apps is a question, not a pick — the
    /// refusal names the candidates.
    func testLocateAmbiguousNamesCandidates() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600),
            windowRow(id: 8, pid: 9, app: "Noteshelf", title: "Noteshelf",
                      x: 900, y: 0, w: 800, h: 600)])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "where did my notes go"),
                                    session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("Notes"), reason)
        XCTAssertTrue(reason.contains("Noteshelf"), reason)
    }

    // MARK: - repeatLast

    /// "do that again" reaches the executor with no replay log — the
    /// coordinator owns real replays, so the floor is an honest refusal.
    func testRepeatLastBlocksHonestly() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "do that again"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("Nothing to repeat"), reason)
    }

    // MARK: - display scope

    /// "on this monitor" resolves the app owning the topmost window on the
    /// display under the gaze point — the ⌘M lands on the app whose row
    /// intersects the fake display containing (200,200), never the other
    /// display's app. `displayFrames` is the seam: NSScreen can't be
    /// stubbed, so the display lookup reads injected (frame, scale) pairs.
    func testDisplayScopeResolvesAppOnGazeDisplay() async {
        let old = DriveLoop.displayFrames
        defer { DriveLoop.displayFrames = old }
        DriveLoop.displayFrames = {
            [(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2),
             (frame: CGRect(x: 1440, y: 0, width: 1440, height: 900), scale: 2)]
        }
        let driver = FakeDriver()
        driver.responses["list_apps"] = [
            apps([appRow("Notes", "com.apple.Notes", pid: 42),
                  appRow("Safari", "com.apple.Safari", pid: 9)]),
            apps([appRow("Notes", "com.apple.Notes", pid: 42),
                  appRow("Safari", "com.apple.Safari", pid: 9)]),
        ]
        driver.responses["list_windows"] = [
            // The global read the display hit-test makes: Safari owns the
            // second display, Notes the one under the gaze point.
            windows([windowRow(id: 8, pid: 9, app: "Safari", title: "Safari",
                               x: 1500, y: 100, w: 800, h: 600, z: 0),
                     windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                               x: 100, y: 100, w: 800, h: 600, z: 1)]),
            // The bound app's inventory, then the post-dispatch readback.
            windows([windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                               x: 100, y: 100, w: 800, h: 600, z: 1)]),
            windows([windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                               x: 100, y: 100, w: 800, h: 600, z: 1,
                               onScreen: false)]),
        ]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(200, 200))
        let result = await loop.run(
            DriveTask(goal: "minimize the window on this monitor"), session: "t")
        XCTAssertEqual(result.status, .done)
        let hotkeys = driver.calls.filter { $0.tool == "hotkey" }
        XCTAssertEqual(hotkeys.count, 1)
        XCTAssertEqual(hotkeys[0].args["keys"]?.array?.compactMap(\.string),
                       ["cmd", "m"])
        XCTAssertEqual(hotkeys[0].args["pid"], .number(42),
                       "the app under the gaze display owns the chord — not Safari on the other display")
        XCTAssertEqual(result.pid, 42)
    }

    // MARK: - overlay

    /// Native AX targets already carry the overlay's global screen points.
    func testOverlayVerbDispatchesConvertedTargets() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Notes", "com.apple.Notes", pid: 42)])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 100, y: 100, w: 800, h: 600)])]
        driver.responses["get_window_state"] = [.object([
            "window_bounds": .object(["x": .number(100), "y": .number(100),
                                      "width": .number(800), "height": .number(600)]),
            "screenshot_scale": .number(2),
            "elements": .array([
                .object(["element_index": .number(1), "role": .string("button"),
                         "label": .string("Save"),
                         "frame": .object(["x": .number(400), "y": .number(300),
                                           "w": .number(60), "h": .number(30)]),
                         "actions": .array([.string("AXPress")])]),
            ])])]
        var gotVerb: FastAction.OverlayVerb?
        var gotTargets: [(frame: CGRect, label: String)] = []
        var gotPoint: CGPoint?
        let loop = DriveLoop(
            call: { t, a in try driver.call(t, a) },
            choose: { _, _ in nil }, ask: nil, granted: { true },
            gaze: gaze(200, 200),
            overlayDispatch: { verb, targets, point in
                gotVerb = verb; gotTargets = targets; gotPoint = point
                return DriveResult(status: .done, history: ["numbered"],
                                   dispatchedEffect: true)
            })
        let result = await loop.run(DriveTask(goal: "show names"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(gotVerb, .showNames)
        XCTAssertEqual(gotTargets.count, 1)
        // Screenshot metadata must not move or halve native AX rectangles.
        XCTAssertEqual(gotTargets[0].frame, CGRect(x: 400, y: 300, width: 60, height: 30))
        XCTAssertEqual(gotTargets[0].label, "Save")
        XCTAssertEqual(gotPoint, CGPoint(x: 200, y: 200))
    }

    /// A nil overlay seam refuses — "nothing was numbered" is honest when
    /// no app-side overlay exists to draw the chips.
    func testOverlayWithoutSeamBlocksHonestly() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(200, 200))
        let result = await loop.run(DriveTask(goal: "show names"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("can't put names on the screen"), reason)
    }

    /// An unlabeled field still has something to say — its value. The
    /// spoken line names the role as words ("a text field", not the AX
    /// constant) and reads the value back.
    func testDescribeSpeaksElementValue() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Mail", title: "Inbox",
                      x: 100, y: 100, w: 800, h: 600)])]
        driver.responses["get_window_state"] = [.object([
            "window_bounds": .object(["x": .number(100), "y": .number(100),
                                      "width": .number(800), "height": .number(600)]),
            "screenshot_scale": .number(2),
            "elements": .array([
                .object(["element_index": .number(1), "role": .string("AXTextField"),
                         "value": .string("Your order ships Friday"),
                         "frame": .object(["x": .number(100), "y": .number(100),
                                           "w": .number(600), "h": .number(200)]),
                         "actions": .array([.string("AXSetValue")])]),
            ])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(200, 200)) // window-local (100,100)pt → (200,200)px, inside the field
        let result = await loop.run(DriveTask(goal: "what is this"), session: "t")
        XCTAssertEqual(result.status, .done)
        let say = result.history.last ?? ""
        XCTAssertTrue(say.contains("text field"), say)
        XCTAssertTrue(say.contains("Your order ships Friday"), say)
        XCTAssertTrue(say.contains("Mail"), say)
    }

    func testDescribeNativeScreenFrameWithoutScreenshotMetadata() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Fixture", title: "Owned",
                      x: 634, y: 160, w: 656, h: 422)])]
        driver.responses["get_window_state"] = [.object(["elements": .array([
            .object(["element_index": .number(1), "role": .string("AXTextField"),
                     "value": .string("Coordinate fixture"),
                     "frame": .object(["x": .number(634), "y": .number(192),
                                       "w": .number(656), "h": .number(384)])])
        ])])]
        let loop = DriveLoop(call: { try driver.call($0, $1) }, choose: { _, _ in nil },
                             ask: nil, granted: { true }, gaze: gaze(700, 220))
        let result = await loop.run(DriveTask(goal: "what is this"), session: "native-frame")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue((result.history.last ?? "").contains("Coordinate fixture"))
    }

    // MARK: - gaze remedy naming

    /// A dead gaze seam on a paused tracker names the fix — "resume
    /// tracking" — instead of a bare "the tracker didn't answer".
    func testGazeRefusalNamesResumeWhenPaused() async {
        let old = TrackerControl.transport
        defer { TrackerControl.transport = old }
        TrackerControl.transport = { _ in
            let body = Data(#"{"paused":true,"calibration_status":"loaded","preview":{"head_detected":true}}"#.utf8)
            return (body, HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                          statusCode: 200, httpVersion: nil,
                                          headerFields: nil)!)
        }
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { throw GazeError.unreachable })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("resume tracking"), reason)
    }

    // MARK: - deny corpus on the fast lane

    /// The bound window's own words ride the deny scan: "file menu save
    /// as" is a benign path, but on a window titled "Wire Transfer"
    /// the corpus refuses — grant or not.
    func testMenuOnDeniedWindowTitleRefuses() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Store", "com.example.store", pid: 42)])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Store", title: "Wire Transfer",
                      x: 0, y: 0, w: 800, h: 600)])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             frontmostBundleID: { "com.example.store" })
        let result = await loop.run(DriveTask(goal: "file menu save as"), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "invoke_menu" })
    }

    /// The field's identity is the deny corpus — typing into a field
    /// labelled "Gift card number" refuses even though the payload is
    /// never scanned.
    func testTypeIntoDeniedFieldRefuses() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Store", "com.example.store", pid: 42)])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Store", title: "Redeem",
                      x: 0, y: 0, w: 800, h: 600)])]
        driver.responses["get_window_state"] = [.object([
            "elements": .array([
                .object(["element_index": .number(1),
                         "role": .string("AXTextField"),
                         "label": .string("Gift card number"),
                         "enabled": .bool(true),
                         "element_token": .string("tok-1"),
                         "frame": .object(["x": .number(100), "y": .number(100),
                                           "w": .number(600), "h": .number(40)]),
                         "actions": .array([.string("AXSetValue")])]),
            ])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             frontmostBundleID: { "com.example.store" })
        let result = await loop.run(DriveTask(goal: "type hello"), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "type_text" })
    }

    /// "close this" on a window whose own title is protected refuses —
    /// the deictic gate scans the gazed window's words, grant or not.
    func testDeicticCloseOnDeniedWindowRefuses() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Store", "com.example.store", pid: 42)])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Store", title: "Wire Transfer",
                      x: 0, y: 0, w: 800, h: 600)])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(200, 200),
                             frontmostBundleID: { "com.example.store" })
        let result = await loop.run(DriveTask(goal: "close this"), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains {
            ["hotkey", "click", "invoke_menu", "set_window_frame"].contains($0.tool) })
    }

    /// The deny scan reads the window under the point even on the raw
    /// gaze fallback — a click at "Wire Transfer" refuses before any
    /// pixel dispatch.
    func testGazeClickOnDeniedWindowRefuses() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([])]
        driver.responses["list_windows"] = [windows([
            windowRow(id: 7, pid: 42, app: "Store", title: "Wire Transfer",
                      x: 0, y: 0, w: 800, h: 600)])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(200, 200))
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
    }

    /// The launch path lifts the goal's domain token for a browser
    /// target — "open example.com in Safari" puts the address
    /// mid-sentence, and a file-shaped tail must never become a URL.
    func testFirstDomainURL() {
        XCTAssertEqual(ActionCatalog.firstDomainURL(in: "Open example.com in Safari"),
                       "https://example.com")
        XCTAssertEqual(ActionCatalog.firstDomainURL(in: "go to https://a.b/c now"),
                       "https://a.b/c")
        XCTAssertNil(ActionCatalog.firstDomainURL(in: "open report.pdf in Preview"))
        XCTAssertNil(ActionCatalog.firstDomainURL(in: "open Calculator"))
    }

    // MARK: - named targets (voice-only)

    private func namedFixture(_ labels: [(String, Double)]) -> FakeDriver {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [apps([appRow("Mail", "com.apple.mail", pid: 42)])]
        driver.responses["list_windows"] = Array(repeating: windows([
            windowRow(id: 7, pid: 42, app: "Mail", title: "New Message",
                      x: 0, y: 0, w: 900, h: 700)]), count: 3)
        let elements: [JSONValue] = labels.enumerated().map { index, item in
            .object(["element_index": .number(Double(index + 1)), "role": .string("button"),
                     "label": .string(item.0), "element_token": .string("tok\(index + 1)"),
                     "frame": .object(["x": .number(item.1), "y": .number(40),
                                       "w": .number(60), "h": .number(30)]),
                     "actions": .array([.string("AXPress")])])
        }
        driver.responses["get_window_state"] = Array(repeating: .object([
            "window_bounds": .object(["x": .number(0), "y": .number(0),
                                      "width": .number(900), "height": .number(700)]),
            "elements": .array(elements)]), count: 3)
        return driver
    }

    /// "click Save" with one Save on screen presses it — no gaze, no
    /// numbers.
    func testClickNameWithOneMatchClicksIt() async {
        let saved = DriveLoop.gazeEnabled
        DriveLoop.gazeEnabled = { false }
        defer { DriveLoop.gazeEnabled = saved }
        let driver = namedFixture([("Save", 100), ("Cancel", 200)])
        var overlayCalls = 0
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             overlayDispatch: { _, _, _ in overlayCalls += 1; return nil },
                             frontmostBundleID: { "com.apple.mail" })
        let result = await loop.run(DriveTask(goal: "click save"), session: "t")
        XCTAssertEqual(result.status, .done)
        let clicks = driver.calls.filter { $0.tool == "click" }
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks.first?.args["element_token"], .string("tok1"))
        XCTAssertEqual(clicks.first?.args["pid"], .number(42))
        XCTAssertEqual(overlayCalls, 0)
    }

    /// Two matches: nothing is clicked, numbers go up over just those two,
    /// and Jarvis asks which.
    func testClickNameWithTwoMatchesNumbersThemAndAsks() async {
        let saved = DriveLoop.gazeEnabled
        DriveLoop.gazeEnabled = { false }
        defer { DriveLoop.gazeEnabled = saved }
        let driver = namedFixture([("Save", 100), ("Save", 400), ("Cancel", 200)])
        var gotVerb: FastAction.OverlayVerb?
        var gotTargets: [(frame: CGRect, label: String)] = []
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             overlayDispatch: { verb, targets, _ in
                                 gotVerb = verb; gotTargets = targets
                                 return DriveResult(status: .done, history: [], dispatchedEffect: true)
                             },
                             frontmostBundleID: { "com.apple.mail" })
        let result = await loop.run(DriveTask(goal: "click save"), session: "t")
        XCTAssertTrue(driver.calls.filter { $0.tool == "click" }.isEmpty)
        XCTAssertEqual(gotVerb, .showNumbers)
        XCTAssertEqual(gotTargets.map(\.label), ["Save", "Save"])
        guard case .blocked(let question) = result.status else {
            return XCTFail("expected a question, got \(result.status)")
        }
        XCTAssertEqual(question, "I can see two things called Save. One or two?")
    }

    /// "show me Save" highlights the one match and never clicks.
    func testShowMeNameHighlights() async {
        let saved = DriveLoop.gazeEnabled
        DriveLoop.gazeEnabled = { false }
        defer { DriveLoop.gazeEnabled = saved }
        let driver = namedFixture([("Save", 100)])
        var gotVerb: FastAction.OverlayVerb?
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             overlayDispatch: { verb, _, _ in
                                 gotVerb = verb
                                 return DriveResult(status: .done, history: [], dispatchedEffect: true)
                             },
                             frontmostBundleID: { "com.apple.mail" })
        let result = await loop.run(DriveTask(goal: "show me save"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(gotVerb, .highlight)
        XCTAssertTrue(driver.calls.filter { $0.tool == "click" }.isEmpty)
    }

    /// With eye tracking off, "click this" says what to say instead and
    /// never reads the tracker.
    func testGazeClickWithEyesOffSuggestsSayingTheName() async {
        let saved = DriveLoop.gazeEnabled
        DriveLoop.gazeEnabled = { false }
        defer { DriveLoop.gazeEnabled = saved }
        let driver = FakeDriver()
        var gazeReads = 0
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { gazeReads += 1
                                     return GazeSample(x: 1, y: 1, confidence: 0.9, state: "dwell", updatedAt: Date()) })
        let result = await loop.run(DriveTask(goal: "click this"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(reason, DriveLoop.eyesOffReply(.click))
        XCTAssertTrue(reason.contains("click Save"))
        XCTAssertEqual(gazeReads, 0)
        XCTAssertTrue(driver.calls.filter { $0.tool == "click" }.isEmpty)
    }

    /// "type X here" with eye tracking off types at the insertion point
    /// of the bound window instead of refusing for want of a gaze point.
    func testTypeHereWithEyesOffUsesTheCursor() async {
        let saved = DriveLoop.gazeEnabled
        DriveLoop.gazeEnabled = { false }
        defer { DriveLoop.gazeEnabled = saved }
        let driver = FakeDriver(), payload = "Jev audit alpha"
        let loop = boundTypeLoop(driver)
        var task = DriveTask(goal: "type \(payload) here", application: "fixture.bound", pid: 42, windowID: 7)
        task.values["text"] = payload
        let result = await loop.run(task, session: "type-here")
        XCTAssertEqual(result.status, .done)
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" }, "no click at a gaze point")
        let typed = driver.calls.filter { $0.tool == "type_text" }
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(typed.first?.args["text"], .string(payload))
    }
}
