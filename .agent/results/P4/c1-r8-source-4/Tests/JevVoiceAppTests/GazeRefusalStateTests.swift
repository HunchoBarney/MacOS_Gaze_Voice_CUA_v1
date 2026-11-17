import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: every user-facing surface tells the truth about tracker
/// state — a booting or respawning tracker never earns "turn it on",
/// a frozen preview can't hold the menu at "Tracking", and a deictic
/// type refuses instead of typing into a window nobody looked at.
final class GazeRefusalStateTests: XCTestCase {

    // MARK: - Fixtures

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

    /// Per-path transport stub — `/control` and `/snapshot` answer
    /// differently in a booting vs paused vs dead tracker.
    private final class FakeTransport {
        var requests: [URLRequest] = []
        var handler: (URLRequest) throws -> (Data, URLResponse) = { _ in
            throw URLError(.cannotConnectToHost)
        }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            return try handler(request)
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

    private func iso(_ age: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-age))
    }

    // MARK: - Label freshness

    /// A frozen preview must not hold the label at "Tracking": its stale
    /// `updated_at` clears the live claim while `lastHeadDetected`
    /// remembers what the preview last saw — and stale gaze after a
    /// seen face reads "No gaze", not "Tracking" or "No face".
    func testStalePreviewStopsVouching() async throws {
        let snapshot = """
        {"paused": false, "calibration_status": "loaded",
         "preview": {"head_detected": true, "updated_at": "\(iso(30))"},
         "gaze": {"updated_at": "\(iso(30))"}}
        """
        let control = TrackerControl(send: { request in
            (Data(snapshot.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!)
        })
        let status = try await control.status()
        XCTAssertNil(status.headDetected, "a 30s-old preview claim is not live")
        XCTAssertEqual(status.lastHeadDetected, true)
        XCTAssertEqual(status.gazeFresh, false)
        XCTAssertEqual(status.label, "No gaze")
    }

    /// A fresh preview stamp keeps the claim — and live gaze keeps the
    /// label at "Tracking".
    func testFreshPreviewStillVouches() async throws {
        let snapshot = """
        {"paused": false, "calibration_status": "loaded",
         "preview": {"head_detected": true, "updated_at": "\(iso(0.2))"},
         "gaze": {"updated_at": "\(iso(0.2))"}}
        """
        let control = TrackerControl(send: { request in
            (Data(snapshot.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!)
        })
        let status = try await control.status()
        XCTAssertEqual(status.headDetected, true)
        XCTAssertEqual(status.label, "Tracking")
    }

    /// A preview slice with no stamp can't be disproven — the raw claim
    /// stands (older tracker shape), but stale gaze still outranks it.
    func testUnstampedPreviewKeepsClaim() async throws {
        let snapshot = """
        {"paused": false, "calibration_status": "loaded",
         "preview": {"head_detected": true},
         "gaze": {"updated_at": "\(iso(30))"}}
        """
        let control = TrackerControl(send: { request in
            (Data(snapshot.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!)
        })
        let status = try await control.status()
        XCTAssertEqual(status.headDetected, true)
        XCTAssertEqual(status.label, "No gaze")
    }

    /// Precedence: gaze quiet after a seen face → "No gaze"; gaze quiet
    /// with no face evidence at all → "No face".
    func testNoGazeLabelPrecedence() {
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                     headDetected: true,
                                     gazeFresh: false).label, "No gaze")
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                     lastHeadDetected: true,
                                     gazeFresh: false).label, "No gaze")
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                     gazeFresh: false).label, "No face")
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                     headDetected: true).label, "Tracking")
    }

    // MARK: - Process-state refusals

    /// While the host is booting, a gaze failure says "still starting" —
    /// never "turn eye tracking on" (ensureRunning early-returns; the
    /// remedy is a no-op).
    func testStartingNeverOffersEnable() async {
        let old = DriveLoop.trackerState
        defer { DriveLoop.trackerState = old }
        DriveLoop.trackerState = { .starting }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { throw GazeError.unreachable })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("still starting"), reason)
        XCTAssertFalse(reason.contains("turn eye tracking on"), reason)
    }

    /// A crashed-out tracker names the restart path — the state string's
    /// short reason rides inside the sentence.
    func testFailedNamesRestart() async {
        let old = DriveLoop.trackerState
        defer { DriveLoop.trackerState = old }
        DriveLoop.trackerState = {
            .failed("The eye tracker exited and won't be restarted.")
        }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { throw GazeError.unreachable })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("stopped"), reason)
        XCTAssertTrue(reason.contains("exited and won't be restarted"), reason)
        XCTAssertTrue(reason.contains("enable eye tracking"), reason)
    }

    /// Process state doesn't arbitrate a live answer: `.stopped` while
    /// the tracker still serves `/snapshot` means the served status is
    /// the truth — paused is paused, whatever the host last recorded.
    func testStoppedKeepsLiveStatusRemedy() async {
        let old = DriveLoop.trackerState
        defer { DriveLoop.trackerState = old }
        DriveLoop.trackerState = { .stopped }
        let transport = FakeTransport()
        let oldTransport = TrackerControl.transport
        defer { TrackerControl.transport = oldTransport }
        TrackerControl.transport = { try transport.send($0) }
        transport.handler = { request in
            (Data(#"{"paused":true,"calibration_status":"loaded","preview":{"head_detected":true}}"# .utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!)
        }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { throw GazeError.unreachable })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("resume tracking"), reason)
    }

    /// `.stopped` with nothing serving lands on the original
    /// "isn't running" line — unchanged remedy.
    func testStoppedAndSilentKeepsIsntRunning() async {
        let old = DriveLoop.trackerState
        defer { DriveLoop.trackerState = old }
        DriveLoop.trackerState = { .stopped }
        let transport = FakeTransport()
        let oldTransport = TrackerControl.transport
        defer { TrackerControl.transport = oldTransport }
        TrackerControl.transport = { try transport.send($0) }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { throw GazeError.unreachable })
        let result = await loop.run(DriveTask(goal: "click"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("isn't running"), reason)
        XCTAssertTrue(reason.contains("turn eye tracking on"), reason)
    }

    /// A tracker verb that fails while the host is booting gets the same
    /// "wait" answer — never an offer to enable what's already starting.
    func testTrackerVerbStartingRefusal() async {
        let old = DriveLoop.trackerState
        defer { DriveLoop.trackerState = old }
        DriveLoop.trackerState = { .starting }
        let transport = FakeTransport()
        let oldTransport = TrackerControl.transport
        defer { TrackerControl.transport = oldTransport }
        TrackerControl.transport = { try transport.send($0) }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "pause tracking"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("still starting"), reason)
        XCTAssertFalse(reason.contains("turn eye tracking on"), reason)
    }

    /// `.running` falls through to the status-derived remedy: a rejected
    /// pause_toggle on a paused tracker names "resume tracking".
    func testTrackerVerbRunningUsesStatusRemedy() async {
        let old = DriveLoop.trackerState
        defer { DriveLoop.trackerState = old }
        DriveLoop.trackerState = { .running }
        let transport = FakeTransport()
        let oldTransport = TrackerControl.transport
        defer { TrackerControl.transport = oldTransport }
        TrackerControl.transport = { try transport.send($0) }
        transport.handler = { request in
            if request.url?.path == "/control" {
                throw URLError(.cannotConnectToHost) // the POST failed
            }
            return (Data(#"{"paused":true,"calibration_status":"loaded"}"# .utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "pause tracking"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("resume tracking"), reason)
    }

    // MARK: - Deictic + scroll targeting

    /// "type X here" with a dead tracker refuses — it must not retarget
    /// the bound window and type into a place nobody pointed at.
    func testDeicticTypeRefusesWithoutGaze() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [
            .object(["apps": .array([appRow("Notes", "com.apple.Notes", pid: 42)])])]
        driver.responses["list_windows"] = [
            .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600)])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { throw GazeError.unreachable },
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "type hello there here"),
                                    session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("tell me which window"), reason)
        XCTAssertTrue(driver.calls.allSatisfy { $0.tool != "type_text" && $0.tool != "click" },
                      "no keystroke may land without the gaze point")
    }

    /// Gaze over bare desktop ("here" names no window) refuses rather
    /// than typing into the bound window — the same wrong-target class.
    func testDeicticTypeRefusesWhenNothingUnderGaze() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [
            .object(["apps": .array([appRow("Notes", "com.apple.Notes", pid: 42)])])]
        driver.responses["list_windows"] = [
            .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600)])]),
            .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600)])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: gaze(1800, 900), // outside the one window
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "type hello there here"),
                                    session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("no window where you're looking"), reason)
        XCTAssertTrue(driver.calls.allSatisfy { $0.tool != "type_text" && $0.tool != "click" })
    }

    func testMissingScrollViewportSendsNoInputAndNamesTheRequestedWindow() async {
        let driver = FakeDriver()
        driver.responses["list_apps"] = [
            .object(["apps": .array([appRow("Notes", "com.apple.Notes", pid: 42)])])]
        driver.responses["list_windows"] = [
            .object(["windows": .array([
                windowRow(id: 7, pid: 42, app: "Notes", title: "Notes",
                          x: 0, y: 0, w: 800, h: 600)])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             gaze: { throw GazeError.unreachable },
                             frontmostBundleID: { "com.apple.Notes" })
        let result = await loop.run(DriveTask(goal: "scroll down"), session: "t")
        XCTAssertEqual(result.blockedReason, DriveLoop.scrollUnverifiedReason)
        XCTAssertFalse(driver.calls.contains { ["scroll", "hotkey", "press_key"].contains($0.tool) })
        let say = result.history.joined(separator: "\n")
        XCTAssertTrue(say.contains("Notes"), say)
        XCTAssertTrue(say.contains("Eye tracking is unavailable"), say)
    }
}
