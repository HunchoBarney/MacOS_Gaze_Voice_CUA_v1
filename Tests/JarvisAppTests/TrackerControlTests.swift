import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: tracker self-control phrases route to `POST /control` or the
/// host feature switch — app-free, never a media key or a gaze referent —
/// and the status read reports the tracker's own state, not our guess.
final class TrackerControlTests: XCTestCase {

    // MARK: - Parse contracts

    /// Pause/resume tracking phrases all land on the single pause toggle.
    func testPauseResumePhrasesParse() {
        for phrase in ["pause tracking", "pause eye tracking", "pause the tracker",
                       "resume tracking", "resume eye tracking", "resume the eye tracker"] {
            guard let parsed = FastAction.parse(phrase),
                  case .tracker(let verb) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to a tracker verb")
                continue
            }
            XCTAssertEqual(verb, .pauseToggle, phrase)
        }
    }

    /// Recalibration phrases route to the recalibrate control action.
    func testRecalibrateParses() {
        for phrase in ["recalibrate", "recalibrate eyes", "tune the tracker"] {
            guard let parsed = FastAction.parse(phrase),
                  case .tracker(let verb) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to a tracker verb")
                continue
            }
            XCTAssertEqual(verb, .recalibrate, phrase)
        }
    }

    /// The feature-switch phrases route to enable/disable, not the
    /// tracker's API — it can't spawn itself.
    func testEnableDisableParse() {
        for phrase in ["turn eye tracking on", "enable eye tracking"] {
            guard let parsed = FastAction.parse(phrase),
                  case .tracker(let verb) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to a tracker verb")
                continue
            }
            XCTAssertEqual(verb, .enable, phrase)
        }
        for phrase in ["turn eye tracking off", "disable eye tracking"] {
            guard let parsed = FastAction.parse(phrase),
                  case .tracker(let verb) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to a tracker verb")
                continue
            }
            XCTAssertEqual(verb, .disable, phrase)
        }
    }

    /// The tracker table shadows nothing: bare pause/resume stay media
    /// keys, volume verbs stay volume, gaze referents stay gaze, and
    /// ordinary chords keep their lane.
    func testTrackerPhrasesShadowNothing() {
        for phrase in ["pause", "resume", "play it", "mute",
                       "turn it up", "turn the volume down"] {
            guard let parsed = FastAction.parse(phrase),
                  case .mediaKey = parsed.action.body else {
                XCTFail("'\(phrase)' must stay a media key")
                continue
            }
        }
        guard let click = FastAction.parse("click"),
              case .gaze = click.action.body else {
            return XCTFail("'click' must stay a gaze referent")
        }
        guard let tab = FastAction.parse("new tab"),
              case .hotkey = tab.action.body else {
            return XCTFail("'new tab' must stay a chord")
        }
        guard let open = FastAction.parse("open this"),
              case .gaze = open.action.body else {
            return XCTFail("'open this' must stay a gaze referent")
        }
    }

    /// Tracker verbs resolve app-free — a dead app roster can't sink them.
    func testTrackerVerbsResolveAppFree() {
        let r = DriveLoop.resolveFastLane(goal: "pause tracking", apps: [],
                                          frontmostBundle: nil)
        guard case .tracker(.pauseToggle)? = r?.action?.body else {
            return XCTFail("expected tracker, got \(String(describing: r?.action?.body))")
        }
        XCTAssertEqual(r?.bundle, "")
        XCTAssertNil(r?.openVerb)
    }

    // MARK: - Dispatch

    /// A scripted driver for fast-lane runs — same shape as GazeLaneTests.
    private final class FakeDriver {
        var calls: [(tool: String, args: [String: JSONValue])] = []
        var responses: [String: [JSONValue]] = [:]
        private let lock = NSLock()

        func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
            lock.lock()
            defer { lock.unlock() }
            calls.append((tool, args))
            if var queue = responses[tool], !queue.isEmpty {
                let first = queue.removeFirst()
                responses[tool] = queue
                return first
            }
            return .object(["effect": .string("confirmed")])
        }
    }

    /// Records every request the transport seam sees; each test hands it
    /// the status code the tracker would answer with.
    private final class FakeTransport {
        var requests: [URLRequest] = []
        var statusCode = 200
        var error: Error?
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            if let error { throw error }
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: statusCode,
                                    httpVersion: nil, headerFields: nil)!)
        }
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// "pause tracking" posts the tracker's pause toggle through
    /// `/control` — exactly once, with no app involved.
    func testPauseTrackingPostsControl() async {
        let transport = FakeTransport()
        let old = TrackerControl.transport
        defer { TrackerControl.transport = old }
        TrackerControl.transport = { try transport.send($0) }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "pause tracking"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/control")
        XCTAssertEqual(body(request)["action"] as? String, "pause_toggle")
        XCTAssertNil(body(request)["value"], "pause_toggle carries no value")
    }

    /// "recalibrate" posts the recalibrate action — same control surface.
    func testRecalibratePostsControl() async {
        let transport = FakeTransport()
        let old = TrackerControl.transport
        defer { TrackerControl.transport = old }
        TrackerControl.transport = { try transport.send($0) }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "recalibrate"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(body(transport.requests[0])["action"] as? String, "recalibrate")
    }

    /// A dead tracker blocks honestly — the pause is never claimed.
    func testTrackerDownBlocksHonestly() async {
        let transport = FakeTransport()
        transport.error = URLError(.cannotConnectToHost)
        let old = TrackerControl.transport
        defer { TrackerControl.transport = old }
        TrackerControl.transport = { try transport.send($0) }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "pause tracking"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertTrue(reason.contains("tracker"), reason)
    }

    /// A non-2xx answer is a refusal, never a claimed toggle.
    func testRejectedControlBlocksHonestly() async {
        let transport = FakeTransport()
        transport.statusCode = 400
        let old = TrackerControl.transport
        defer { TrackerControl.transport = old }
        TrackerControl.transport = { try transport.send($0) }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "recalibrate"), session: "t")
        guard case .blocked = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
    }

    /// "disable eye tracking" flips the host feature switch — the Config
    /// publisher owns the tracker lifecycle from there, no /control post.
    func testDisableFlipsFeatureSwitch() async {
        let transport = FakeTransport()
        let old = TrackerControl.transport
        defer { TrackerControl.transport = old }
        TrackerControl.transport = { try transport.send($0) }
        let oldValue = Config.shared.gazeTracking
        defer { Config.shared.gazeTracking = oldValue }

        let driver = FakeDriver()
        driver.responses["list_apps"] = [.object(["apps": .array([])])]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "disable eye tracking"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertFalse(Config.shared.gazeTracking)
        XCTAssertTrue(transport.requests.isEmpty, "the feature switch is host-side, not a tracker POST")
    }

    // MARK: - Client contract

    /// `post` sends the exact `{"action":…, "value":…}` shape the tracker
    /// validates — non-enum actions get a 400, so the wire shape is the
    /// contract.
    func testPostWireShape() async throws {
        let transport = FakeTransport()
        let control = TrackerControl(send: { try transport.send($0) })
        try await control.post(action: "dot_scale", value: 1.25)
        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/control")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let obj = body(request)
        XCTAssertEqual(obj["action"] as? String, "dot_scale")
        XCTAssertEqual(obj["value"] as? Double, 1.25)
    }

    /// Transport failure reads as unreachable; a non-2xx as rejected.
    func testPostFailures() async {
        var control = TrackerControl(send: { _ in throw URLError(.timedOut) })
        await XCTAssertAsyncThrows(try await control.post(action: "recalibrate")) {
            XCTAssertEqual($0 as? TrackerControlError, .unreachable)
        }
        control = TrackerControl(send: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503,
                                     httpVersion: nil, headerFields: nil)!)
        })
        await XCTAssertAsyncThrows(try await control.post(action: "recalibrate")) {
            XCTAssertEqual($0 as? TrackerControlError, .rejected(503))
        }
    }

    /// The status read composes the snapshot slices the menu needs.
    func testStatusDecode() async throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let snapshot = """
        {"paused": true, "calibration_status": "loaded",
         "settings": {"dot_scale": 1.25, "dwell_lock": true},
         "preview": {"head_detected": true},
         "gaze": {"updated_at": "\(stamp)"}}
        """
        let control = TrackerControl(send: { request in
            XCTAssertEqual(request.url?.path, "/snapshot")
            return (Data(snapshot.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        })
        let status = try await control.status()
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.calibration, "loaded")
        XCTAssertEqual(status.dotScale, 1.25)
        XCTAssertEqual(status.dwellLock, true)
        XCTAssertEqual(status.headDetected, true)
        XCTAssertEqual(status.gazeFresh, true)
        XCTAssertEqual(status.label, "Paused")
    }

    /// A dead tracker throws unreachable — the menu dims, never guesses.
    func testStatusUnreachable() async {
        let control = TrackerControl(send: { _ in throw URLError(.cannotConnectToHost) })
        await XCTAssertAsyncThrows(try await control.status()) {
            XCTAssertEqual($0 as? TrackerControlError, .unreachable)
        }
    }

    /// A non-2xx answer is unreachable too — an error page's JSON must
    /// not decode to a default "Tracking" status.
    func testStatusNonSuccessThrows() async {
        let control = TrackerControl(send: { request in
            (Data(#"{"error":"not_found"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 404,
                             httpVersion: nil, headerFields: nil)!)
        })
        await XCTAssertAsyncThrows(try await control.status()) {
            XCTAssertEqual($0 as? TrackerControlError, .unreachable)
        }
    }

    /// The label mirrors the tracker's own menu precedence: pause
    /// outranks calibration, calibration outranks face presence.
    func testLabelPrecedence() {
        XCTAssertEqual(TrackerStatus(paused: true, calibration: "missing",
                                   headDetected: false).label, "Paused")
        XCTAssertEqual(TrackerStatus(calibration: "missing").label, "Needs calibration")
        XCTAssertEqual(TrackerStatus(calibration: "invalid").label, "Needs calibration")
        XCTAssertEqual(TrackerStatus(calibration: "rejected_fit").label, "Calibrating")
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                   headDetected: false).label, "No face")
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                   gazeFresh: false).label, "No face")
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                   headDetected: true).label, "Tracking")
        // Terminal "saved" is never "Calibrating" — with a live gaze stamp
        // it reads "Tracking".
        XCTAssertEqual(TrackerStatus(calibration: "saved",
                                   gazeFresh: true).label, "Tracking")
        // A tracker that never produced a frame (no gaze stamp, no live
        // face claim) must not claim "Tracking": inside the boot grace it
        // reads "Starting"; past it — or with no boot stamp at all — the
        // honest word is "No gaze".
        XCTAssertEqual(TrackerStatus(calibration: "saved").label, "No gaze")
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                   startedAt: Date()).label, "Starting")
        XCTAssertEqual(TrackerStatus(calibration: "loaded",
                                   startedAt: Date()
                                       .addingTimeInterval(-(TrackerStatus.bootGraceWindow + 5))).label,
                       "No gaze")
    }
}

/// Contract: `stop()` spends the spawn budget permanently — only a
/// user-initiated start clears it, and that path is the single spawn
/// drive (the Config sink's ensureRunning never duplicates).
final class TrackerHostLifecycleTests: XCTestCase {

    /// After `stop()` the attempt bound gates `ensureRunning` — an
    /// ordinary retry must stay stopped so a deliberate kill can't
    /// respawn behind the user's back.
    func testStopBoundGatesEnsureRunning() async {
        let host = TrackerHost()
        await host.stop()
        await host.ensureRunning()
        let state = await host.state
        XCTAssertEqual(state, .stopped,
                       "ensureRunning after stop() must stay bound")
    }

    /// A user-requested start clears the stop bound — the run leaves
    /// `.stopped` (fails honestly on a tracker-less checkout, adopts or
    /// spawns on a box that has one).
    func testUserRequestedStartClearsStopBound() async {
        let host = TrackerHost()
        await host.stop()
        await host.ensureRunning()
        var state = await host.state
        XCTAssertEqual(state, .stopped)
        await host.userRequestedStart()
        state = await host.state
        for _ in 0..<50 where state == .stopped {
            try? await Task.sleep(for: .milliseconds(100))
            state = await host.state
        }
        XCTAssertNotEqual(state, .stopped,
                          "a user-requested start must clear the stop bound")
    }
}

/// `XCTestExpectation`-free async error assertion — the suite has no
/// shared helper for this, and the shape keeps the error check readable.
private func XCTAssertAsyncThrows<T>(_ expression: @autoclosure () async throws -> T,
                                     _ check: (Error) -> Void,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        check(error)
    }
}
