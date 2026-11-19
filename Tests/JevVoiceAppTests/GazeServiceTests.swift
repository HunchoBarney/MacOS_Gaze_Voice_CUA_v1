import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: the always-on service — one stream for the app's life,
/// candidates re-enumerated only on the gate's signals (window change,
/// settled fixation, TTL), scorer events fan out to the ring, dwell
/// fires land on the actuation seam, and commits/referent context read
/// through the scorer. The Fn pump reads the same stream; teardown is
/// owned here, never by a hold.
@MainActor
final class GazeServiceTests: XCTestCase {

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One gaze frame in the `/events` wire shape.
    private func gazeFrame(_ x: Double, _ y: Double,
                           state: String = "fixation", at date: Date = Date()) -> String {
        let stamp = Self.iso.string(from: date)
        return #"{"type":"snapshot","snapshot":{"gaze":{"x_px":\#(x),"y_px":\#(y),"confidence":0.9,"gaze_state":"\#(state)","captured_at_ms":\#(date.timeIntervalSince1970 * 1000),"updated_at":"\#(stamp)"}}}"#
    }

    /// A stream that yields the fixture frames then idles open — like a
    /// live socket between tracker updates.
    private func stream(yielding frames: [String]) -> GazeStream {
        GazeStream(frames: {
            AsyncThrowingStream { continuation in
                for f in frames { continuation.yield(f) }
            }
        })
    }

    /// A yieldable frame source — lets a test push frames after start,
    /// like a live socket that talks when the tracker does.
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<String, Error>.Continuation?
        func stream() -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in
                lock.lock(); continuation = c; lock.unlock()
            }
        }
        func yield(_ frame: String) {
            lock.lock(); let live = continuation; lock.unlock()
            live?.yield(frame)
        }
    }

    private let saveButton = IntentCandidate(
        id: "ax:42:7:axel_9", kind: .axElement,
        frame: CGRect(x: 80, y: 80, width: 60, height: 30),
        motorRect: CGRect(x: 80, y: 80, width: 60, height: 30),
        role: "AXButton", label: "Save", pid: 42, windowID: 7,
        appName: "Test", windowTitle: "Doc")

    private func feed(_ source: Source, count: Int, x: Double = 100) async throws {
        for _ in 0..<count {
            source.yield(gazeFrame(x, 100))
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func fixture(stream: GazeStream, defaults: UserDefaults? = nil) -> GazeService {
        let suite = "GazeServiceTests." + UUID().uuidString
        let store = defaults ?? UserDefaults(suiteName: suite)!
        if defaults == nil { addTeardownBlock { store.removePersistentDomain(forName: suite) } }
        let service = GazeService(stream: stream, defaults: store)
        service.cursorPoint = { nil }
        service.eventSink = { _ in }; service.gazePointSink = { _ in }; service.staleSink = { _ in }
        service.labels = ImplicitLabeler(post: { _, _ in }, displayBounds: { nil })
        return service
    }

    /// A started service with a fresh sample scores the batch, emits
    /// the acquire, and answers commits through the scorer.
    func testServiceScoresAndCommits() async throws {
        let source = Source()
        let service = fixture(stream: GazeStream(frames: { source.stream() }))
        var enumerations = 0
        var events: [IntentEvent] = []
        var points: [CGPoint] = []
        service.enumerate = { _ in
            enumerations += 1
            return .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        service.eventSink = { events.append($0) }
        service.gazePointSink = { points.append($0) }
        service.dwellPolicy = DwellPolicy(mode: .off, deniedApps: [], userMultiplier: 1)
        service.start()
        defer { service.stop() }
        try await feed(source, count: 10)
        XCTAssertGreaterThanOrEqual(enumerations, 1)
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(events.contains {
            if case .acquire(let c) = $0 { return c.id == "ax:42:7:axel_9" }
            return false
        })
        let hit = await service.commitTarget()
        XCTAssertEqual(hit?.0.id, "ax:42:7:axel_9")
    }

    /// The gate: window change enumerates immediately; a parked gaze
    /// waits for the settle window; between signals nothing refetches.
    func testFeedGateCadence() {
        var gate = FeedGate()
        let p = CGPoint(x: 100, y: 100)
        // First sight of a window enumerates.
        XCTAssertTrue(gate.shouldEnumerate(point: p, saccade: false,
                                           windowUnder: 7, now: 0))
        // Same window, fresh fixation — the point moved past the radius,
        // the settle clock is ticking.
        XCTAssertFalse(gate.shouldEnumerate(point: CGPoint(x: 400, y: 400),
                                            saccade: false, windowUnder: 7, now: 0.5))
        XCTAssertTrue(gate.shouldEnumerate(point: CGPoint(x: 405, y: 400),
                                           saccade: false, windowUnder: 7, now: 0.7))
        // A saccade resets the settle clock — a fetch can't land
        // mid-flight on a point the eyes already left.
        XCTAssertFalse(gate.shouldEnumerate(point: CGPoint(x: 800, y: 400),
                                            saccade: true, windowUnder: 7, now: 0.8))
        XCTAssertFalse(gate.shouldEnumerate(point: CGPoint(x: 800, y: 400),
                                            saccade: false, windowUnder: 7, now: 0.85))
        // Parked in the new spot past settle → enumerate.
        XCTAssertTrue(gate.shouldEnumerate(point: CGPoint(x: 800, y: 400),
                                           saccade: false, windowUnder: 7, now: 1.0))
        // TTL: a steady fixation still refreshes.
        XCTAssertTrue(gate.shouldEnumerate(point: CGPoint(x: 800, y: 400),
                                           saccade: false, windowUnder: 7,
                                           now: 1.0 + FeedGate().refreshTTL + 0.1))
    }

    /// A dwell fire lands on the actuation seam once; the suppression
    /// gate and mode are the last line before anything moves.
    func testDwellFiresThroughActuation() async throws {
        let suite = "GazeServiceTests.dwell.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DwellPolicy(mode: .safe, deniedApps: [], userMultiplier: 1).save(to: defaults)
        let source = Source()
        let service = fixture(stream: GazeStream(frames: { source.stream() }), defaults: defaults)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        var furthestHold = 0.0
        service.eventSink = {
            if case .hold(_, let progress) = $0 { furthestHold = max(furthestHold, progress) }
        }
        service.gazePointSink = { _ in }
        var fired: [String] = []
        let landed = expectation(description: "explicit dwell actuation")
        landed.assertForOverFulfill = true
        service.actuate = { fired.append($0.id); landed.fulfill(); return true }
        service.dwellSuppressed = { false }
        let started = ProcessInfo.processInfo.systemUptime
        service.start()
        let feeder = Task { @MainActor in
            for _ in 0..<45 {
                source.yield(gazeFrame(100, 100))
                try await Task.sleep(for: .milliseconds(66))
            }
        }
        defer { feeder.cancel(); service.stop() }
        await fulfillment(of: [landed], timeout: 3)
        XCTAssertEqual(service.dwellPolicy.mode, .safe, "A different defaults domain must not replace explicit opt-in")
        XCTAssertGreaterThanOrEqual(furthestHold, 1, "The fixture must actually hold a fresh target long enough")
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(fired, ["ax:42:7:axel_9"])
    }

    /// Suppressed dwell — a parked ask or armed overlay — never fires.
    func testDwellSuppressed() async throws {
        let source = Source()
        let suite = "GazeServiceTests.suppressed." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DwellPolicy(mode: .safe, deniedApps: [], userMultiplier: 1).save(to: defaults)
        let service = fixture(stream: GazeStream(frames: { source.stream() }), defaults: defaults)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        var furthestHold = 0.0
        service.eventSink = {
            if case .hold(_, let progress) = $0 { furthestHold = max(furthestHold, progress) }
        }
        service.gazePointSink = { _ in }
        var fired: [String] = []
        service.actuate = { fired.append($0.id); return true }
        service.dwellSuppressed = { true }
        service.start()
        defer { service.stop() }
        try await feed(source, count: 36)
        XCTAssertGreaterThanOrEqual(furthestHold, 1)
        XCTAssertTrue(fired.isEmpty)
    }

    /// The referent context line a task gets — the live fixation's
    /// "Looking at" line once the focal gate has crossed.
    func testReferentContext() async throws {
        let source = Source()
        let service = fixture(stream: GazeStream(frames: { source.stream() }))
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        service.eventSink = { _ in }
        service.gazePointSink = { _ in }
        service.dwellPolicy = DwellPolicy(mode: .off, deniedApps: [], userMultiplier: 1)
        service.start()
        defer { service.stop() }
        // Past the focal gate (~180ms of argmax) — the referent exists.
        try await feed(source, count: 12)
        let context = await service.referentContext()
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Looking at:") == true)
        XCTAssertTrue(context?.contains("Save") == true)
    }

    /// A cold feed answers commits with nil — callers keep the
    /// raw-point fallback, never a guessed candidate.
    func testColdCommitIsNil() async {
        let service = fixture(stream: stream(yielding: []))
        service.start()
        defer { service.stop() }
        let hit = await service.commitTarget()
        XCTAssertNil(hit)
        let context = await service.referentContext()
        XCTAssertNil(context)
    }

    /// Stop drops the socket and clears scorer state — a commit after
    /// stop has no stale winner to return.
    func testStopClearsState() async throws {
        let source = Source()
        let stream = GazeStream(frames: { source.stream() })
        let service = fixture(stream: stream)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        service.eventSink = { _ in }
        service.gazePointSink = { _ in }
        service.start()
        try await feed(source, count: 10)
        let live = await service.commitTarget(recordSelection: false)
        XCTAssertNotNil(live)
        service.stop()
        try await Task.sleep(for: .milliseconds(80))
        let streaming = await stream.streaming
        XCTAssertFalse(streaming)
        let hit = await service.commitTarget()
        XCTAssertNil(hit)
    }

    /// Stop retires the ring before resetting — a .release on the live
    /// candidate so the overlay can play the shrink-back, then the
    /// teardown hook hard-clears whatever the events can't reach.
    func testStopRetiresRingAndCallsTeardown() async throws {
        let source = Source()
        let service = fixture(stream: GazeStream(frames: { source.stream() }))
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        var events: [IntentEvent] = []
        service.eventSink = { events.append($0) }
        service.gazePointSink = { _ in }
        var teardowns = 0
        service.overlayTeardown = { teardowns += 1 }
        service.start()
        defer { service.stop() }
        try await feed(source, count: 8)
        XCTAssertTrue(events.contains {
            if case .acquire = $0 { return true }; return false
        }, "need a live ring to retire — got \(events)")
        service.stop()
        XCTAssertEqual(teardowns, 1)
        XCTAssertTrue(events.contains {
            if case .release(let c) = $0 { return c.id == self.saveButton.id }
            return false
        }, "stop() must emit a terminal .release — got \(events)")
        // Idempotent: a second stop is a quiet .none, never a phantom
        // release of a candidate the first stop already retired.
        service.stop()
        XCTAssertEqual(teardowns, 2)
        if case .some(.none) = events.last {} else {
            XCTFail("second stop should emit .none — got \(String(describing: events.last))")
        }
    }

    /// While the feed is stale the sink hears the true outage duration
    /// on EVERY tick — stale-dim and halo-hide thresholds key on it —
    /// and a single 0 reports recovery.
    func testStaleSinkReportsOutageDuration() async throws {
        let source = Source()
        let service = fixture(
            stream: GazeStream(frames: { source.stream() }))
        var fakeT: TimeInterval = 100
        service.now = { fakeT }
        var reports: [TimeInterval] = []
        service.staleSink = { reports.append($0) }
        service.eventSink = { _ in }
        service.gazePointSink = { _ in }
        service.start()
        defer { service.stop() }
        // No frames yet — every tick is a stale tick at t=100.
        try await Task.sleep(for: .milliseconds(160))
        fakeT = 103.5
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(reports.contains { $0 < GazeSample.freshnessWindow },
                      "early reports are sub-threshold — got \(reports)")
        XCTAssertTrue(reports.contains { $0 > 2 },
                      "the outage duration must grow continuously — got \(reports)")
        // Recovery reports a single 0 — no more stale reports after it.
        source.yield(gazeFrame(100, 100))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reports.last, 0)
        let mark = reports.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reports.count, mark)
    }

    /// A Settings write re-reads the persisted policy — the defaults
    /// observer keeps the mode live instead of pinning the launch-time
    /// `.safe` forever.
    func testPolicyReloadsOnDefaultsChange() async throws {
        let key = DwellPolicy.modeKey
        let suite = "GazeServiceTests.policy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = fixture(stream: stream(yielding: []), defaults: defaults)
        service.eventSink = { _ in }
        service.gazePointSink = { _ in }
        service.staleSink = { _ in }
        service.start()
        defer { service.stop() }
        defaults.set("all", forKey: key)
        for _ in 0..<200 where service.dwellPolicy.mode != .all {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.dwellPolicy.mode, .all)
        defaults.set("off", forKey: key)
        for _ in 0..<200 where service.dwellPolicy.mode != .off {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.dwellPolicy.mode, .off)
    }
}
