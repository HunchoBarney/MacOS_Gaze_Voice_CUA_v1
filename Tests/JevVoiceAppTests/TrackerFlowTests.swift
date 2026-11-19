import Darwin
import XCTest
@testable import JevVoice
import JevVoiceCore

// MARK: - A real loopback stand-in for the tracker

/// An actual HTTP/1.1 server on 127.0.0.1 — POSIX sockets, no
/// URLProtocol, no transport substitution. It plays back the tracker
/// contract from EyeTracking/electron/externalApi.cjs: GET /snapshot
/// serves the shared state store, POST /control takes
/// {"action": <name>, "value": <any>} and 400s a non-enum action.
///
/// A real socket under the tests proves what the fake-transport seam
/// can't: URLSession's actual request bytes on the wire, the response
/// status line, and the client's own 2s timeout against a connection
/// that answers nothing.
private final class TrackerStub: @unchecked Sendable {
    /// One request exactly as it arrived — method, path, raw body.
    struct Request: Equatable {
        var method: String
        var path: String
        var body: Data
    }

    /// (method, path, body text) → (HTTP status, response body). Tests
    /// script the tracker's answer per request.
    var respond: (_ method: String, _ path: String, _ body: String) -> (Int, String) = { _, _, _ in
        (200, #"{"ok":true}"#)
    }
    /// When true the request is accepted and recorded but never answered —
    /// the socket stays open and silent so the client's own timeout is
    /// what ends it.
    var hang = false

    private(set) var port = 0
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private let lock = NSLock()
    private var _requests: [Request] = []
    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    private var listenFD: Int32 = -1
    private var openFDs: Set<Int32> = []
    private var stopped = false
    private var acceptDone: DispatchSemaphore?

    enum StubError: Error { case socket(Int32), bind(Int32), listen(Int32) }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x7F000001).bigEndian)
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw StubError.bind(errno) }
        guard listen(fd, 8) == 0 else { close(fd); throw StubError.listen(errno) }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        listenFD = fd
        stopped = false
        let done = DispatchSemaphore(value: 0)
        acceptDone = done
        DispatchQueue.global().async { [weak self] in
            self?.acceptLoop()
            done.signal()
        }
    }

    /// Interrupts every in-flight read (shutdown wakes a blocked recv,
    /// which is what makes stop() prompt for a hanging connection) and
    /// stops the accept loop. Connection threads close their own fds,
    /// so the fd number can never be reused under a live connection.
    func stop() {
        lock.lock()
        stopped = true
        let clients = Array(openFDs)
        lock.unlock()
        for fd in clients { shutdown(fd, SHUT_RDWR) }
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            lock.lock(); listenFD = -1; lock.unlock()
        }
        _ = acceptDone?.wait(timeout: .now() + 2)
    }

    private func acceptLoop() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }
            // A write to a socket the client already abandoned must not
            // SIGPIPE the test process.
            var yes: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            let alive = !stopped
            if alive { openFDs.insert(cfd) }
            lock.unlock()
            if !alive { close(cfd); continue }
            DispatchQueue.global().async { [weak self] in
                self?.serve(cfd)
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock(); openFDs.remove(fd); lock.unlock()
            close(fd)
        }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            while !Self.hasFullRequest(pending) {
                let n = recv(fd, &chunk, chunk.count, 0)
                if n <= 0 { return }
                pending.append(contentsOf: chunk[0..<n])
            }
            guard let (request, consumed) = Self.parse(pending) else { return }
            pending = pending.count > consumed
                ? pending.subdata(in: consumed..<pending.count) : Data()
            lock.lock()
            _requests.append(request)
            let scripted = respond
            let hanging = hang
            lock.unlock()
            if hanging {
                // Answer nothing — block on the client's close. Its
                // request timeout ends the wait; a body that "took the
                // action but never replied" is the wedge shape this
                // flag exists to probe.
                while recv(fd, &chunk, chunk.count, 0) > 0 {}
                return
            }
            let (status, json) = scripted(request.method, request.path,
                                          String(decoding: request.body, as: UTF8.self))
            guard Self.write(fd, status: status, body: json) else { return }
            // HTTP/1.1 keep-alive: loop for the next request on this
            // connection — URLSession reuses sockets.
        }
    }

    /// A complete request is buffered once the header terminator arrived
    /// and Content-Length bytes of body followed it.
    private static func hasFullRequest(_ data: Data) -> Bool {
        guard let headEnd = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return false }
        let head = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self)
        return data.count >= headEnd.upperBound + contentLength(head)
    }

    private static func parse(_ data: Data) -> (Request, Int)? {
        guard let headEnd = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return nil }
        let head = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self)
        guard let line = head.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        let path = target.split(separator: "?").first.map(String.init) ?? target
        let length = contentLength(head)
        guard data.count >= headEnd.upperBound + length else { return nil }
        let body = data.subdata(in: headEnd.upperBound..<headEnd.upperBound + length)
        return (Request(method: String(parts[0]), path: path, body: body),
                headEnd.upperBound + length)
    }

    private static func contentLength(_ head: String) -> Int {
        for line in head.split(separator: "\r\n") {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces)
                      .lowercased() == "content-length" else { continue }
            return Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private static let reasons: [Int: String] = [
        200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found",
        405: "Method Not Allowed", 500: "Internal Server Error",
        503: "Service Unavailable"
    ]

    private static func write(_ fd: Int32, status: Int, body json: String) -> Bool {
        let body = Data(json.utf8)
        let header = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: keep-alive\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out.withUnsafeBytes { ptr -> Bool in
            var sent = 0
            while sent < out.count {
                let n = Darwin.send(fd, ptr.baseAddress!.advanced(by: sent),
                                    out.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

// MARK: - Shared fixtures

/// The snapshot body the real store serves — every top-level slice from
/// externalStore.cjs's initial state is present so the decode under test
/// sees production-shaped JSON, not a minimal fixture.
private func trackerSnapshot(paused: Bool = false,
                             calibration: String? = "loaded",
                             headDetected: Bool? = nil,
                             previewAge: TimeInterval? = nil,
                             gazeAge: TimeInterval? = nil,
                             settings: [String: Any]? = nil) -> String {
    let now = Date()
    let stamp: (Date) -> String = { date in
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    var snapshot: [String: Any] = [
        "schema_version": 1,
        "started_at": stamp(now),
        "updated_at": stamp(now),
        "paused": paused
    ]
    if let calibration { snapshot["calibration_status"] = calibration }
    if let headDetected {
        var preview: [String: Any] = ["head_detected": headDetected]
        if let previewAge { preview["updated_at"] = stamp(now.addingTimeInterval(-previewAge)) }
        snapshot["preview"] = preview
    }
    if let gazeAge {
        snapshot["gaze"] = ["updated_at": stamp(now.addingTimeInterval(-gazeAge))]
    }
    if let settings { snapshot["settings"] = settings }
    // swiftlint:disable:next force_try — literals above are always serializable
    return String(decoding: try! JSONSerialization.data(withJSONObject: snapshot),
                  as: UTF8.self)
}

/// The status line the Settings/eyes surfaces lean on — a freshly-stamped
/// snapshot with a live face and a fresh gaze stream.
private func healthySnapshot(paused: Bool = false,
                             calibration: String? = "loaded") -> String {
    trackerSnapshot(paused: paused, calibration: calibration,
                    headDetected: true, previewAge: 0.2, gazeAge: 0.1,
                    settings: ["dot_scale": 1.25, "dwell_lock": true,
                               "gaze_dot_visible": false])
}

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

// MARK: - TrackerControl over a real socket

/// Contract: `TrackerControl` speaks the tracker's external API on an
/// actual socket — /control is a POST carrying {"action":…,"value":…},
/// /snapshot decodes every slice the menu and Settings card read, and
/// the three honest failures (dead socket, non-2xx, silent socket) all
/// surface as typed errors, never a fabricated state.
final class TrackerControlFlowTests: XCTestCase {

    private var stub: TrackerStub!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stub = TrackerStub()
        try stub.start()
    }

    override func tearDown() {
        stub?.stop()
        stub = nil
        super.tearDown()
    }

    private var control: TrackerControl { TrackerControl(baseURL: stub.baseURL) }

    /// The pause toggle lands on the wire exactly as
    /// externalApi.cjs parses it: POST /control, JSON body, action name.
    /// A settings action then proves the value slot travels too.
    func testControlPostWireBytes() async throws {
        try await control.post(action: "pause_toggle")
        try await control.post(action: "dot_scale", value: 1.25)

        let requests = stub.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/control")
        }
        let first = try JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any]
        XCTAssertEqual(first?["action"] as? String, "pause_toggle")
        XCTAssertNil(first?["value"], "pause_toggle carries no value")
        let second = try JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any]
        XCTAssertEqual(second?["action"] as? String, "dot_scale")
        XCTAssertEqual(second?["value"] as? Double, 1.25)
    }

    /// A production-shaped snapshot decodes to every field the status
    /// item and the Settings card bind — including the settings slice
    /// values the card's read-back writes onto its controls.
    func testSnapshotDecodesTheWholeWireShape() async throws {
        stub.respond = { _, path, _ in
            guard path == "/snapshot" else { return (404, #"{"error":"not_found"}"#) }
            return (200, healthySnapshot())
        }
        let status = try await control.status()
        XCTAssertEqual(stub.requests.map(\.method), ["GET"])
        XCTAssertEqual(stub.requests.map(\.path), ["/snapshot"])
        XCTAssertFalse(status.paused)
        XCTAssertEqual(status.calibration, "loaded")
        XCTAssertEqual(status.headDetected, true)
        XCTAssertEqual(status.gazeFresh, true)
        XCTAssertEqual(status.dotScale, 1.25)
        XCTAssertEqual(status.dwellLock, true)
        XCTAssertEqual(status.dotVisible, false)
        XCTAssertEqual(status.label, "Tracking")
    }

    /// A 503 serving a perfectly decodable tracker body still throws —
    /// the status code arbitrates, never the payload. An error page's
    /// JSON must not masquerade as a live tracker.
    func testNonSuccessStatusRefusesTheBody() async {
        stub.respond = { _, _, _ in (503, healthySnapshot()) }
        await XCTAssertAsyncThrows(try await control.status()) {
            XCTAssertEqual($0 as? TrackerControlError, .unreachable)
        }
    }

    /// A 200 whose body isn't JSON is unreachable too — a truncated or
    /// proxy-mangled answer is no snapshot.
    func testMalformedSnapshotBodyIsUnreachable() async {
        stub.respond = { _, _, _ in (200, "not json{{{") }
        await XCTAssertAsyncThrows(try await control.status()) {
            XCTAssertEqual($0 as? TrackerControlError, .unreachable)
        }
    }

    /// A socket that answers nothing hits the client's own 2s timeout —
    /// the failure surfaces as unreachable, and inside a small bound so
    /// a wedged tracker can't hang the status read.
    func testSilentSocketTimesOutAsUnreachable() async {
        stub.hang = true
        let started = Date()
        await XCTAssertAsyncThrows(try await control.status()) {
            XCTAssertEqual($0 as? TrackerControlError, .unreachable)
        }
        XCTAssertEqual(stub.requests.count, 1,
                       "the request arrived — it's the reply that never comes")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "the client timeout, not the test runner, ends it")
    }

    /// The tracker's own answer to a non-enum action is 400
    /// {"error":"bad_request"} — rejected, with the code kept.
    func testNonEnumActionIsRejected() async {
        stub.respond = { method, path, body in
            guard path == "/control", method == "POST" else {
                return (404, #"{"error":"not_found"}"#)
            }
            let action = (try? JSONSerialization.jsonObject(
                with: Data(body.utf8))) as? [String: Any]
            let known: Set<String> = ["pause_toggle", "set_paused", "recalibrate",
                                      "dot_scale", "gaze_dot", "dwell_lock",
                                      "preview_toggle", "status_toggle",
                                      "inference_time_toggle", "show_marker",
                                      "implicit_sample", "quit"]
            if let name = action?["action"] as? String, known.contains(name) {
                return (200, #"{"ok":true}"#)
            }
            return (400, #"{"error":"bad_request"}"#)
        }
        await XCTAssertAsyncThrows(try await control.post(action: "definitely_not_real")) {
            XCTAssertEqual($0 as? TrackerControlError, .rejected(400))
        }
    }

    /// Nothing listening — the "tracker isn't running" shape the menu
    /// reads as unreachable.
    func testClosedPortIsUnreachable() async {
        let dead = TrackerControl(baseURL: URL(string: "http://127.0.0.1:1")!)
        await XCTAssertAsyncThrows(try await dead.status()) {
            XCTAssertEqual($0 as? TrackerControlError, .unreachable)
        }
    }
}

// MARK: - Eyes menu state derivation

/// Contract: the status item's Eyes label is the host state word first
/// and the served snapshot second — `applyEyesState`/`paintEyes`
/// (main.swift) are private, so the reachable seam is the piece the menu
/// renders: `TrackerControl().status()` over a real socket producing the
/// `TrackerStatus` whose `.label` becomes "Eyes — <label>", and nil
/// (a failed read) becoming "Eyes — Running". Each test below is the
/// wire half of one menu state; the host-side words (Starting…, Stopped,
/// Off) live behind private NSMenuItems and are documented, not faked.
final class EyesMenuFlowTests: XCTestCase {

    private var stub: TrackerStub!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stub = TrackerStub()
        try stub.start()
        stub.respond = { _, path, _ in
            path == "/snapshot" ? (200, healthySnapshot())
                                : (404, #"{"error":"not_found"}"#)
        }
    }

    override func tearDown() {
        stub?.stop()
        stub = nil
        super.tearDown()
    }

    private var control: TrackerControl { TrackerControl(baseURL: stub.baseURL) }

    /// Running + unpaused + calibrated + a live face and gaze feed —
    /// the menu paints "Eyes — Tracking" and unhides Pause/Recalibrate.
    func testRunningCalibratedReadsTracking() async throws {
        let status = try await control.status()
        XCTAssertEqual(status.label, "Tracking")
        XCTAssertEqual("Eyes — \(status.label)", "Eyes — Tracking")
    }

    /// A served pause outranks everything — the menu shows
    /// "Eyes — Paused" and flips its item to "Resume Tracking".
    func testPausedReadsPaused() async throws {
        stub.respond = { _, _, _ in
            (200, healthySnapshot(paused: true))
        }
        let status = try await control.status()
        XCTAssertEqual(status.label, "Paused")
        XCTAssertTrue(status.paused,
                      "the paused flag is what flips the menu item's title")
    }

    /// calibration_status "missing" — the tracker's word for no usable
    /// calibration on disk — names the remedy the menu advertises.
    func testMissingCalibrationReadsNeedsCalibration() async throws {
        stub.respond = { _, path, _ in
            (200, healthySnapshot(calibration: "missing"))
        }
        let status = try await control.status()
        XCTAssertEqual(status.label, "Needs calibration")
    }

    /// An in-flight calibration (the renderer reports pursuit_sampled
    /// while points land) reads "Calibrating" — neither done nor missing.
    func testInFlightCalibrationReadsCalibrating() async throws {
        stub.respond = { _, path, _ in
            (200, healthySnapshot(calibration: "pursuit_sampled"))
        }
        let status = try await control.status()
        XCTAssertEqual(status.label, "Calibrating")
    }

    /// A live preview reporting no face — "No face" is the fresh claim,
    /// not a stale guess.
    func testFreshPreviewMissReadsNoFace() async throws {
        stub.respond = { _, path, _ in
            (200, trackerSnapshot(calibration: "loaded",
                                  headDetected: false, previewAge: 0.2,
                                  gazeAge: 0.1))
        }
        let status = try await control.status()
        XCTAssertEqual(status.label, "No face")
    }

    /// The wedge shape: the preview's last claim was a face but its stamp
    /// is stale AND the gaze feed went quiet — the live headDetected
    /// clears (a frozen feed vouches for nothing) while the last claim
    /// keeps the label honest: "No gaze", not "No face".
    func testQuietFeedAfterAFaceReadsNoGaze() async throws {
        stub.respond = { _, path, _ in
            (200, trackerSnapshot(calibration: "loaded",
                                  headDetected: true,
                                  previewAge: 30, gazeAge: 30))
        }
        let status = try await control.status()
        XCTAssertNil(status.headDetected, "a stale preview vouches for nothing")
        XCTAssertEqual(status.lastHeadDetected, true,
                       "the last claim is kept — it's what names No gaze")
        XCTAssertEqual(status.gazeFresh, false)
        XCTAssertEqual(status.label, "No gaze")
    }

    /// A freshly booted tracker serves the store's initial state —
    /// calibration_status null, no preview, no gaze yet. Nothing claims
    /// a frame ever landed, so the label is the boot grace's "Starting",
    /// never "Tracking": the first real report is what earns that word.
    func testFreshBootSnapshotReadsStarting() async throws {
        let booted = """
        {"schema_version":1,"paused":false,"calibration_status":null,
         "preview":null,"gaze":null,"settings":null,
         "started_at":"\(ISO8601DateFormatter().string(from: Date()))",
         "runtime":{"name":"webgpu","updated_at":"\(ISO8601DateFormatter().string(from: Date()))}"},
         "models":{"detector":null,"gaze":null},"status":null}
        """
        stub.respond = { _, path, _ in (200, booted) }
        let status = try await control.status()
        XCTAssertEqual(status.calibration, "")
        XCTAssertNil(status.headDetected)
        XCTAssertNil(status.gazeFresh)
        XCTAssertEqual(status.label, "Starting")
    }

    /// The same fresh-boot snapshot without a started_at stamp can't
    /// prove it's still warming — "No gaze", not "Tracking".
    func testUnstampedSilentTrackerReadsNoGaze() async throws {
        let silent = """
        {"schema_version":1,"paused":false,"calibration_status":null,
         "preview":null,"gaze":null,"settings":null,
         "runtime":{"name":"webgpu","updated_at":"\(ISO8601DateFormatter().string(from: Date()))}"},
         "models":{"detector":null,"gaze":null},"status":null}
        """
        stub.respond = { _, path, _ in (200, silent) }
        let status = try await control.status()
        XCTAssertNil(status.headDetected)
        XCTAssertNil(status.gazeFresh)
        XCTAssertEqual(status.label, "No gaze")
    }

    /// Stopped/unreachable: the throw is what the menu's `try?` turns
    /// into eyesStatus=nil — with host state .running that paints
    /// "Eyes — Running"; with .stopped, "Eyes — Off". The throw itself
    /// is the seam this test can prove.
    func testUnreachableTrackerThrowsForTheMenu() async {
        stub.stop()
        let started = Date()
        await XCTAssertAsyncThrows(try await control.status()) {
            XCTAssertEqual($0 as? TrackerControlError, .unreachable)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

// MARK: - Voice commands through the drive loop

/// Contract: the spoken tracker commands ride the whole drive loop to
/// the tracker's socket — `GazeClient.defaultBaseURL` points `TrackerControl()`'s
/// default base URL at the stub, so `dispatchTrackerVerb` and the
/// refusal path both run production code over a real wire. The media
/// key seam stands in for the HID tap; the app's process-state seam
/// poses host states the refusal reads first.
final class TrackerCommandFlowTests: XCTestCase {

    /// Records the driver calls a run made — tracker verbs must never
    /// pay a roster read, and nothing else should reach the driver.
    private final class FakeDriver {
        var calls: [String] = []
        func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
            calls.append(tool)
            return .object(["apps": .array([])])
        }
    }

    private var stub: TrackerStub!
    private var oldGazeURL: URL!
    private var oldTrackerState: (() async -> TrackerHost.State)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stub = TrackerStub()
        try stub.start()
        // The one seam that moves every default TrackerControl()
        // (dispatch AND refusal status reads) onto the stub — the rest
        // of the path stays production code.
        oldGazeURL = GazeClient.defaultBaseURL
        GazeClient.defaultBaseURL = stub.baseURL
        oldTrackerState = DriveLoop.trackerState
    }

    override func tearDown() {
        DriveLoop.trackerState = oldTrackerState
        GazeClient.defaultBaseURL = oldGazeURL
        stub?.stop()
        stub = nil
        super.tearDown()
    }

    private func makeLoop(driver: FakeDriver,
                          postedKeys: ((MediaKeys.Key) -> Void)? = nil) -> DriveLoop {
        DriveLoop(call: { t, a in try driver.call(t, a) },
                  choose: { _, _ in nil }, ask: nil, granted: { true },
                  resolver: AppResolver(listApps: { [] }),
                  postMediaKey: { key in postedKeys?(key); return true },
                  frontmostBundleID: { nil })
    }

    private func bodies(_ requests: [TrackerStub.Request]) -> [[String: Any]] {
        requests.compactMap {
            try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any]
        }
    }

    /// "pause tracking" → POST /control {"action":"pause_toggle"} on the
    /// real wire — one request, no roster read, no model turn.
    func testPauseTrackingPostsTheToggle() async {
        let driver = FakeDriver()
        let result = await makeLoop(driver: driver)
            .run(DriveTask(goal: "pause tracking"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(driver.calls.isEmpty,
                      "a tracker verb never pays for list_apps")
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(stub.requests[0].method, "POST")
        XCTAssertEqual(stub.requests[0].path, "/control")
        XCTAssertEqual(bodies(stub.requests)[0]["action"] as? String, "pause_toggle")
        XCTAssertNil(bodies(stub.requests)[0]["value"])
    }

    /// "resume tracking" lands on the same toggle — the tracker, not the
    /// phrase, owns which way the pause went.
    func testResumeTrackingPostsTheSameToggle() async {
        let driver = FakeDriver()
        let result = await makeLoop(driver: driver)
            .run(DriveTask(goal: "resume tracking"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(bodies(stub.requests)[0]["action"] as? String, "pause_toggle")
    }

    /// "recalibrate" → POST /control {"action":"recalibrate"}.
    func testRecalibratePostsToControl() async {
        let driver = FakeDriver()
        let result = await makeLoop(driver: driver)
            .run(DriveTask(goal: "recalibrate"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(bodies(stub.requests)[0]["action"] as? String, "recalibrate")
    }

    /// "enable eye tracking" is the host feature switch — the Config
    /// publisher owns the spawn from there; no /control POST exists.
    func testEnableEyeTrackingFlipsTheSwitch() async {
        let wasEnabled = Config.shared.gazeTracking
        defer { Config.shared.gazeTracking = wasEnabled }
        await TrackerControl.setTrackingEnabled(false)

        let driver = FakeDriver()
        let result = await makeLoop(driver: driver)
            .run(DriveTask(goal: "enable eye tracking"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(Config.shared.gazeTracking)
        XCTAssertTrue(stub.requests.isEmpty,
                      "enable is host-side — the tracker can't spawn itself")
    }

    /// "disable eye tracking" — the same switch, the other way.
    func testDisableEyeTrackingFlipsTheSwitch() async {
        let wasEnabled = Config.shared.gazeTracking
        defer { Config.shared.gazeTracking = wasEnabled }
        await TrackerControl.setTrackingEnabled(true)

        let driver = FakeDriver()
        let result = await makeLoop(driver: driver)
            .run(DriveTask(goal: "disable eye tracking"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertFalse(Config.shared.gazeTracking)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    /// Bare "pause"/"resume" stay media keys — the HID seam records the
    /// key and the tracker hears nothing.
    func testBarePauseAndResumeStayMediaKeys() async {
        var posted: [MediaKeys.Key] = []
        let driver = FakeDriver()
        let loop = makeLoop(driver: driver) { posted.append($0) }
        for goal in ["pause", "resume"] {
            let result = await loop.run(DriveTask(goal: goal), session: "t")
            XCTAssertEqual(result.status, .done, goal)
        }
        XCTAssertEqual(posted, [.playPause, .playPause])
        XCTAssertTrue(stub.requests.isEmpty,
                      "a bare media key never reaches the tracker")
        XCTAssertTrue(driver.calls.isEmpty)
    }

    /// Lookalikes keep their own lanes — "track my time" and
    /// "recalibrate my display" name no tracker verb, so no /control
    /// POST can leave under their name. (They resolve to nothing
    /// app-bound either, so the run blocks honestly.)
    func testAmbiguousPhrasesNeverReachTheTracker() async {
        for goal in ["track my time", "recalibrate my display"] {
            if let parsed = FastAction.parse(goal),
               case .tracker = parsed.action.body {
                XCTFail("'\(goal)' must never parse to a tracker verb")
            }
            let driver = FakeDriver()
            let result = await makeLoop(driver: driver)
                .run(DriveTask(goal: goal), session: "t")
            guard case .blocked = result.status else {
                XCTFail("'\(goal)' should fall out of the fast lane, got \(result.status)")
                continue
            }
            XCTAssertFalse(driver.calls.contains { $0 != "list_apps" },
                           "'\(goal)' may read the roster but never mutates")
        }
        XCTAssertTrue(stub.requests.isEmpty,
                      "no ambiguous phrase may reach /control")
    }

    /// A refused control POST on a tracker that's still booting names
    /// the honest remedy — the process-state word beats the HTTP one.
    func testRefusedVerbWhileTrackerBoots() async {
        DriveLoop.trackerState = { .starting }
        stub.respond = { _, path, _ in
            path == "/control" ? (503, #"{"error":"unavailable"}"#)
                               : (404, #"{"error":"not_found"}"#)
        }
        let driver = FakeDriver()
        let result = await makeLoop(driver: driver)
            .run(DriveTask(goal: "pause tracking"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(reason, "The eye tracker is still starting — give it a few seconds.")
    }

    /// A refused POST on a live paused tracker names its own remedy —
    /// the refusal reads a REAL /snapshot off the stub to say it.
    func testRefusedVerbReadsTheLiveSnapshot() async {
        DriveLoop.trackerState = { .running }
        stub.respond = { _, path, _ in
            switch path {
            case "/control": return (503, #"{"error":"unavailable"}"#)
            case "/snapshot": return (200, healthySnapshot(paused: true))
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        let driver = FakeDriver()
        let result = await makeLoop(driver: driver)
            .run(DriveTask(goal: "pause tracking"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(reason,
                       "The tracker is paused and didn't take the command — say 'resume tracking'.")
        XCTAssertEqual(stub.requests.map(\.path), ["/control", "/snapshot"],
                       "the refusal consulted the tracker's own status, not a guess")
    }

    /// A refused POST and a dead status read alike land on the one
    /// "isn't running" line — nothing guesses.
    func testRefusedVerbWithDeadTrackerIsHonest() async {
        DriveLoop.trackerState = { .stopped }
        stub.respond = { _, _, _ in (503, #"{"error":"unavailable"}"#) }
        let driver = FakeDriver()
        let result = await makeLoop(driver: driver)
            .run(DriveTask(goal: "recalibrate"), session: "t")
        guard case .blocked(let reason) = result.status else {
            return XCTFail("expected blocked, got \(result.status)")
        }
        XCTAssertEqual(reason,
                       "The eye tracker isn't running — say 'turn eye tracking on' or open the Eyes menu.")
        XCTAssertEqual(result.blockedReason, "tracker control failed")
    }
}

// MARK: - Enable lifecycle

/// Contract: the enable path is a user-initiated start — the menu item,
/// the Settings toggle and the voice verb all funnel through
/// `Config.gazeTracking` (the app delegate's sink then calls
/// `TrackerHost.shared.userRequestedStart()`). These tests pin the two
/// reachable ends: the switch write (persisted, next launch reads it)
/// and `userRequestedStart()` clearing a spent spawn budget. The sink
/// itself is app-delegate wiring — no seam reaches it; that gap is
/// documented, not faked.
final class TrackerEnableFlowTests: XCTestCase {

    /// With the spawn budget spent, ensureRunning stays bound — but a
    /// user-requested start must clear it and run a REAL attempt: the
    /// spawn fuse turns that attempt into the honest .failed the Eyes
    /// menu reads; a live tracker on the port gets adopted instead. Both
    /// land only if the reset actually happened — a still-bound budget
    /// leaves .stopped standing forever. (No child is forked — the fuse
    /// is checked before any Process exists, and no kill path runs:
    /// installForTest poses the spent budget directly.)
    func testUserRequestedStartRunsAFullAttempt() async throws {
        let host = TrackerHost(spawnEnabled: false)
        await host.installForTest(child: nil, attempts: TrackerHost.maxAttempts,
                                  state: .stopped)
        await host.ensureRunning()
        var state = await host.state
        XCTAssertEqual(state, .stopped,
                       "a spent budget binds ensureRunning — the ordinary path can't respawn")
        let generation = await host.generationForTest

        await host.userRequestedStart()
        for _ in 0..<50 where state == .stopped || state == .starting {
            try? await Task.sleep(for: .milliseconds(100))
            state = await host.state
        }
        XCTAssertNotEqual(state, .stopped,
                          "a user-requested start must clear the stop bound")
        if case .failed(let message) = state {
            XCTAssertEqual(message, "tracker spawn disabled",
                           "the reset attempt ran the real start path — it hit the fuse")
        }
        let generationAfter = await host.generationForTest
        XCTAssertGreaterThan(generationAfter, generation,
                             "a fresh claim was minted — the attempt is real")
    }

    /// A deliberate start while the tracker already runs claims nothing —
    /// the enable path must not double-spawn over a live process.
    func testUserRequestedStartWhileRunningIsQuiet() async throws {
        let host = TrackerHost()
        await host.installForTest(child: nil, attempts: 0, state: .running)
        let generation = await host.generationForTest
        await host.userRequestedStart()
        let stateAfter = await host.state
        let generationAfter = await host.generationForTest
        XCTAssertEqual(stateAfter, .running)
        XCTAssertEqual(generationAfter, generation,
                       "no second spawn claim while one tracker is live")
    }

    /// The feature switch is a persisted write — the Settings toggle,
    /// the Eyes menu item and the voice verb all land on the same key
    /// the next launch reads.
    func testFeatureSwitchPersists() async {
        let old = Config.shared.gazeTracking
        defer { Config.shared.gazeTracking = old }
        await TrackerControl.setTrackingEnabled(false)
        XCTAssertFalse(Config.shared.gazeTracking)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "gazeTracking") as? Bool, false,
                       "the toggle persists — the next boot reads this key")
        await TrackerControl.setTrackingEnabled(true)
        XCTAssertTrue(Config.shared.gazeTracking)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "gazeTracking") as? Bool, true)
    }
}

// MARK: - Settings card round trips

/// Contract: the Eye Tracking card reads `/snapshot.settings` into its
/// controls and posts `{"action": <name>, "value": <v>}` on every edit —
/// dot_scale carries a Double, gaze_dot and dwell_lock carry Bools. The
/// dwell auto-click picker and the geometry pickers persist to
/// UserDefaults instead — the service reloads the policy and the next
/// spawn reads the geometry flags.
///
/// What stays out of reach: `eyeSettingsTouched` and the `.task`
/// read-back live in private SwiftUI @State — no test seam reaches them
/// without changing Sources/. The transport half of the contract — the
/// writes below and the decode above — is what's proven here.
final class EyeSettingsFlowTests: XCTestCase {

    private var stub: TrackerStub!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stub = TrackerStub()
        try stub.start()
    }

    override func tearDown() {
        stub?.stop()
        stub = nil
        super.tearDown()
    }

    private var control: TrackerControl { TrackerControl(baseURL: stub.baseURL) }

    /// The read side of the round trip: the settings slice the tracker
    /// serves lands on the exact fields the card binds
    /// (eyeDotScale/eyeDwellLock/eyeDotVisible) — absent slice leaves
    /// nils, which the card treats as "keep the local value".
    func testSettingsSliceDecodes() async throws {
        stub.respond = { _, path, _ in
            (200, trackerSnapshot(calibration: "loaded",
                                  settings: ["dot_scale": 1.25,
                                             "dwell_lock": true,
                                             "gaze_dot_visible": false]))
        }
        let status = try await control.status()
        XCTAssertEqual(status.dotScale, 1.25)
        XCTAssertEqual(status.dwellLock, true)
        XCTAssertEqual(status.dotVisible, false)

        stub.respond = { _, path, _ in
            (200, trackerSnapshot(calibration: "loaded", settings: nil))
        }
        let empty = try await control.status()
        XCTAssertNil(empty.dotScale)
        XCTAssertNil(empty.dwellLock)
        XCTAssertNil(empty.dotVisible)
    }

    /// The write side: each card control posts its action with the value
    /// type the tracker validates — the wire shape is the contract a
    /// Settings edit speaks.
    func testSettingsPostsCarryActionAndValue() async throws {
        try await control.post(action: "dot_scale", value: 1.25)
        try await control.post(action: "gaze_dot", value: true)
        try await control.post(action: "dwell_lock", value: false)

        let bodies = stub.requests.compactMap {
            try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any]
        }
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(bodies[0]["action"] as? String, "dot_scale")
        XCTAssertEqual(bodies[0]["value"] as? Double, 1.25,
                       "a Double rides the wire — the tracker numbers-checks it")
        XCTAssertEqual(bodies[1]["action"] as? String, "gaze_dot")
        XCTAssertEqual(bodies[1]["value"] as? Bool, true)
        XCTAssertEqual(bodies[2]["action"] as? String, "dwell_lock")
        XCTAssertEqual(bodies[2]["value"] as? Bool, false)
    }

    func testDwellModeWriteReloads() throws {
        let suiteName = "EyeSettingsFlowTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        for raw in ["off", "safe", "all"] {
            var policy = DwellPolicy.load(from: suite)
            policy.mode = try XCTUnwrap(DwellPolicy.Mode(rawValue: raw))
            policy.save(to: suite)
            XCTAssertEqual(DwellPolicy.load(from: suite).mode.rawValue, raw)
        }
        suite.set("bogus", forKey: DwellPolicy.modeKey)
        XCTAssertEqual(DwellPolicy.load(from: suite).mode, .off)
    }

    /// The geometry pickers persist UserDefaults keys the next spawn
    /// maps to launch flags — an "Auto" pick REMOVES the key, which is
    /// what returns the flag to the tracker's own default.
    func testTrackerGeometryRoundTrip() throws {
        let suiteName = "EyeSettingsFlowTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracker-geo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func value(after flag: String, in args: [String]) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func argv() -> [String] {
            TrackerHost.trackerArguments(trackerDir: dir, useProdRenderer: true,
                                         forceWasm: false, defaults: suite,
                                         hostPid: 4242)
        }

        // The card's exact write semantics: explicit picks set the keys.
        suite.set(27.0, forKey: "trackerDisplaySizeInch")
        suite.set("legacy", forKey: "trackerProjectionMode")
        suite.set(90, forKey: "trackerCameraFovDeg")
        var args = argv()
        XCTAssertEqual(value(after: "--display-size-inch", in: args), "27.0")
        XCTAssertEqual(value(after: "--gaze-projection-mode", in: args), "legacy")
        XCTAssertEqual(value(after: "--camera-fov", in: args), "90")

        // The "Auto" picks: removeObject, not a sentinel write — the
        // projection flag falls back to the tuned production default and
        // the FOV flag drops out entirely.
        suite.removeObject(forKey: "trackerDisplaySizeInch")
        suite.removeObject(forKey: "trackerProjectionMode")
        suite.removeObject(forKey: "trackerCameraFovDeg")
        args = argv()
        XCTAssertNotEqual(value(after: "--display-size-inch", in: args), "0.0",
                          "unset never emits a bogus zero")
        XCTAssertEqual(value(after: "--gaze-projection-mode", in: args),
                       "binocular-screen")
        XCTAssertNil(value(after: "--camera-fov", in: args))
    }
}
