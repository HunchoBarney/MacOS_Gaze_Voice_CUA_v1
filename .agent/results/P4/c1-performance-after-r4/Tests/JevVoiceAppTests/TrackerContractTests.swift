import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: `/snapshot/gaze` payloads in the exact shape
/// `externalStore.cjs` serves — `compactObject` over the renderer's
/// `type:"gaze"` message, snake_case wire names — decode through
/// `GazeClient.decode`'s gates. Freshness is checked before confidence,
/// missing coordinates are malformed, and the WS `{type:"update",
/// changed:[…], snapshot:{…}}` envelope lands in `GazeStream` through the
/// same decode the HTTP client uses.
final class TrackerContractTests: XCTestCase {

    /// The fractional ISO8601 `externalStore.cjs` stamps via
    /// `Date#toISOString()` (`store.now()`).
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// A gaze slice carrying every field the store's `updateFromBackendMessage`
    /// preserves for a `type:"gaze"` payload — the real wire shape, not a
    /// trimmed test double. `updated_at` is the store-side stamp.
    private func gazeSlice(x: Double = 580, y: Double = 740,
                           confidence: Double = 0.92,
                           state: String = "fixation",
                           age: TimeInterval = 0.1) -> [String: Any] {
        ["x_norm": 0.25, "y_norm": 0.5,
         "raw_x_norm": 0.24, "raw_y_norm": 0.51,
         "x_px": x, "y_px": y,
         "confidence": confidence,
         "distance_m": 0.68,
         "iris_distance_m": 0.011,
         "distance_source": "iris",
         "eye_open": 0.98,
         "gaze_filter": "saccade",
         "tracking_source": "iris",
         "filter_velocity_deg_s": 12.5,
         "gaze_state": state,
         "capture_ms": 33.2,
         "preview_ms": 5.1,
         "processed_fps": 29.7,
         "frame_interval_ms": 33.7,
         "head_face_width_ratio": 0.42,
         "eye_position_weight_x": 1.0,
         "eye_position_weight_y": 0.25,
         "gaze_projection_mode": "binocular-screen",
         "detect_inference_ms": 4.2,
         "gaze_inference_ms": 12.5,
         "inference_ms": 16.7,
         "yaw_deg": 3.1,
         "pitch_deg": -2.4,
         "updated_at": Self.iso.string(from: Date().addingTimeInterval(-age))]
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Decode: the good slice

    /// The full served slice decodes — every extra field the store
    /// preserves is ignored, not a malformed trip.
    func testFullServedSliceDecodes() throws {
        let sample = try GazeClient.decode(try json(gazeSlice()))
        XCTAssertEqual(sample.x, 580)
        XCTAssertEqual(sample.y, 740)
        XCTAssertEqual(sample.confidence, 0.92)
        XCTAssertEqual(sample.state, "fixation")
        XCTAssertNotNil(sample.updatedAt)
    }

    /// compactObject drops `undefined`, so a minimal slice — just what
    /// decode actually reads — is equally valid wire.
    func testMinimalSliceDecodes() throws {
        let slice: [String: Any] = [
            "x_px": 512, "y_px": 384,
            "confidence": 0.75, "gaze_state": "dwell",
            "updated_at": Self.iso.string(from: Date())
        ]
        let sample = try GazeClient.decode(try json(slice))
        XCTAssertEqual(sample.state, "dwell")
        XCTAssertEqual(sample.confidence, 0.75)
    }

    /// Whole-second ISO8601 parses through the no-fraction fallback.
    func testPlainIsoStampParses() throws {
        var slice = gazeSlice()
        slice["updated_at"] = Self.isoPlain.string(from: Date())
        let sample = try GazeClient.decode(try json(slice))
        XCTAssertNotNil(sample.updatedAt)
    }

    // MARK: - Decode: the gates

    /// A sample taken before the user finished the sentence throws
    /// `.stale` — acting on it clicks where they WERE.
    func testStaleSliceThrows() {
        XCTAssertThrowsError(try GazeClient.decode(try json(gazeSlice(age: 10)))) {
            XCTAssertEqual($0 as? GazeError, .stale)
        }
    }

    /// No stamp — or a stamp decode can't read — counts as stale, never
    /// as fresh.
    func testMissingOrGarbageStampThrowsStale() {
        var missing = gazeSlice()
        missing.removeValue(forKey: "updated_at")
        XCTAssertThrowsError(try GazeClient.decode(try json(missing))) {
            XCTAssertEqual($0 as? GazeError, .stale)
        }
        var garbage = gazeSlice()
        garbage["updated_at"] = "not-a-date"
        XCTAssertThrowsError(try GazeClient.decode(try json(garbage))) {
            XCTAssertEqual($0 as? GazeError, .stale)
        }
    }

    /// Without screen coordinates there is no sample at all.
    func testMissingCoordinatesThrowMalformed() {
        for key in ["x_px", "y_px"] {
            var slice = gazeSlice()
            slice.removeValue(forKey: key)
            XCTAssertThrowsError(try GazeClient.decode(try json(slice)), key) {
                XCTAssertEqual($0 as? GazeError, .malformed)
            }
        }
        // A string coordinate is not a number — still malformed.
        var stringX = gazeSlice()
        stringX["x_px"] = "580"
        XCTAssertThrowsError(try GazeClient.decode(try json(stringX))) {
            XCTAssertEqual($0 as? GazeError, .malformed)
        }
        XCTAssertThrowsError(try GazeClient.decode(Data("[1,2]".utf8))) {
            XCTAssertEqual($0 as? GazeError, .malformed)
        }
    }

    /// Below the tracker's own floor the point is refused; at the floor
    /// it passes — the gate is inclusive.
    func testConfidenceGateIsInclusiveFloor() throws {
        XCTAssertThrowsError(try GazeClient.decode(try json(gazeSlice(confidence: 0.39)))) {
            XCTAssertEqual($0 as? GazeError, .lowConfidence)
        }
        var missing = gazeSlice()
        missing.removeValue(forKey: "confidence")
        XCTAssertThrowsError(try GazeClient.decode(try json(missing))) {
            XCTAssertEqual($0 as? GazeError, .lowConfidence)
        }
        XCTAssertNoThrow(try GazeClient.decode(try json(gazeSlice(confidence: 0.4))))
    }

    /// Freshness is checked FIRST — a stale low-confidence sample reads
    /// `.stale`, matching the order the spoken errors prefer.
    func testStaleOutranksLowConfidence() {
        XCTAssertThrowsError(
            try GazeClient.decode(try json(gazeSlice(confidence: 0.1, age: 9)))) {
            XCTAssertEqual($0 as? GazeError, .stale)
        }
    }

    // MARK: - Client end-to-end through the fetch seam

    /// `snapshot()` fetches `/snapshot/gaze` and runs the same decode.
    func testSnapshotDecodesThroughFetch() async throws {
        final class RequestLog { var urls: [URL] = [] }
        let log = RequestLog()
        let data = try json(gazeSlice(x: 111, y: 222, state: "saccade"))
        let client = GazeClient(fetch: { url in
            log.urls.append(url)
            return data
        })
        let sample = try await client.snapshot()
        XCTAssertEqual(sample.x, 111)
        XCTAssertEqual(sample.state, "saccade")
        XCTAssertEqual(log.urls.map(\.path), ["/snapshot/gaze"])
    }

    /// A dead tracker reads unreachable; a malformed answer propagates
    /// the decode verdict — never a guessed point.
    func testSnapshotFailureModes() async {
        let down = GazeClient(fetch: { _ in throw URLError(.cannotConnectToHost) })
        do {
            _ = try await down.snapshot()
            XCTFail("expected unreachable")
        } catch {
            XCTAssertEqual(error as? GazeError, .unreachable)
        }
        let garbage = GazeClient(fetch: { _ in Data("oops".utf8) })
        do {
            _ = try await garbage.snapshot()
            XCTFail("expected malformed")
        } catch {
            XCTAssertEqual(error as? GazeError, .malformed)
        }
    }

    // MARK: - WS envelope through GazeStream

    private func feed(_ frames: [String]) -> @Sendable () -> AsyncThrowingStream<String, Error> {
        {
            AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            }
        }
    }

    /// Poll `latest()` — the pump is a Task behind an actor (same posture
    /// as GazeStreamTests).
    private func awaitLatest(_ stream: GazeStream,
                             where predicate: (GazeSample?) -> Bool = { $0 != nil }) async -> GazeSample? {
        var sample = await stream.latest()
        for _ in 0..<200 where !predicate(sample) {
            try? await Task.sleep(for: .milliseconds(10))
            sample = await stream.latest()
        }
        return sample
    }

    /// The exact event the tracker's /events socket emits on change —
    /// `{type:"update", changed:[slices], snapshot:{full state}}` — feeds
    /// the whole snapshot envelope; the gaze slice inside decodes.
    func testUpdateEnvelopeFeedsStream() async throws {
        let snapshot: [String: Any] = [
            "schema_version": 1,
            "started_at": "2026-06-21T00:00:00.000Z",
            "updated_at": Self.iso.string(from: Date()),
            "runtime": ["name": "onnxweb", "accelerator": "webgpu"],
            "display": ["display_index": 1, "display_count": 2,
                        "bounds": ["x": 100, "y": 200, "width": 1920, "height": 1080],
                        "display_size_inch": 31.5],
            "camera": ["camera": "0", "camera_fov_deg": 90],
            "status": ["level": "info", "message": "Models loaded"],
            "paused": false,
            "gaze": gazeSlice(x: 640, y: 360, state: "saccade")
        ]
        let frame = String(data: try json([
            "type": "update",
            "changed": ["gaze"],
            "snapshot": snapshot
        ]), encoding: .utf8)!

        let stream = GazeStream(frames: feed([frame]))
        await stream.start()
        let sample = await awaitLatest(stream) { $0?.x == 640 }
        XCTAssertEqual(sample?.x, 640)
        XCTAssertEqual(sample?.y, 360)
        XCTAssertEqual(sample?.state, "saccade")
        XCTAssertEqual(sample?.confidence, 0.92)
        await stream.stop()
    }

    /// The connect handshake `{type:"snapshot", snapshot:{…}}` carries the
    /// same envelope — a gated sample inside (stale) must not land.
    func testSnapshotHandshakeStillGated() async throws {
        let frame = String(data: try json([
            "type": "snapshot",
            "snapshot": ["gaze": gazeSlice(x: 50, y: 60, age: 30)]
        ]), encoding: .utf8)!
        let stream = GazeStream(frames: feed([frame]))
        await stream.start()
        try? await Task.sleep(for: .milliseconds(200))
        let sample = await stream.latest()
        XCTAssertNil(sample, "a stale handshake gaze must die in decode")
        await stream.stop()
    }
}
