import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: gaze-referent verbs resolve app-free, dispatch at the live
/// tracker point, and refuse honestly when the tracker can't say where the
/// user is looking.
final class GazeLaneTests: XCTestCase {
    private var priorTracker: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?

    override func setUp() {
        super.setUp()
        priorTracker = TrackerControl.transport
        TrackerControl.transport = { _ in throw URLError(.notConnectedToInternet) }
    }

    override func tearDown() {
        if let priorTracker { TrackerControl.transport = priorTracker }
        super.tearDown()
    }

    // MARK: - Parse + resolve

    /// Referent phrases parse to gaze verbs — never an app guess.
    func testGazeVerbsParse() {
        for phrase in ["click", "click this", "tap it", "open this"] {
            guard let parsed = FastAction.parse(phrase),
                  case .gaze(let verb) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to a gaze verb")
                continue
            }
            XCTAssertEqual(verb, .click, "'\(phrase)' is a gaze click")
        }
        for (phrase, want) in [("right click", FastAction.GazeVerb.rightClick),
                               ("right-click this", .rightClick),
                               ("double click", .doubleClick),
                               ("what is this", .describe),
                               ("what am i looking at", .describe)] {
            guard let parsed = FastAction.parse(phrase),
                  case .gaze(let verb) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to a gaze verb")
                continue
            }
            XCTAssertEqual(verb, want)
        }
    }

    /// "open this" is claimed by the gaze lane — the open-verb fallback
    /// must not hand "this" to an app-name lookup.
    func testOpenThisResolvesAsGazeNotApp() {
        let notes = appRow("Notes", "com.apple.Notes", pid: 42)
        let resolved = DriveLoop.resolveFastLane(goal: "open this", apps: [notes],
                                                 frontmostBundle: "com.apple.Notes")
        XCTAssertNotNil(resolved)
        XCTAssertNil(resolved?.openVerb)
        XCTAssertEqual(resolved?.bundle, "")
        if case .gaze(let verb) = resolved?.action?.body {
            XCTAssertEqual(verb, .click)
        } else { XCTFail("expected gaze, got \(String(describing: resolved?.action?.body))") }
    }

    /// A mid-sentence "click" is not a gaze referent — the loop owns it.
    func testClickWithObjectStaysInTheLoop() {
        let notes = appRow("Notes", "com.apple.Notes", pid: 42)
        let resolved = DriveLoop.resolveFastLane(goal: "click the save button",
                                                 apps: [notes],
                                                 frontmostBundle: "com.apple.Notes")
        XCTAssertNil(resolved, "'click the save button' is element work, not a gaze verb")
    }

    // MARK: - Dispatch

    private final class FakeDriver {
        var calls: [(tool: String, args: [String: JSONValue])] = []
        var responses: [String: [JSONValue]] = [:]
        func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
            calls.append((tool, args))
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

    private func windowRow(id: Int, pid: Int, app: String, title: String,
                           x: Double, y: Double, w: Double, h: Double,
                           z: Int = 1, onScreen: Bool = true) -> JSONValue {
        .object(["window_id": .number(Double(id)), "pid": .number(Double(pid)),
                 "app_name": .string(app), "title": .string(title),
                 "bounds": .object(["x": .number(x), "y": .number(y),
                                    "width": .number(w), "height": .number(h)]),
                 "z_index": .number(Double(z)), "is_on_screen": .bool(onScreen)])
    }

    private func gaze(_ x: Double, _ y: Double) -> () async throws -> GazeSample {
        { GazeSample(x: x, y: y, confidence: 0.9, state: "dwell",
                     updatedAt: Date()) }
    }


    private func button(at p: CGPoint) -> IntentCandidate {
        let r = CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)
        return IntentCandidate(id: "ax:42:7:fixture", kind: .axElement, frame: r, motorRect: r,
                               role: "AXButton", label: "Save", pid: 42, windowID: 7)
    }

    @MainActor
    func testGenericVoiceLoopCannotTurnARewrittenPayloadIntoAGazeClick() async throws {
        let loop = DriveLoop(call: { tool, _ in XCTFail(tool); return .null },
            choose: { _, _ in XCTFail("Unexpected chooser"); return nil }, ask: nil, granted: { true },
            directSession: "voice-direct",
            gaze: { XCTFail("Unexpected gaze read"); throw CancellationError() },
            gazeCommit: { XCTFail("Unexpected target selection"); return nil },
            gazeClick: { _, _ in XCTFail("Unexpected actuation"); return true })
        for phrase in ["click", "right click", "double click"] {
            let resolved = try XCTUnwrap(DriveLoop.resolveFastLane(goal: phrase, apps: [], frontmostBundle: nil))
            var history: [String] = [], confirmed = true
            let result = try await loop.runFastLane(resolved, task: DriveTask(goal: "fixture payload"),
                session: "fixture", history: &history, confirmed: &confirmed)
            guard case .blocked? = result?.status else { return XCTFail(phrase) }
            XCTAssertFalse(result?.dispatchedEffect ?? true, phrase)
        }
    }

    @MainActor
    func testClickDispatchesOnlyTheVerifiedElementAtTheGazePoint() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let point = CGPoint(x: 500, y: 400)
        let button = button(at: point)
        var presses = 0
        let loop = DriveLoop(call: { try driver.call($0, $1) }, choose: { _, _ in nil }, ask: nil, granted: { true },
            gaze: gaze(500, 400), gazeCommit: { (button, 1) }, gazeClick: { c, verb in
                await VoiceTaskCoordinator.dispatchCommitted(verb: verb, current: { c == button }, press: { presses += 1; return true })
            })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(presses, 1)
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
    }

    @MainActor
    func testMissingCommitOrRevocationBeforeSendCannotFallBackToRawPoint() async {
        let driver = FakeDriver(), point = CGPoint(x: 500, y: 400)
        let candidate = button(at: point)
        for hasBinding in [false, true] {
            var validations = 0
            let loop = DriveLoop(call: { try driver.call($0, $1) }, choose: { _, _ in nil }, ask: nil,
                granted: { true }, gaze: gaze(500, 400), gazeCommit: { hasBinding ? (candidate, 1) : nil },
                gazeClick: { _, verb in
                    await VoiceTaskCoordinator.dispatchCommitted(verb: verb, current: {
                        validations += 1; return false
                    }, press: { XCTFail("Revoked gaze press"); return false })
                })
            let result = await loop.run(DriveTask(goal: "click"), session: "t")
            guard case .blocked = result.status else { return XCTFail("Expected refused click") }
            XCTAssertEqual(validations, hasBinding ? 1 : 0)
        }
        XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
    }

    /// No tracker → an honest refusal naming the missing piece; no click
    /// is ever dispatched to a guessed point.
    func testClickTrackerDownBlocksHonestly() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { throw GazeError.unreachable })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("tracker"), reason)
        XCTAssertTrue(driver.calls.filter { $0.tool == "click" }.isEmpty)
    }

    /// A stale or distrusted sample refuses — never a click on where the
    /// user was a while ago.
    func testStaleGazeRefuses() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let stale = { () async throws -> GazeSample in
            GazeSample(x: 1, y: 1, confidence: 0.9, state: "dwell",
                       updatedAt: Date().addingTimeInterval(-30))
        }
        // The loop re-checks freshness — the seam contract is "freshest",
        // and a click on where the user was is worse than no click.
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { try await stale() })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blocked = result.status else {
            return XCTFail("a 30s-old sample must not click — got \(result.status)")
        }
        XCTAssertTrue(driver.calls.filter { $0.tool == "click" }.isEmpty)
    }

    /// A committed referent's own words ride the deny scan: "Buy now" is
    /// protected vocabulary, so the gaze click refuses before ANY
    /// actuation form — element-token, traffic-light, or pixel.
    func testGazeClickOnDeniedCandidateRefuses() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let rect = CGRect(x: 190, y: 190, width: 120, height: 30)
        let candidate = IntentCandidate(id: "ax:42:tok", kind: .axElement,
                                        frame: rect, motorRect: rect,
                                        role: "AXButton", label: "Buy now",
                                        pid: 42, windowID: 7,
                                        appName: "Store",
                                        windowTitle: "Checkout")
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(200, 200),
                             gazeCommit: { (candidate, 0.9) })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blockedByConsent = result.status else {
            return XCTFail("expected blockedByConsent, got \(result.status)")
        }
        XCTAssertTrue(driver.calls.filter { $0.tool == "click" }.isEmpty)
    }

    @MainActor
    func testRightAndDoubleClickCannotFallBackToGlobalPointerEvents() async {
        let old = GazePointer.poster
        defer { GazePointer.poster = old }
        GazePointer.poster = { _, _ in XCTFail("Ungrounded pointer event"); return false }
        let target = button(at: CGPoint(x: 200, y: 100))
        for goal in ["right click", "double click"] {
            let driver = FakeDriver()
            let loop = DriveLoop(call: { try driver.call($0, $1) }, choose: { _, _ in nil }, ask: nil,
                granted: { true }, gaze: gaze(200, 100), gazeCommit: { (target, 1) },
                gazeClick: { _, verb in await VoiceTaskCoordinator.dispatchCommitted(verb: verb, current: { true },
                    press: { XCTFail("Wrong gesture"); return false }) })
            let result = await loop.run(DriveTask(goal: goal), session: "t")
            guard case .blocked = result.status else { return XCTFail(goal) }
            XCTAssertFalse(driver.calls.contains { $0.tool == "click" })
        }
    }

    func testScrollDownRequiresFreshWindowAndRegionBindingAtGazePoint() async {
        for hasFreshWindow in [false, true] {
            let driver = FakeDriver()
            driver.responses["list_apps"] = [
                .object(["apps": .array([appRow("Notes", "com.apple.Notes", pid: 42)])])]
            let windows: JSONValue = .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600)])])
            driver.responses["list_windows"] = hasFreshWindow ? [windows, windows] : [windows]
            let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                                 choose: { _, _ in nil }, ask: nil, granted: { true },
                                 gaze: gaze(300, 250),
                                 frontmostBundleID: { "com.apple.Notes" })
            let result = await loop.run(DriveTask(goal: "scroll down"), session: "t")
            guard case .blocked = result.status else { return XCTFail("Unbound gaze must not scroll") }
            let scrolls = driver.calls.filter { $0.tool == "scroll" }
            XCTAssertTrue(scrolls.isEmpty)
        }
    }

    func testScrollTrackerOffStillRequiresAnObservedViewport() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [
            .object(["apps": .array([appRow("Notes", "com.apple.Notes", pid: 42)])])]
        driver.responses["list_windows"] = [.object(["windows": .array([
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600)])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "scroll down"), session: "t")
        XCTAssertEqual(result.blockedReason, DriveLoop.scrollUnverifiedReason)
        XCTAssertFalse(driver.calls.contains { ["scroll", "hotkey", "press_key"].contains($0.tool) })
    }

    func testDeicticTypeRefusesEvenWithFreshGaze() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [
            .object(["apps": .array([appRow("Notes", "com.apple.Notes", pid: 42)])])]
        // Two window listings: the bound app's inventory before dispatch,
        // then the all-windows read the gaze hit-test makes.
        driver.responses["list_windows"] = [
            .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600)])]),
            .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600)])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(300, 250),
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "type hello there here"),
                                    session: "t")
        guard case .blocked = result.status else { return XCTFail("Expected refusal") }
        XCTAssertFalse(result.dispatchedEffect)
        XCTAssertTrue(driver.calls.isEmpty)
    }

    /// "what is this" reads the deepest element under the gaze point —
    /// app, window title, and the element's role+label when the tree
    /// exposes them.
    func testDescribeReadsElementUnderGaze() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        driver.responses["list_windows"] = [.object(["windows": .array([
            windowRow(id: 7, pid: 42, app: "Safari", title: "Example",
                      x: 100, y: 100, w: 800, h: 600)])])]
        driver.responses["get_window_state"] = [.object([
            "window_bounds": .object(["x": .number(100), "y": .number(100),
                                      "width": .number(800), "height": .number(600)]),
            "screenshot_scale": .number(2),
            "app_name": .string("Safari"), "window_title": .string("Example"),
            "elements": .array([
                .object(["element_index": .number(0), "role": .string("window"),
                         "frame": .object(["x": .number(100), "y": .number(100),
                                           "w": .number(800), "h": .number(600)])]),
                .object(["element_index": .number(1), "role": .string("button"),
                         "label": .string("Save"),
                         "frame": .object(["x": .number(380), "y": .number(330),
                                           "w": .number(60), "h": .number(30)])]),
            ])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(400, 340)) // native screen points, inside the same physical button
        let result = await loop.run(DriveTask(goal: "what is this"), session: "t")
        XCTAssertEqual(result.status, .done)
        let say = result.history.last ?? ""
        XCTAssertTrue(say.contains("button") && say.contains("Save"), say)
        XCTAssertTrue(say.contains("Safari"), say)
    }

    /// Gaze over bare desktop describes honestly — no window, no invented
    /// element.
    func testDescribeDesktopIsHonest() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        driver.responses["list_windows"] = [.object(["windows": .array([
            windowRow(id: 7, pid: 42, app: "Safari", title: "Example",
                      x: 100, y: 100, w: 100, h: 100)])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(900, 900))
        let result = await loop.run(DriveTask(goal: "what is this"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue((result.history.last ?? "").contains("desktop"))
    }

    // MARK: - Window hit-test (z order + self exclusion)

    /// The driver's z contract is higher `z_index` = closer to the front
    /// (CGWindowList front-to-back reversed). Two windows overlapping the
    /// gaze point must resolve to the one the user can actually see — the
    /// frontmost — not the row buried under it.
    func testHitTestPicksFrontmostRow() {
        let rows = [
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600, z: 3),
            windowRow(id: 8, pid: 9, app: "Safari", title: "Safari",
                      x: 100, y: 100, w: 800, h: 600, z: 9),
        ]
        let hit = DriveLoop.topmostWindowRow(at: CGPoint(x: 400, y: 400), in: rows)
        XCTAssertEqual(hit?["window_id"]?.integer, 8,
                       "z 9 is in front of z 3 — the visible window wins")
        XCTAssertEqual(hit?["pid"]?.integer, 9)
    }

    /// The same hit with the order reversed in the payload — enumeration
    /// order must never outrank z order.
    func testHitTestZOrderNotListOrder() {
        let rows = [
            windowRow(id: 8, pid: 9, app: "Safari", title: "Safari",
                      x: 100, y: 100, w: 800, h: 600, z: 9),
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600, z: 3),
        ]
        let hit = DriveLoop.topmostWindowRow(at: CGPoint(x: 400, y: 400), in: rows)
        XCTAssertEqual(hit?["window_id"]?.integer, 8)
    }

    /// A Jev Voice window (overlay panel, settings card, a chip if it
    /// ever surfaces as layer 0) must never resolve as a gaze target —
    /// "this" while looking at our own chrome means the window under it.
    func testHitTestExcludesOwnPID() {
        let own = DriveLoop.ownPID
        let rows = [
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600, z: 3),
            windowRow(id: 99, pid: own, app: "Jev Voice", title: "Settings",
                      x: 100, y: 100, w: 800, h: 600, z: 20),
        ]
        let hit = DriveLoop.topmostWindowRow(at: CGPoint(x: 400, y: 400),
                                             in: rows, excludingPID: own)
        XCTAssertEqual(hit?["window_id"]?.integer, 7,
                       "our own window can never claim the gaze point")
    }

    /// Nothing but our own windows under the point is an honest miss —
    /// not a self-target.
    func testHitTestAllOwnWindowsMisses() {
        let own = DriveLoop.ownPID
        let rows = [windowRow(id: 99, pid: own, app: "Jev Voice", title: "Panel",
                              x: 0, y: 0, w: 1440, h: 900, z: 20)]
        XCTAssertNil(DriveLoop.topmostWindowRow(at: CGPoint(x: 400, y: 400),
                                                in: rows, excludingPID: own))
    }

    /// A null `z_index` means the driver couldn't order the row — it
    /// trails every ordered one rather than claiming the front on a
    /// technicality.
    func testHitTestNullZIndexTrailsOrdered() {
        let unordered = JSONValue.object([
            "window_id": .number(9), "pid": .number(7),
            "app_name": .string("Dock"), "title": .string(""),
            "bounds": .object(["x": .number(0), "y": .number(0),
                               "width": .number(1440), "height": .number(900)]),
            "is_on_screen": .bool(true)]) // no z_index at all
        let rows = [
            unordered,
            windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                      x: 0, y: 0, w: 800, h: 600, z: 1),
        ]
        let hit = DriveLoop.topmostWindowRow(at: CGPoint(x: 400, y: 400), in: rows)
        XCTAssertEqual(hit?["window_id"]?.integer, 7,
                       "a z-less row can't outrank the ordered frontmost")
        // Alone under the point, though, it is still a real window.
        let solo = DriveLoop.topmostWindowRow(at: CGPoint(x: 1400, y: 850),
                                              in: rows)
        XCTAssertEqual(solo?["window_id"]?.integer, 9)
    }

    /// `x_px`/`y_px` are screen *points*, not physical pixels: the
    /// hit-test compares them to `bounds` verbatim — on a Retina display
    /// a 700,500 gaze point inside a 0,0,800,600 window is a hit, and
    /// the doubled-pixel point 1400,1000 is not the same lookup. Any
    /// unconditional ×2 here would land every hit on the wrong window.
    func testHitTestUsesPointSpaceVerbatim() {
        let rows = [windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                              x: 0, y: 0, w: 800, h: 600)]
        XCTAssertNotNil(DriveLoop.topmostWindowRow(at: CGPoint(x: 700, y: 500),
                                                   in: rows))
        XCTAssertNil(DriveLoop.topmostWindowRow(at: CGPoint(x: 1400, y: 1000),
                                                in: rows),
                     "physical-pixel values would only hit on a 2x misread")
    }

    func testDeicticTypeCannotRetargetTheWindowUnderGaze() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [
            .object(["apps": .array([appRow("Notes", "com.apple.Notes", pid: 42)])])]
        driver.responses["list_windows"] = [
            .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600)])]),
            // The all-windows read the gaze hit-test makes: Notes (z 3)
            // sits under Safari (z 9) at the gaze point.
            .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600, z: 3),
                windowRow(id: 8, pid: 9, app: "Safari", title: "Safari",
                          x: 100, y: 100, w: 800, h: 600, z: 9)])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(400, 400),
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "type hello there here"),
                                    session: "t")
        guard case .blocked = result.status else { return XCTFail("Expected refusal") }
        XCTAssertTrue(driver.calls.isEmpty)
        XCTAssertFalse(result.dispatchedEffect)
    }

    // MARK: - Client decode gates

    /// The client refuses stale and unsure samples before the loop sees
    /// them — `updated_at` freshness and tracker confidence are the gates.
    func testClientGatesFreshnessAndConfidence() throws {
        let now = ISO8601DateFormatter()
        now.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func payload(_ age: TimeInterval, _ confidence: Double) throws -> Data {
            let stamp = now.string(from: Date().addingTimeInterval(-age))
            return Data(#"{"x_px":500,"y_px":400,"confidence":\#(confidence),"gaze_state":"dwell","updated_at":"\#(stamp)"}"#.utf8)
        }
        XCTAssertNoThrow(try GazeClient.decode(try payload(0.2, 0.9)))
        XCTAssertThrowsError(try GazeClient.decode(try payload(9, 0.9))) {
            XCTAssertEqual($0 as? GazeError, .stale)
        }
        XCTAssertThrowsError(try GazeClient.decode(try payload(0.2, 0.1))) {
            XCTAssertEqual($0 as? GazeError, .lowConfidence)
        }
        XCTAssertThrowsError(try GazeClient.decode(Data("{}".utf8))) {
            XCTAssertEqual($0 as? GazeError, .malformed)
        }
    }
}
