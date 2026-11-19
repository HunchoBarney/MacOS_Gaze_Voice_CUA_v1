import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: the feed's candidate ladder — windows as the floor, AX
/// native AX elements already in global top-left points,
/// traffic lights and menu items as their own kinds, OCR only when
/// nothing actionable answered — and every committed candidate maps to
/// a real actuation (element token / traffic-light press / pixel).
@MainActor
final class GazeCandidateFeedTests: XCTestCase {

    /// Lock-boxed counter — the @Sendable seams can't mutate a captured
    /// var; test spies serialize through the lock instead.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _n }
        func bump() { lock.lock(); _n += 1; lock.unlock() }
    }

    nonisolated private static func row(
        _ id: Int, pid: pid_t = 42,
        app: String = "Test App", title: String = "Doc",
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
        layer: Int = 0
    ) -> GazeCandidateFeed.WindowRow {
        .init(id: id, pid: pid, layer: layer, app: app, title: title, bounds: frame)
    }

    nonisolated private static func snap(
        bounds: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
        scale: Double = 2,
        elements: [JSONValue]
    ) -> JSONValue {
        .object([
            "structuredContent": .object([
                "window_bounds": .object([
                    "x": .number(bounds.minX), "y": .number(bounds.minY),
                    "width": .number(bounds.width), "height": .number(bounds.height)]),
                "screenshot_scale": .number(scale),
                "elements": .array(elements)])
        ])
    }

    nonisolated private static func element(
        _ index: Int, token: String? = nil,
        role: String = "AXButton", label: String = "Save",
        frame: CGRect = .init(x: 200, y: 140, width: 60, height: 20)
    ) -> JSONValue {
        var e: [String: JSONValue] = [
            "element_index": .number(Double(index)),
            "role": .string(role), "label": .string(label),
            "frame": .object(["x": .number(frame.minX), "y": .number(frame.minY),
                              "w": .number(frame.width), "h": .number(frame.height)])]
        if let token { e["element_token"] = .string(token) }
        return .object(e)
    }

    /// The seam wiring every test shares — a feed with all external
    /// sources stubbed to empty/safe defaults.
    nonisolated private static func feed(
        rows: @escaping @Sendable () -> [GazeCandidateFeed.WindowRow]
    ) -> GazeCandidateFeed {
        var feed = GazeCandidateFeed()
        feed.windowRows = rows
        feed.elementSnapshot = { _, _ in .object([:]) }
        feed.trafficLights = { _, _ in [] }
        feed.menuBarItems = { [] }
        feed.inMenuBand = { _ in false }
        feed.ocrRegions = { _ in [] }
        feed.bundleID = { _ in nil }
        feed.axTrusted = { true }
        return feed
    }

    // MARK: element conversion

    /// Native AX points must not be translated or scaled a second time.
    /// The candidate carries pid/window/token so actuation can verify.
    nonisolated func testElementCandidatesConvertGeometry() {
        let out = GazeCandidateFeed.elementCandidates(
            Self.snap(elements: [Self.element(3, token: "axel_9")]),
            row: Self.row(7, pid: 42))
        XCTAssertEqual(out.count, 1)
        let c = out[0]
        XCTAssertEqual(c.id, "ax:42:7:axel_9")
        XCTAssertEqual(c.kind, .axElement)
        XCTAssertEqual(c.frame, CGRect(x: 200, y: 140, width: 60, height: 20))
        XCTAssertEqual(c.pid, 42); XCTAssertEqual(c.windowID, 7)
        XCTAssertEqual(c.appName, "Test App")
    }

    nonisolated func testObservedNativeFrameIgnoresScreenshotGeometry() {
        let observed = CGRect(x: 634, y: 192, width: 656, height: 384)
        let out = GazeCandidateFeed.elementCandidates(
            Self.snap(bounds: CGRect(x: 634, y: 160, width: 656, height: 422),
                      scale: 2, elements: [Self.element(1, role: "AXTextArea", frame: observed)]),
            row: Self.row(7))
        XCTAssertEqual(out.first?.frame, observed)
    }

    nonisolated func testNativeFrameDoesNotRequireScreenshotMetadata() {
        let observed = CGRect(x: -1500, y: 200, width: 100, height: 30)
        let snapshot = JSONValue.object(["elements": .array([Self.element(1, frame: observed)])])
        let out = GazeCandidateFeed.elementCandidates(snapshot, row: Self.row(7))
        XCTAssertEqual(out.first?.frame, observed)
    }

    nonisolated func testInvalidNativeFramesDoNotBecomeCandidates() {
        let elements = [
            Self.element(1, frame: CGRect(x: 10, y: 10, width: 0, height: 20)),
            Self.element(2, frame: CGRect(x: Double.infinity, y: 10, width: 20, height: 20)),
            .object(["role": .string("AXButton"), "frame": .object([
                "x": .number(10), "y": .number(10), "w": .number(20), "h": .number(-1)
            ])])
        ]
        XCTAssertTrue(GazeCandidateFeed.elementCandidates(Self.snap(elements: elements), row: Self.row(7)).isEmpty)
    }

    /// Token-less elements keep an index marker — the actuation path
    /// reads `_idx_` as "no verified click, fall back to pixel".
    nonisolated func testTokenlessElementID() {
        let out = GazeCandidateFeed.elementCandidates(
            Self.snap(elements: [Self.element(5)]), row: Self.row(7, pid: 42))
        XCTAssertEqual(out.first?.id, "ax:42:7:_idx_5")
        XCTAssertNil(VoiceTaskCoordinator.axToken(in: out[0].id))
        XCTAssertEqual(VoiceTaskCoordinator.axToken(in: "ax:42:7:axel_9"), "axel_9")
    }

    /// Non-actionable elements never enter the feed — a label-less
    /// AXImage can't be a referent worth a ring; a labelled group can.
    nonisolated func testNonActionableExcluded() {
        let out = GazeCandidateFeed.elementCandidates(Self.snap(elements: [
            Self.element(1, role: "AXImage", label: ""),
            Self.element(2, role: "AXButton", label: "Save"),
            Self.element(3, role: "AXGroup", label: "Panel"),
        ]), row: Self.row(7))
        XCTAssertEqual(out.map(\.id), ["ax:42:7:_idx_2", "ax:42:7:_idx_3"])
    }

    // MARK: enumerate ladder

    /// Window floor: every row is a `.window` candidate, our own pid and
    /// non-layer-0 rows excluded, topmost-under-gaze drives windowID.
    func testWindowFloor() async {
        var feed = Self.feed { [
            Self.row(1, pid: 42), // under the gaze
            Self.row(2, pid: 43, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            Self.row(3, pid: 999),                          // own — excluded
            Self.row(4, pid: 44, layer: 8),                 // overlay — excluded
        ] }
        feed.ownPID = 999
        let batch = await feed.enumerate(around: CGPoint(x: 200, y: 200))
        XCTAssertEqual(batch.windowID, 1)
        let windows = batch.candidates.filter { $0.kind == .window }
        XCTAssertEqual(windows.map(\.windowID), [1, 2])
        XCTAssertFalse(batch.candidates.contains { $0.pid == 999 || $0.pid == 44 })
    }

    /// Menu-bar items enter only while the point sits in the band.
    func testMenuBandGate() async {
        var feed = Self.feed { [Self.row(1)] }
        feed.menuBarItems = {
            [.init(title: "File", frame: CGRect(x: 20, y: 0, width: 40, height: 22), pid: 42)]
        }
        feed.inMenuBand = { $0.y < 24 }
        let off = await feed.enumerate(around: CGPoint(x: 200, y: 200))
        XCTAssertFalse(off.candidates.contains { $0.kind == .menuBar })
        let on = await feed.enumerate(around: CGPoint(x: 30, y: 10))
        XCTAssertEqual(on.candidates.first { $0.kind == .menuBar }?.label, "File")
    }

    /// The OCR floor fires only when nothing actionable is near the
    /// point — AX coverage wins over pixels.
    func testOCRFloorOnlyWhenBlind() async {
        var feed = Self.feed { [Self.row(1)] }
        let ocrCalls = Counter()
        feed.ocrRegions = { _ in
            ocrCalls.bump()
            return [(CGRect(x: 180, y: 180, width: 60, height: 14), "Score: 12")]
        }
        // Nothing actionable → OCR answers.
        var batch = await feed.enumerate(around: CGPoint(x: 200, y: 200))
        XCTAssertEqual(ocrCalls.value, 1)
        XCTAssertEqual(batch.candidates.first { $0.kind == .ocr }?.label, "Score: 12")
        // A nearby actionable element → the floor stays down.
        feed.elementSnapshot = { _, _ in Self.snap(elements: [Self.element(1)]) }
        batch = await feed.enumerate(around: CGPoint(x: 230, y: 145))
        XCTAssertEqual(ocrCalls.value, 1)
        XCTAssertTrue(batch.candidates.contains { $0.kind == .axElement })
    }

    /// A browser window probes the DOM; a non-browser never pays for it.
    func testDOMProbeOnlyForBrowsers() async {
        var feed = Self.feed { [Self.row(1)] }
        let probeCalls = Counter()
        feed.domProbe = { _, _ in
            probeCalls.bump()
            let r = CGRect(x: 150, y: 150, width: 40, height: 16)
            return [IntentCandidate(id: "dom:42:1:0", kind: .dom, frame: r,
                                    motorRect: r, role: "a", label: "Pricing",
                                    url: "https://x.test/p", pid: 42,
                                    windowID: 1)]
        }
        feed.bundleID = { _ in "com.google.Chrome" }
        var batch = await feed.enumerate(around: CGPoint(x: 155, y: 155))
        XCTAssertEqual(probeCalls.value, 1)
        XCTAssertEqual(batch.candidates.first { $0.kind == .dom }?.url,
                       "https://x.test/p")
        feed.bundleID = { _ in "com.apple.notes" }
        batch = await feed.enumerate(around: CGPoint(x: 155, y: 155))
        XCTAssertEqual(probeCalls.value, 1)   // not a browser — no second probe
    }

    /// Traffic lights carry their BUTTON rects on both `frame` and
    /// `motorRect` — the whole-window frame made all three a permanent
    /// top-2 tie (every AX-matched window deadlocked .ambiguous). The
    /// window association rides `windowID`, never `frame`.
    func testTrafficLightsCarryButtonFrames() async {
        var feed = Self.feed { [Self.row(1)] }
        let frames: [WindowControls.Kind: CGRect] = [
            .close: CGRect(x: 112, y: 104, width: 12, height: 12),
            .minimize: CGRect(x: 132, y: 104, width: 12, height: 12),
            .zoom: CGRect(x: 152, y: 104, width: 12, height: 12),
        ]
        feed.trafficLights = { _, _ in
            frames.map { WindowControls.Button(kind: $0.key, frame: $0.value) }
        }
        let batch = await feed.enumerate(around: CGPoint(x: 118, y: 110))
        let lights = batch.candidates.filter { $0.kind == .trafficLight }
        XCTAssertEqual(lights.count, 3)
        let windowBounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        for c in lights {
            let kind = WindowControls.Kind(
                rawValue: String(c.id.split(separator: ":").last!))
            XCTAssertNotNil(kind)
            XCTAssertEqual(c.frame, frames[kind!], "\(c.id)")
            XCTAssertEqual(c.motorRect, frames[kind!], "\(c.id)")
            XCTAssertNotEqual(c.frame, windowBounds)
            XCTAssertEqual(c.windowID, 1)
            XCTAssertEqual(c.pid, 42)
        }
        // The fixated light scores at distance 0, its neighbours don't —
        // the three candidates differentiate instead of tying.
        let gaze = CGPoint(x: 118, y: 110)
        XCTAssertEqual(lights.first { $0.id.hasSuffix(":close") }?
            .edgeDistance(to: gaze), 0)
        XCTAssertGreaterThan(lights.first { $0.id.hasSuffix(":zoom") }?
            .edgeDistance(to: gaze) ?? 0, 0)
    }

    /// The feed's window-state call never requests a screenshot —
    /// candidates need the AX tree only, and the PNG costs real latency
    /// per enumeration.
    func testSnapshotRequestsTreeWithoutScreenshot() async {
        var feed = Self.feed { [Self.row(1)] }
        feed.elementSnapshot = nil   // route through the driver seam
        let calls = Counter()
        feed.call = { tool, args in
            calls.bump()
            XCTAssertEqual(tool, "get_window_state")
            XCTAssertEqual(args["include_screenshot"], .bool(false))
            XCTAssertEqual(args["session"], .string("voice-gaze"))
            return .object([:])
        }
        _ = await feed.enumerate(around: CGPoint(x: 200, y: 200))
        XCTAssertEqual(calls.value, 1)
    }

    /// The two driver reads ride their own lanes: the element snapshot —
    /// read-only — takes `readCall` while the DOM probe
    /// (execute_javascript is mutation-class on the wire) keeps `call`.
    /// Splitting them is what lets the pair actually overlap.
    func testSnapshotRidesReadLaneDOMKeepsMutationLane() async {
        var feed = Self.feed { [Self.row(1)] }
        feed.elementSnapshot = nil      // snapshot through the driver seam
        feed.domProbe = nil             // DOM probe through `call`
        feed.bundleID = { _ in "com.google.Chrome" }
        let lane = LaneRecorder()
        feed.call = { tool, _ in
            lane.note("call", tool)
            return .object([:])
        }
        feed.readCall = { tool, _ in
            lane.note("read", tool)
            return .object([:])
        }
        _ = await feed.enumerate(around: CGPoint(x: 200, y: 200))
        XCTAssertEqual(lane.tools(on: "read"), ["get_window_state"])
        XCTAssertEqual(lane.tools(on: "call"), ["page"])
    }

    /// No read lane wired → the snapshot falls through to `call`, the
    /// single-transport behavior callers without a pool already have.
    func testSnapshotFallsBackToSingleLane() async {
        var feed = Self.feed { [Self.row(1)] }
        feed.elementSnapshot = nil
        let calls = Counter()
        feed.call = { tool, _ in
            calls.bump()
            XCTAssertEqual(tool, "get_window_state")
            return .object([:])
        }
        _ = await feed.enumerate(around: CGPoint(x: 200, y: 200))
        XCTAssertEqual(calls.value, 1)
    }

    /// Lane recorder — the @Sendable seams can't mutate a captured var.
    private final class LaneRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(lane: String, tool: String)] = []
        func note(_ lane: String, _ tool: String) {
            lock.lock(); log.append((lane, tool)); lock.unlock()
        }
        func tools(on lane: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return log.filter { $0.lane == lane }.map(\.tool)
        }
    }

    // MARK: actuation mapping

    nonisolated func testActuationMapping() {
        let button = IntentCandidate(
            id: "ax:42:7:axel_9", kind: .axElement,
            frame: CGRect(x: 100, y: 100, width: 80, height: 30),
            motorRect: CGRect(x: 100, y: 100, width: 80, height: 30),
            role: "AXButton", label: "Save", pid: 42, windowID: 7)
        XCTAssertEqual(VoiceTaskCoordinator.actuation(for: button, gaze: nil),
                       .elementClick(pid: 42, windowID: 7, token: "axel_9"))

        let traffic = IntentCandidate(
            id: "traffic:42:7:minimize", kind: .trafficLight,
            // frame/motorRect carry the BUTTON rect; the actuation's
            // window-match frame resolves live from windowID.
            frame: CGRect(x: 120, y: 106, width: 12, height: 12),
            motorRect: CGRect(x: 120, y: 106, width: 12, height: 12),
            role: "AXButton", label: "the yellow minimize button",
            pid: 42, windowID: 7)
        let windowRect = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(VoiceTaskCoordinator.actuation(
            for: traffic, gaze: nil, windowBounds: { _ in windowRect }),
            .trafficLight(.minimize, pid: 42, frame: windowRect))
        // A window that can't be resolved can't be matched — refuse.
        XCTAssertNil(VoiceTaskCoordinator.actuation(
            for: traffic, gaze: nil, windowBounds: { _ in nil }))

        // Pixel fallback — a gaze point inside the motor rect wins over
        // the midpoint; outside it, the midpoint.
        let dom = IntentCandidate(
            id: "dom:42:7:0", kind: .dom,
            frame: CGRect(x: 100, y: 100, width: 80, height: 30),
            motorRect: CGRect(x: 100, y: 100, width: 80, height: 30),
            role: "a", label: "Pricing")
        XCTAssertEqual(VoiceTaskCoordinator.actuation(
            for: dom, gaze: CGPoint(x: 110, y: 110)),
            .pixelClick(CGPoint(x: 110, y: 110)))
        XCTAssertEqual(VoiceTaskCoordinator.actuation(
            for: dom, gaze: CGPoint(x: 5, y: 5)),
            .pixelClick(CGPoint(x: 140, y: 115)))

        // Chrome never actuates.
        let chip = IntentCandidate(id: "agent:scout", kind: .agentCursor,
                                   frame: .zero, motorRect: .zero,
                                   role: "agent cursor", label: "Scout")
        XCTAssertNil(VoiceTaskCoordinator.actuation(for: chip, gaze: nil))
    }
}
