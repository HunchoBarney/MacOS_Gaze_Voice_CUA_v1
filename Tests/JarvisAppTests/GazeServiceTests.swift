import XCTest
@testable import Jarvis
import JarvisCore

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

    /// One gaze frame in the `/events` wire shape, stamped at `at`.
    private func gazeFrame(_ x: Double, _ y: Double,
                           state: String = "fixation", at: Date = Date()) -> String {
        let stamp = Self.iso.string(from: at)
        return #"{"type":"snapshot","snapshot":{"gaze":{"x_px":\#(x),"y_px":\#(y),"confidence":0.9,"gaze_state":"\#(state)","updated_at":"\#(stamp)"}}}"#
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
    /// Frames yielded before the stream opens are held and delivered
    /// once it does, so a test never races the service's socket start.
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<String, Error>.Continuation?
        private var held: [String] = []
        func stream() -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in
                lock.lock(); continuation = c; let early = held; held = []; lock.unlock()
                for frame in early { c.yield(frame) }
            }
        }
        func yield(_ frame: String) {
            lock.lock()
            let live = continuation
            if live == nil { held.append(frame) }
            lock.unlock()
            live?.yield(frame)
        }
    }

    /// One fake clock for a hand-pumped service: `t` drives its
    /// monotonic clock and, from a fixed epoch, its wall clock.
    @MainActor
    private final class ManualClock {
        static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        var t: TimeInterval = 0
        var wall: Date { Self.epoch.addingTimeInterval(t) }

        func drive(_ service: GazeService) {
            service.pumpsAutomatically = false
            service.now = { [unowned self] in self.t }
            service.wallClock = { [unowned self] in self.wall }
        }

        /// One tracker frame later (15 Hz), then one pump step.
        func tick(_ service: GazeService, times: Int = 1) async {
            for _ in 0..<times {
                t += 1.0 / 15
                await service.tickForTest()
            }
        }
    }

    /// Waits on the stream's own sample signal until it has ingested past
    /// `seen` — no sleeping or polling on real time.
    private func ingested(_ stream: GazeStream, beyond seen: Int) async {
        var current = await stream.sequence
        for _ in 0..<5 where current <= seen {
            current = await stream.waitForSample(after: seen, timeout: .seconds(5))
        }
        XCTAssertGreaterThan(current, seen, "the stream never ingested the frame")
    }

    /// One frame stamped at `at`, delivered and ingested before returning.
    private func feed(_ source: Source, _ stream: GazeStream, at: Date) async {
        let seen = await stream.sequence
        source.yield(gazeFrame(100, 100, at: at))
        await ingested(stream, beyond: seen)
    }

    private let saveButton = IntentCandidate(
        id: "ax:42:7:axel_9", kind: .axElement,
        frame: CGRect(x: 80, y: 80, width: 60, height: 30),
        motorRect: CGRect(x: 80, y: 80, width: 60, height: 30),
        role: "AXButton", label: "Save", pid: 42, windowID: 7,
        appName: "Test", windowTitle: "Doc")

    /// Polls until `condition` holds or about two seconds pass. A fixed
    /// sleep misses the first tick's acquire when the suite runs under
    /// --parallel load; a deadline only waits as long as it must.
    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func acquired(_ events: [IntentEvent]) -> Bool {
        events.contains { if case .acquire = $0 { return true }; return false }
    }

    /// A started service with a fresh sample scores the batch, emits
    /// the acquire, and answers commits through the scorer.
    func testServiceScoresAndCommits() async throws {
        let clock = ManualClock()
        let frames = stream(yielding: [gazeFrame(100, 100, at: clock.wall)])
        let service = GazeService(stream: frames)
        clock.drive(service)
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
        service.cursorPoint = { nil }
        service.dwellPolicy = DwellPolicy(mode: .off, deniedApps: [], userMultiplier: 1)
        service.start()
        defer { service.stop() }
        await ingested(frames, beyond: 0)
        await clock.tick(service, times: 6)
        XCTAssertGreaterThanOrEqual(enumerations, 1)
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(events.contains {
            if case .acquire(let c) = $0 { return c.id == "ax:42:7:axel_9" }
            return false
        })
        let hit = await service.commitTarget()
        XCTAssertEqual(hit?.0.id, "ax:42:7:axel_9")
    }

    /// The scorer's σ reaches the highlight before the first event, so
    /// the ring's lock gate never judges a control by a stale band.
    func testSigmaReachesTheHighlightBeforeTheFirstEvent() async throws {
        let clock = ManualClock()
        let frames = stream(yielding: [gazeFrame(100, 100, at: clock.wall)])
        let service = GazeService(stream: frames,
                                  scorer: GazeIntentScorer(config: .init(sigmaPx: 384)))
        clock.drive(service)
        var log: [String] = []
        service.enumerate = { _ in .init(candidates: [self.saveButton], windowID: 7) }
        service.windowIDUnder = { _ in 7 }
        service.sigmaSink = { log.append("sigma \(Int($0))") }
        service.eventSink = { _ in log.append("event") }
        service.cursorPoint = { nil }
        service.dwellPolicy = DwellPolicy(mode: .off, deniedApps: [], userMultiplier: 1)
        service.start()
        defer { service.stop() }
        await ingested(frames, beyond: 0)
        await clock.tick(service)
        XCTAssertTrue(log.contains("event"))
        XCTAssertEqual(log.first, "sigma 384")
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
        let frames = GazeStream(frames: { source.stream() })
        let service = GazeService(stream: frames,
                                  scorer: GazeIntentScorer(config: .init(sigmaPx: 40)),
                                  defaults: defaults)
        let clock = ManualClock()
        clock.drive(service)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        var furthestHold = 0.0
        service.eventSink = {
            if case .hold(_, let progress) = $0 { furthestHold = max(furthestHold, progress) }
        }
        service.sigmaSink = { _ in }
        service.gazePointSink = { _ in }
        service.cursorPoint = { nil }
        var fired: [String] = []
        service.actuate = { fired.append($0.id); return true }
        service.dwellSuppressed = { false }
        service.start()
        defer { service.stop() }
        for _ in 0..<45 {
            await feed(source, frames, at: clock.wall)
            await clock.tick(service)
        }
        XCTAssertEqual(service.dwellPolicy.mode, .safe, "A different defaults domain must not replace explicit opt-in")
        XCTAssertGreaterThanOrEqual(furthestHold, 1, "The fixture must actually hold a fresh target long enough")
        XCTAssertGreaterThanOrEqual(clock.t, 1)
        XCTAssertEqual(fired, ["ax:42:7:axel_9"])
    }

    /// Dwell never clicks a target the ring refused to lock onto: at
    /// σ 384 a 60×30 button shows no ring and no countdown, so a fire
    /// there would land without warning.
    func testDwellNeverFiresWhereTheRingCannotLock() async throws {
        let suite = "GazeServiceTests.dwellGate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DwellPolicy(mode: .safe, deniedApps: [], userMultiplier: 1).save(to: defaults)
        let source = Source()
        let frames = GazeStream(frames: { source.stream() })
        let service = GazeService(stream: frames,
                                  scorer: GazeIntentScorer(config: .init(sigmaPx: 384)),
                                  defaults: defaults)
        let clock = ManualClock()
        clock.drive(service)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        var furthestHold = 0.0
        service.eventSink = {
            if case .hold(_, let progress) = $0 { furthestHold = max(furthestHold, progress) }
        }
        service.sigmaSink = { _ in }
        service.gazePointSink = { _ in }
        service.cursorPoint = { nil }
        var fired: [String] = []
        service.actuate = { fired.append($0.id); return true }
        service.dwellSuppressed = { false }
        service.start()
        defer { service.stop() }
        for _ in 0..<45 {
            await feed(source, frames, at: clock.wall)
            await clock.tick(service)
        }
        XCTAssertGreaterThanOrEqual(furthestHold, 1, "The fixture must actually hold the target long enough")
        XCTAssertTrue(fired.isEmpty)
    }

    /// The answer or guide halo stands the ring down, so dwell has no
    /// countdown on screen while it shows and must not click.
    func testDwellNeverFiresWhileTheHaloHoldsTheRingDown() async throws {
        let suite = "GazeServiceTests.dwellHalo.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DwellPolicy(mode: .safe, deniedApps: [], userMultiplier: 1).save(to: defaults)
        let source = Source()
        let frames = GazeStream(frames: { source.stream() })
        let service = GazeService(stream: frames,
                                  scorer: GazeIntentScorer(config: .init(sigmaPx: 40)),
                                  defaults: defaults)
        let clock = ManualClock()
        clock.drive(service)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        var furthestHold = 0.0
        service.eventSink = {
            if case .hold(_, let progress) = $0 { furthestHold = max(furthestHold, progress) }
        }
        service.sigmaSink = { _ in }
        service.gazePointSink = { _ in }
        service.cursorPoint = { nil }
        service.haloShowing = { true }
        var fired: [String] = []
        service.actuate = { fired.append($0.id); return true }
        service.dwellSuppressed = { false }
        service.start()
        defer { service.stop() }
        for _ in 0..<45 {
            await feed(source, frames, at: clock.wall)
            await clock.tick(service)
        }
        XCTAssertGreaterThanOrEqual(furthestHold, 1, "The fixture must actually hold the target long enough")
        XCTAssertTrue(fired.isEmpty)
    }

    /// Suppressed dwell — a parked ask or armed overlay — never fires.
    func testDwellSuppressed() async throws {
        let source = Source()
        let frames = GazeStream(frames: { source.stream() })
        let service = GazeService(stream: frames)
        let clock = ManualClock()
        clock.drive(service)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        service.eventSink = { _ in }
        service.gazePointSink = { _ in }
        service.cursorPoint = { nil }
        var fired: [String] = []
        service.actuate = { fired.append($0.id); return true }
        service.dwellSuppressed = { true }
        service.dwellPolicy = DwellPolicy(mode: .safe, deniedApps: [],
                                        userMultiplier: 1)
        service.start()
        defer { service.stop() }
        for _ in 0..<17 {
            await feed(source, frames, at: clock.wall)
            await clock.tick(service)
        }
        XCTAssertGreaterThanOrEqual(clock.t, 1.1)
        XCTAssertTrue(fired.isEmpty)
    }

    /// The referent context line a task gets — the live fixation's
    /// "Looking at" line once the focal gate has crossed.
    func testReferentContext() async throws {
        let clock = ManualClock()
        let frames = stream(yielding: [gazeFrame(100, 100, at: clock.wall)])
        let service = GazeService(stream: frames)
        clock.drive(service)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        service.eventSink = { _ in }
        service.gazePointSink = { _ in }
        service.cursorPoint = { nil }
        service.dwellPolicy = DwellPolicy(mode: .off, deniedApps: [], userMultiplier: 1)
        service.start()
        defer { service.stop() }
        await ingested(frames, beyond: 0)
        // Past the focal gate (~180ms of argmax) — the referent exists.
        await clock.tick(service, times: 8)
        let context = await service.referentContext()
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Looking at:") == true)
        XCTAssertTrue(context?.contains("Save") == true)
    }

    /// A cold feed answers commits with nil — callers keep the
    /// raw-point fallback, never a guessed candidate.
    func testColdCommitIsNil() async {
        let service = GazeService(stream: stream(yielding: []))
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
        let stream = stream(yielding: [gazeFrame(100, 100)])
        let service = GazeService(stream: stream)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        var events: [IntentEvent] = []
        service.eventSink = { events.append($0) }
        service.gazePointSink = { _ in }
        service.cursorPoint = { nil }
        service.start()
        try await eventually { Self.acquired(events) }
        XCTAssertTrue(Self.acquired(events), "need a scored winner to clear — got \(events)")
        service.stop()
        try await eventually { !(await stream.streaming) }
        let streaming = await stream.streaming
        XCTAssertFalse(streaming)
        let hit = await service.commitTarget()
        XCTAssertNil(hit)
    }

    /// Stop retires the ring before resetting — a .release on the live
    /// candidate so the overlay can play the shrink-back, then the
    /// teardown hook hard-clears whatever the events can't reach.
    func testStopRetiresRingAndCallsTeardown() async throws {
        let clock = ManualClock()
        let frames = stream(yielding: [gazeFrame(100, 100, at: clock.wall)])
        let service = GazeService(stream: frames)
        clock.drive(service)
        service.enumerate = { _ in
            .init(candidates: [self.saveButton], windowID: 7)
        }
        service.windowIDUnder = { _ in 7 }
        var events: [IntentEvent] = []
        service.eventSink = { events.append($0) }
        service.gazePointSink = { _ in }
        service.cursorPoint = { nil }
        var teardowns = 0
        service.overlayTeardown = { teardowns += 1 }
        service.start()
        defer { service.stop() }
        await ingested(frames, beyond: 0)
        await clock.tick(service, times: 6)
        XCTAssertTrue(Self.acquired(events), "need a live ring to retire — got \(events)")
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
        let frames = GazeStream(frames: { source.stream() })
        let service = GazeService(stream: frames)
        let clock = ManualClock()
        clock.t = 100
        clock.drive(service)
        var reports: [TimeInterval] = []
        service.staleSink = { reports.append($0) }
        service.eventSink = { _ in }
        service.gazePointSink = { _ in }
        service.start()
        defer { service.stop() }
        // No frames yet — every tick is a stale tick.
        await service.tickForTest()
        clock.t = 103.5
        await service.tickForTest()
        XCTAssertTrue(reports.contains { $0 < GazeSample.freshnessWindow },
                      "early reports are sub-threshold — got \(reports)")
        XCTAssertTrue(reports.contains { $0 > 2 },
                      "the outage duration must grow continuously — got \(reports)")
        // Recovery reports a single 0 — no more stale reports after it.
        await feed(source, frames, at: clock.wall)
        await clock.tick(service)
        XCTAssertEqual(reports.last, 0)
        let mark = reports.count
        await clock.tick(service, times: 3)
        XCTAssertEqual(reports.count, mark)
    }

    /// A loaded Mac stalls the test between ticks: real seconds pass, but
    /// freshness and the outage clock read only the injected clocks, so
    /// a sample stays fresh until the test moves the clock and the stale
    /// reports come out exactly as stepped.
    func testStaleReportsIgnoreRealTimeBetweenTicks() async throws {
        let source = Source()
        let frames = GazeStream(frames: { source.stream() })
        let service = GazeService(stream: frames)
        let clock = ManualClock()
        clock.t = 100
        clock.drive(service)
        var reports: [TimeInterval] = []
        service.staleSink = { reports.append($0) }
        service.eventSink = { _ in }
        service.gazePointSink = { _ in }
        service.start()
        defer { service.stop() }
        await feed(source, frames, at: clock.wall)
        await service.tickForTest()
        try await Task.sleep(for: .seconds(2))
        await service.tickForTest()
        XCTAssertEqual(reports, [], "a stalled test must not age the sample")
        clock.t = 101.6
        await service.tickForTest()
        try await Task.sleep(for: .seconds(2))
        await service.tickForTest()
        await service.tickForTest()
        XCTAssertEqual(reports.count, 3, "got \(reports)")
        for r in reports { XCTAssertEqual(r, 1.6, accuracy: 0.001) }
    }

    /// A Settings write re-reads the persisted policy — the defaults
    /// observer keeps the mode live instead of pinning the launch-time
    /// `.safe` forever.
    func testPolicyReloadsOnDefaultsChange() async throws {
        let key = DwellPolicy.modeKey
        let suite = "GazeServiceTests.reload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = GazeService(stream: stream(yielding: []), defaults: defaults)
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
