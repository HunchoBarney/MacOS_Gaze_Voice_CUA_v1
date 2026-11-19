import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: the tracker's `/events` socket feeds every frame through the
/// same gates `GazeClient.decode` enforces — malformed JSON, stale stamps
/// and low-confidence samples never reach `latest()`; the last GOOD
/// sample wins. `start()` swaps pumps (never doubles them) and `stop()`
/// cancels the consumer — the same signal that hangs up the real socket.
final class GazeStreamTests: XCTestCase {

    /// Scriptable frame source standing in for the WebSocket. Counts how
    /// many streams `start()` opened (one per pump — proves starts never
    /// double-pump) and observes `onTermination`, the same hook the
    /// production socket uses to cancel the URLSessionWebSocketTask.
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncThrowingStream<String, Error>.Continuation] = [:]
        private var _openCount = 0
        private var _terminatedCount = 0

        var openCount: Int { lock.lock(); defer { lock.unlock() }; return _openCount }
        var terminatedCount: Int { lock.lock(); defer { lock.unlock() }; return _terminatedCount }

        func stream() -> AsyncThrowingStream<String, Error> {
            let id = UUID()
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self.continuations.removeValue(forKey: id)
                    self._terminatedCount += 1
                    self.lock.unlock()
                }
                self.lock.lock()
                self.continuations[id] = continuation
                self._openCount += 1
                self.lock.unlock()
            }
        }

        func yield(_ frame: String) {
            lock.lock()
            let live = Array(continuations.values)
            lock.unlock()
            for continuation in live { continuation.yield(frame) }
        }
    }

    private actor Received {
        var frame: String?
        func record(_ value: String) { frame = value }
    }

    /// The decoder's clock — same fractional ISO8601 the tracker emits.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One gaze slice in the wire shape `snapshot.gaze` carries — same
    /// field names `GazeClient.decode` parses.
    private func gaze(_ x: Double, _ y: Double, confidence: Double = 0.9,
                      state: String = "fixation", age: TimeInterval = 0.1) -> String {
        let stamp = Self.iso.string(from: Date().addingTimeInterval(-age))
        return #"{"x_px":\#(x),"y_px":\#(y),"confidence":\#(confidence),"gaze_state":"\#(state)","updated_at":"\#(stamp)"}"#
    }

    private func snapshotFrame(_ gaze: String) -> String {
        #"{"type":"snapshot","snapshot":{"gaze":\#(gaze)}}"#
    }

    private func updateFrame(_ gaze: String) -> String {
        #"{"type":"update","changed":["gaze"],"snapshot":{"gaze":\#(gaze)}}"#
    }

    /// A finite canned feed — one buffered stream, already finished,
    /// like a socket that delivered its frames and hung up.
    private func feed(_ frames: [String]) -> @Sendable () -> AsyncThrowingStream<String, Error> {
        {
            AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            }
        }
    }

    /// Poll `latest()` until the predicate holds — the pump is a Task
    /// behind an actor, so assertions wait on it instead of racing it.
    @discardableResult
    private func awaitLatest(_ stream: GazeStream,
                             where predicate: (GazeSample?) -> Bool = { $0 != nil }) async -> GazeSample? {
        var sample = await stream.latest()
        for _ in 0..<200 where !predicate(sample) {
            try? await Task.sleep(for: .milliseconds(10))
            sample = await stream.latest()
        }
        return sample
    }

    /// The connect handshake and later updates both carry the gaze
    /// slice; the newest good update is what `latest()` reports, and a
    /// trailing garbage frame can't corrupt it.
    func testSnapshotThenUpdateKeepsNewestGoodSample() async {
        let stream = GazeStream(frames: feed([
            snapshotFrame(gaze(100, 200)),
            updateFrame(gaze(300, 400)),
            "this is not json",
        ]))
        await stream.start()
        let sample = await awaitLatest(stream) { $0?.x == 300 }
        XCTAssertEqual(sample?.x, 300)
        XCTAssertEqual(sample?.y, 400)
        XCTAssertEqual(sample?.confidence, 0.9)
        XCTAssertEqual(sample?.state, "fixation")
        await stream.stop()
    }

    /// The gaze pump parks on `waitForSample`: a new good sample wakes it
    /// at once (no fixed poll between the tracker and the highlight), and
    /// with nothing new it returns after the timeout with the same count.
    func testWaitForSampleWakesOnArrivalAndTimesOutWithout() async {
        let source = Source()
        let stream = GazeStream(frames: { source.stream() })
        await stream.start()
        let idle = await stream.waitForSample(after: 0, timeout: .milliseconds(30))
        XCTAssertEqual(idle, 0)
        async let woke = stream.waitForSample(after: 0, timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        let sent = ContinuousClock.now
        source.yield(updateFrame(gaze(10, 20)))
        let seen = await woke
        XCTAssertEqual(seen, 1)
        XCTAssertLessThan(ContinuousClock.now - sent, .seconds(1))
        let already = await stream.waitForSample(after: 0, timeout: .seconds(5))
        XCTAssertEqual(already, 1, "a reader behind the count returns without waiting")
        await stream.stop()
    }

    /// Garbage between good frames is dropped — a malformed frame never
    /// clears or corrupts the latest sample.
    func testMalformedFramesAreIgnored() async {
        let stream = GazeStream(frames: feed([
            "not json",
            #"{"type":"update","changed":["gaze"]}"#, // update with no snapshot
            #"["arrays","too"]"#,
            updateFrame(gaze(50, 60)),
        ]))
        await stream.start()
        let sample = await awaitLatest(stream) { $0?.x == 50 }
        XCTAssertEqual(sample?.x, 50)
        XCTAssertEqual(sample?.y, 60)
        await stream.stop()
    }

    /// A feed with no usable gaze slice leaves `latest()` nil — noise
    /// never invents a sample.
    func testNoGazeLeavesLatestNil() async {
        let stream = GazeStream(frames: feed(["junk", #"{"type":"update"}"#]))
        await stream.start()
        // The whole feed is already buffered; give the pump a moment to
        // drain it before asserting silence — microseconds of real work.
        try? await Task.sleep(for: .milliseconds(200))
        let sample = await stream.latest()
        XCTAssertNil(sample)
        await stream.stop()
    }

    /// A stale update (decode throws .stale) must not overwrite the last
    /// good sample — the reader keeps where the user IS, not where they
    /// were before a tracker hiccup.
    func testStaleSampleNeverOverwritesFresh() async {
        let stream = GazeStream(frames: feed([
            updateFrame(gaze(300, 400)),
            updateFrame(gaze(1, 1, age: 3)),
        ]))
        await stream.start()
        let first = await awaitLatest(stream) { $0?.x == 300 }
        XCTAssertEqual(first?.x, 300)
        // The stale frame was buffered behind the good one — the pump
        // drains it within microseconds. Settle, then confirm it dropped.
        try? await Task.sleep(for: .milliseconds(250))
        let after = await stream.latest()
        XCTAssertEqual(after?.x, 300, "a 3s-old sample must die in decode")
        XCTAssertEqual(after?.y, 400)
        await stream.stop()
    }

    /// Same gate for tracker self-doubt: confidence below the floor
    /// (decode throws .lowConfidence) never reaches the reader.
    func testLowConfidenceSampleNeverOverwritesFresh() async {
        let stream = GazeStream(frames: feed([
            updateFrame(gaze(300, 400)),
            updateFrame(gaze(9, 9, confidence: 0.1)),
        ]))
        await stream.start()
        let first = await awaitLatest(stream) { $0?.x == 300 }
        XCTAssertEqual(first?.x, 300)
        try? await Task.sleep(for: .milliseconds(250))
        let after = await stream.latest()
        XCTAssertEqual(after?.x, 300, "a distrusted sample must die in decode")
        await stream.stop()
    }

    /// Tracker fixation states pass through untouched — dwell
    /// hit-testing downstream reads `state` verbatim.
    func testDwellStatePassesThrough() async {
        let stream = GazeStream(frames: feed([updateFrame(gaze(7, 8, state: "dwell"))]))
        await stream.start()
        let sample = await awaitLatest(stream)
        XCTAssertEqual(sample?.state, "dwell")
        XCTAssertEqual(sample?.x, 7)
        XCTAssertEqual(sample?.y, 8)
        await stream.stop()
    }

    /// Each start opens one source and cancellation retires the old source.
    /// Scheduling may overlap startup/teardown, but only one pump survives.
    func testStartSwapsPumpNeverDoubles() async {
        let source = Source()
        let stream = GazeStream(frames: { source.stream() })
        await stream.start()
        await stream.start()
        for _ in 0..<200 where source.openCount < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(source.openCount, 2, "each start opens exactly one source")
        for _ in 0..<200 where source.terminatedCount < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(source.terminatedCount, 1,
                       "the replaced pump's stream must terminate")
        // The surviving pump still ingests. Re-yield inside the window —
        // under suite load the second pump's first next() can lag the
        // first yield; a dead pump fails regardless of how many frames land.
        var sample = await stream.latest()
        for _ in 0..<400 where sample?.x != 9 {
            source.yield(updateFrame(gaze(9, 9)))
            try? await Task.sleep(for: .milliseconds(10))
            sample = await stream.latest()
        }
        XCTAssertEqual(sample?.x, 9)
        await stream.stop()
    }

    func testSourceBroadcastReachesSurvivorAfterNewestStreamTerminates() async {
        let source = Source()
        let survivor = source.stream()
        let newest = source.stream()
        let cancelled = Task {
            var iterator = newest.makeAsyncIterator()
            _ = try? await iterator.next()
        }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(source.terminatedCount, 1)
        let received = Received()
        let live = Task {
            var iterator = survivor.makeAsyncIterator()
            if let frame = try? await iterator.next() { await received.record(frame) }
        }
        source.yield("frame-9")
        for _ in 0..<200 {
            if await received.frame == "frame-9" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let frame = await received.frame
        XCTAssertEqual(frame, "frame-9")
        live.cancel()
        await live.value
    }

    /// `stop()` cancels the consuming task — the frame stream's
    /// `onTermination` fires, the same hook that hangs up the real
    /// `URLSessionWebSocketTask`.
    func testStopTerminatesTheConsumer() async {
        let source = Source()
        let stream = GazeStream(frames: { source.stream() })
        await stream.start()
        for _ in 0..<200 where source.openCount < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(source.openCount, 1)
        source.yield(updateFrame(gaze(5, 5)))
        let sample = await awaitLatest(stream) { $0?.x == 5 }
        XCTAssertEqual(sample?.x, 5)
        await stream.stop()
        for _ in 0..<200 where source.terminatedCount < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(source.terminatedCount, 1,
                       "stop() must cancel the pump — onTermination hangs up the socket")
    }
}
