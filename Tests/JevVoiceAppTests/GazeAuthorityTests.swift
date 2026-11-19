import XCTest
@testable import JevVoice

@MainActor
final class GazeAuthorityTests: XCTestCase {
    @MainActor private final class Fixture {
        let channel = AsyncThrowingStream<String, Error>.makeStream()
        let service: GazeService
        let suite = "GazeAuthorityTests." + UUID().uuidString
        let defaults: UserDefaults
        let button = IntentCandidate(id: "A", kind: .axElement,
                                     frame: CGRect(x: 80, y: 80, width: 40, height: 40),
                                     motorRect: CGRect(x: 80, y: 80, width: 40, height: 40),
                                     role: "AXButton", label: "Synthetic", windowID: 7)
        let iso = ISO8601DateFormatter()
        var effects: [IntentCandidate] = []

        @MainActor init() {
            defaults = UserDefaults(suiteName: suite)!
            DwellPolicy(mode: .safe, deniedApps: [], userMultiplier: 1).save(to: defaults)
            let frames = channel.stream
            service = GazeService(stream: GazeStream(frames: { frames }), defaults: defaults)
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            service.cursorPoint = { nil }
            service.windowIDUnder = { _ in 7 }
            service.eventSink = { _ in }
            service.gazePointSink = { _ in }
            service.staleSink = { _ in }
            service.dwellSuppressed = { false }
            service.labels = ImplicitLabeler(post: { _, _ in }, displayBounds: { nil })
            service.actuate = { [weak self] c in self?.effects.append(c); return false }
            service.enumerate = { [button] _ in
                var neighbor = button
                neighbor.id = "B"
                neighbor.frame = neighbor.frame.offsetBy(dx: 70, dy: 0)
                neighbor.motorRect = neighbor.frame
                return .init(candidates: [button, neighbor], windowID: 7)
            }
        }

        func send(_ x: Int, at stamp: Date = Date(), legacy: Bool = false) {
            let capture = legacy ? "" : #""captured_at_ms":\#(stamp.timeIntervalSince1970 * 1000),"#
            channel.continuation.yield(#"{"snapshot":{"gaze":{\#(capture)"x_px":\#(x),"y_px":100,"confidence":0.9,"updated_at":"\#(iso.string(from: Date()))","gaze_state":"fixation"}}}"#)
        }

        func feed(_ x: Int = 100, count: Int) async throws {
            for _ in 0..<count {
                send(x)
                try await Task.sleep(for: .milliseconds(45))
            }
        }

        func selection() async throws -> IntentCandidate {
            for _ in 0..<50 {
                try await feed(count: 1)
                if let (target, _) = await service.commitTarget(recordSelection: false) { return target }
            }
            return try XCTUnwrap(nil as IntentCandidate?, "continuous input never became selectable")
        }

        @MainActor func finish() {
            service.stop()
            channel.continuation.finish()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testHeldTimestampCannotRenewVoiceOrDwellAndContinuousLookCan() async throws {
        let f = Fixture()
        f.service.start()
        defer { f.finish() }
        let target = try await f.selection()
        XCTAssertEqual(f.service.currentActionLease, target.gazeLease)
        let live = await f.service.authorizes(target)
        XCTAssertTrue(live)
        let last = Date()
        for _ in 0..<26 {
            f.send(100, at: last)
            try await Task.sleep(for: .milliseconds(45))
        }
        let expired = await f.service.authorizes(target)
        let stale = await f.service.commitTarget(recordSelection: false)
        XCTAssertFalse(expired)
        XCTAssertNil(f.service.currentActionLease)
        XCTAssertNil(stale)
        XCTAssertTrue(f.effects.isEmpty)
        try await f.feed(count: 15)
        XCTAssertTrue(f.effects.isEmpty, "the stopped interval is not part of the new hold")
        for _ in 0..<80 where f.effects.isEmpty { try await f.feed(count: 1) }
        try await f.feed(count: 12)
        XCTAssertEqual(f.effects.map(\.id), ["A"])
        let old = await f.service.authorizes(target)
        XCTAssertFalse(old, "an older operation cannot borrow the reacquisition")
    }

    func testAdjacentExcursionAndOutOfOrderInputInvalidateIssuedTarget() async throws {
        let f = Fixture()
        f.service.start()
        defer { f.finish() }
        let first = try await f.selection()
        let stamp = Date()
        f.send(170, at: stamp.addingTimeInterval(-0.005))
        f.send(100, at: stamp)
        try await Task.sleep(for: .milliseconds(15))
        let excursion = await f.service.authorizes(first)
        XCTAssertFalse(excursion, "the neighboring observation between service ticks must count")
        let second = try await f.selection()
        XCTAssertNotEqual(first.gazeLease, second.gazeLease)
        f.send(100, at: stamp)
        try await Task.sleep(for: .milliseconds(20))
        let reordered = await f.service.authorizes(second)
        XCTAssertFalse(reordered)
        try await f.feed(count: 8)
        let canceled = Task { @MainActor in await f.service.commitTarget(recordSelection: false) }
        canceled.cancel()
        let hit = await canceled.value
        XCTAssertNil(hit)
        XCTAssertTrue(f.effects.isEmpty)
    }

    func testFreshReceiptDoesNotReviveStaleCaptureOrHeldFrame() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let base: [String: Any] = ["x_px": 100, "y_px": 100, "confidence": 0.9,
                                   "updated_at": stamp, "gaze_state": "fixation"]
        for (field, value, expected): (String, Any, GazeError) in [
            ("captured_at_ms", Date().addingTimeInterval(-3).timeIntervalSince1970 * 1000, .stale),
            ("held_reason", "no_face", .lowConfidence)
        ] {
            var wire = base
            wire[field] = value
            let bytes = try JSONSerialization.data(withJSONObject: wire)
            XCTAssertThrowsError(try GazeClient.decode(bytes)) { error in
                XCTAssertEqual(error as? GazeError, expected)
            }
        }
    }

    func testReceiptOnlyFramesRemainDisplayOnly() async throws {
        let f = Fixture()
        var points = 0
        f.service.gazePointSink = { _ in points += 1 }
        f.service.start()
        defer { f.finish() }
        for _ in 0..<42 {
            f.send(100, legacy: true)
            try await Task.sleep(for: .milliseconds(45))
        }
        let hit = await f.service.commitTarget(recordSelection: false)
        XCTAssertNil(hit)
        XCTAssertTrue(f.effects.isEmpty)
        XCTAssertTrue(points > 0)
    }

    func testAuthorizedPointIsTheCaptureNotAnOverlappedCenter() async throws {
        let f = Fixture()
        var wide = f.button
        wide.frame.size.width = 200
        wide.motorRect = wide.frame
        var other = f.button
        other.id = "overlap"
        other.motorRect = other.motorRect.offsetBy(dx: 90, dy: 0)
        other.frame = other.motorRect
        f.service.enumerate = { _ in .init(candidates: [wide, other], windowID: 7) }
        f.service.start()
        defer { f.finish() }
        let target = try await f.selection()
        let p = await f.service.authorizedPoint(for: target)
        XCTAssertEqual(p, CGPoint(x: 100, y: 100))
        let center = await f.service.authorizes(target, at: CGPoint(x: 180, y: 100))
        XCTAssertFalse(center)
    }

    func testAuthorityExpiresDuringWindowHitTest() async throws {
        let f = Fixture()
        f.service.start()
        defer { f.finish() }
        let target = try await f.selection()
        f.service.windowIDUnder = { _ in
            Thread.sleep(forTimeInterval: GazeStream.continuityWindow + 0.04)
            return 7
        }
        let point = await f.service.authorizedPoint(for: target)
        XCTAssertNil(point)
    }

    func testNewSourceRevisionDuringNativeTargetProofRevokesUnexpiredPoint() async throws {
        let f = Fixture()
        f.service.start()
        defer { f.finish() }
        let target = try await f.selection()
        let replaced = await f.service.authorizes(target, checkingTarget: { _ in false })
        XCTAssertFalse(replaced)
        let stream = f.service.stream
        let before = stream.liveObservations()
        var revokedInsideLookup = false
        let allowed = await f.service.authorizes(target) { _ in
            f.send(170)
            for _ in 0..<100 where stream.isCurrent(before) { Thread.sleep(forTimeInterval: 0.001) }
            revokedInsideLookup = !stream.isCurrent(before)
            return true
        }
        XCTAssertTrue(revokedInsideLookup)
        XCTAssertTrue(before.samples.last?.isFresh(within: GazeStream.continuityWindow) == true)
        XCTAssertNil(f.service.currentActionLease)
        XCTAssertFalse(allowed)
    }

    func testLateRosterFromPreviousRunCannotReplaceNewGeometry() async throws {
        let f = Fixture()
        var oldFetchStarted = false
        var oldFetchReturned = false
        let streams = AsyncThrowingStream<String, Error>.makeStream()
        let replacement = AsyncThrowingStream<String, Error>.makeStream()
        let channels = [streams.continuation, replacement.continuation]
        let sources = StreamPair(streams.stream, replacement.stream)
        let s = GazeService(stream: GazeStream(frames: { sources.next() }), defaults: f.defaults)
        s.labels = ImplicitLabeler(post: { _, _ in }, displayBounds: { nil })
        s.cursorPoint = { nil }; s.windowIDUnder = { _ in 7 }
        s.gazePointSink = { _ in }; s.staleSink = { _ in }; s.eventSink = { _ in }
        let old = f.button
        var new = old
        new.frame = new.frame.offsetBy(dx: 45, dy: 0)
        new.motorRect = new.frame
        s.enumerate = { _ in
            if !oldFetchStarted {
                oldFetchStarted = true
                try? await Task.sleep(for: .milliseconds(900))
                oldFetchReturned = true
                return .init(candidates: [old], windowID: 7)
            }
            return .init(candidates: [new], windowID: 7)
        }
        func send(_ x: Int, _ i: Int) {
            let capture = Date()
            channels[i].yield(#"{"snapshot":{"gaze":{"x_px":\#(x),"y_px":100,"confidence":0.9,"captured_at_ms":\#(capture.timeIntervalSince1970 * 1000),"updated_at":"\#(f.iso.string(from: capture))","gaze_state":"fixation"}}}"#)
        }
        defer { s.stop(); channels.forEach { $0.finish() }; f.finish() }
        s.start()
        for _ in 0..<20 where !oldFetchStarted {
            send(100, 0)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(oldFetchStarted)
        s.stop()
        s.start()
        for _ in 0..<27 {
            send(145, 1)
            try await Task.sleep(for: .milliseconds(45))
        }
        XCTAssertTrue(oldFetchReturned)
        let selected = await s.commitTarget(recordSelection: false)
        let current = try XCTUnwrap(selected?.0)
        XCTAssertEqual(current.motorRect, new.motorRect)
        XCTAssertEqual(s.batch.candidates, [new])
        var forged = current
        forged.motorRect = old.motorRect
        let altered = await s.authorizes(forged)
        XCTAssertFalse(altered)
    }

    private final class StreamPair: @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [AsyncThrowingStream<String, Error>]
        init(_ a: AsyncThrowingStream<String, Error>, _ b: AsyncThrowingStream<String, Error>) {
            streams = [a, b]
        }
        func next() -> AsyncThrowingStream<String, Error> {
            lock.lock()
            defer { lock.unlock() }
            return streams.removeFirst()
        }
    }
}
