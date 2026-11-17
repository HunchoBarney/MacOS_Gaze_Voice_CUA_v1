import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: `TrackerHost.wedgeSignal` is the single classification every
/// watch-loop verdict goes through — ONLY a real dead-inference signature
/// may escalate to wasm. Errors a respawn can't fix (camera denied, model
/// fetch failed, init blew up) stay `.healthy`, and a paused pipeline's
/// silence is intentional, never `.stalled`. The camera-denial case is the
/// bug that shipped: a NotAllowedError must never read as a wedge.
final class TrackerWedgeSignatureTests: XCTestCase {

    private func signal(_ snapshot: [String: Any],
                        gazeIsFresh: Bool = true) -> TrackerHost.WedgeSignal {
        TrackerHost.wedgeSignal(for: snapshot, gazeIsFresh: gazeIsFresh)
    }

    private func errorStatus(_ message: String?,
                             level: String = "error") -> [String: Any] {
        var status: [String: Any] = ["level": level, "updated_at": "2026-06-21T00:00:01.000Z"]
        if let message { status["message"] = message }
        return ["status": status]
    }

    // MARK: - Errors a respawn can't fix never escalate

    /// THE regression: camera permission denial is `level:"error"` but no
    /// respawn fixes it — it must stay `.healthy`, not wedge-flip to wasm.
    func testCameraDenialNeverEscalates() {
        let snapshot = errorStatus("NotAllowedError: Permission denied")
        XCTAssertEqual(signal(snapshot), .healthy)
        // Even with the gaze pipeline silent, the error branch wins.
        XCTAssertEqual(signal(snapshot, gazeIsFresh: false), .healthy)
    }

    /// Model load/fetch failures are healthy-other problems — a respawn
    /// can't fix a missing file or a dead network.
    func testModelFetchErrorNeverEscalates() {
        for message in [
            "Failed to fetch model retinaface.onnx: 404",
            "model fetch failed: net::ERR_INTERNET_DISCONNECTED",
            "NotFoundError: Requested device not found",
            "TypeError: fetch failed"
        ] {
            XCTAssertEqual(signal(errorStatus(message)), .healthy, message)
            XCTAssertEqual(signal(errorStatus(message), gazeIsFresh: false),
                           .healthy, "error still wins over stale gaze: \(message)")
        }
    }

    /// An error with no message carries no wedge token — same honest
    /// non-escalation.
    func testErrorWithoutMessageIsHealthy() {
        XCTAssertEqual(signal(errorStatus(nil)), .healthy)
        XCTAssertEqual(signal(errorStatus(""), gazeIsFresh: false), .healthy)
    }

    /// Wedge tokens only count under `level:"error"`. The tracker emits
    /// real token-carrying text at `warning` level during routine
    /// declined re-promotion — that must never flip providers.
    func testWarningLevelNeverEscalatesEvenWithWedgeTokens() {
        let snapshot = errorStatus(
            "webgpu session rebuilds exhausted (cannot run inference. invalid session id: 5); falling back to wasm",
            level: "warning")
        XCTAssertEqual(signal(snapshot), .healthy)
        // The level isn't "error", so the snapshot falls through to the
        // stall check — a live gaze still reads healthy.
        XCTAssertEqual(signal(snapshot, gazeIsFresh: false), .stalled)
    }

    // MARK: - The wedge signature

    /// The dead-session message the runtime actually emits.
    func testDeadSessionMessageIsWedged() {
        let message = "cannot run inference. invalid session id: 12726032"
        guard case .wedged(let detail) = signal(errorStatus(message)) else {
            return XCTFail("expected .wedged, got \(signal(errorStatus(message)))")
        }
        XCTAssertEqual(detail, message, "the verdict carries the served message")
    }

    /// A bare invalid-session failure is a wedge even without the
    /// inference prefix.
    func testInvalidSessionIsWedged() {
        guard case .wedged = signal(errorStatus("invalid session id: 77")) else {
            return XCTFail("expected .wedged")
        }
    }

    /// The runtime's own unrecoverable marker after rebuild attempts run
    /// out — the wedge the watch exists to catch.
    func testUnrecoverableInferenceIsWedged() {
        guard case .wedged = signal(errorStatus(
            "inference unrecoverable — restart tracking (cannot run inference. invalid session id: 42)")) else {
            return XCTFail("expected .wedged")
        }
    }

    /// A reload failure names models but IS the reload wedge — the token
    /// set wins over the benign model-naming pattern.
    func testReloadFailureIsWedged() {
        guard case .wedged = signal(errorStatus("Failed to reload models with wasm")) else {
            return XCTFail("expected .wedged")
        }
    }

    /// OrtRun faults carry the raw ONNX token — matched case-insensitively.
    func testOrtRunTokenIsWedgedCaseInsensitive() {
        for message in ["OrtRun failed: invalid input",
                        "error in ortrun session",
                        "ORTRUN exception"] {
            guard case .wedged = signal(errorStatus(message)) else {
                return XCTFail("expected .wedged for '\(message)'")
            }
        }
    }

    /// The level check is case-insensitive — "Error"/"ERROR" count.
    func testLevelMatchIsCaseInsensitive() {
        guard case .wedged = signal(errorStatus("invalid session id: 7", level: "ERROR")) else {
            return XCTFail("expected .wedged for upper-case level")
        }
        XCTAssertEqual(signal(errorStatus("NotAllowedError", level: "Error")), .healthy)
    }

    // MARK: - Stalled: tracking on, gaze silent

    /// Tracking reports live but the gaze pipeline went quiet — a wedge
    /// the status can't name.
    func testStaleGazeWhileTrackingIsStalled() {
        XCTAssertEqual(signal([:], gazeIsFresh: false), .stalled)
        XCTAssertEqual(signal(["paused": false], gazeIsFresh: false), .stalled)
        XCTAssertEqual(signal(errorStatus(nil, level: "info"), gazeIsFresh: false), .stalled)
    }

    /// A paused tracker produces no gaze ON PURPOSE — silence there is
    /// not a wedge and never escalates.
    func testStaleGazeWhilePausedIsHealthy() {
        XCTAssertEqual(signal(["paused": true], gazeIsFresh: false), .healthy)
    }

    /// A live gaze plus no error status is plain healthy.
    func testHealthySnapshot() {
        XCTAssertEqual(signal([:]), .healthy)
        XCTAssertEqual(signal(errorStatus("Models loaded", level: "info")), .healthy)
        XCTAssertEqual(signal(errorStatus("ok", level: "debug")), .healthy)
        // A status that isn't a dictionary can't claim an error.
        XCTAssertEqual(signal(["status": "error"], gazeIsFresh: true), .healthy)
    }

    /// A non-wedge error keeps watching (logs once) rather than parking
    /// forever — and the error branch, not the stall check, answers.
    func testErrorStatusAnswersBeforeStallCheck() {
        // paused:true AND stale AND error → the error verdict still
        // governs; with no wedge token that is .healthy.
        var snapshot = errorStatus("camera unplugged")
        snapshot["paused"] = true
        XCTAssertEqual(signal(snapshot, gazeIsFresh: false), .healthy)
    }

    // MARK: - gazeIsFresh inputs the flag

    /// The fractional ISO8601 the store emits (`Date#toISOString`).
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private func gazeStamp(_ text: String?) -> [String: Any] {
        guard let text else { return [:] }
        return ["gaze": ["updated_at": text]]
    }

    /// A stamp inside the 6s window counts as producing.
    func testFreshStampIsFresh() {
        let now = Date()
        let snapshot = gazeStamp(Self.iso.string(from: now.addingTimeInterval(-3)))
        XCTAssertTrue(TrackerHost.gazeIsFresh(in: snapshot,
                                              runningSince: now.addingTimeInterval(-120),
                                              now: now))
    }

    /// A stamp past the 6s window reads stale regardless of uptime.
    func testStampOlderThanWindowIsStale() {
        let now = Date()
        let snapshot = gazeStamp(Self.iso.string(from: now.addingTimeInterval(-7)))
        XCTAssertFalse(TrackerHost.gazeIsFresh(in: snapshot,
                                               runningSince: now,
                                               now: now))
    }

    /// No stamp at all is fresh only inside the 45s post-start grace —
    /// cold-boot shader compiles must not escalate.
    func testMissingStampInsideGraceIsFresh() {
        let now = Date()
        XCTAssertTrue(TrackerHost.gazeIsFresh(in: gazeStamp(nil),
                                              runningSince: now.addingTimeInterval(-30),
                                              now: now))
    }

    /// A pipeline that never produced a stamp after the grace window IS
    /// the silent wedge the watch escalates.
    func testMissingStampPastGraceIsStale() {
        let now = Date()
        XCTAssertFalse(TrackerHost.gazeIsFresh(in: gazeStamp(nil),
                                               runningSince: now.addingTimeInterval(-60),
                                               now: now))
        // A gaze slice with no updated_at falls back to grace the same way.
        let stampless: [String: Any] = ["gaze": ["x_px": 100]]
        XCTAssertFalse(TrackerHost.gazeIsFresh(in: stampless,
                                               runningSince: now.addingTimeInterval(-60),
                                               now: now))
    }

    /// An unparseable stamp is treated as absent — grace decides.
    func testUnparseableStampFallsBackToGrace() {
        let now = Date()
        let snapshot = gazeStamp("not-a-date")
        XCTAssertTrue(TrackerHost.gazeIsFresh(in: snapshot,
                                              runningSince: now.addingTimeInterval(-30),
                                              now: now))
        XCTAssertFalse(TrackerHost.gazeIsFresh(in: snapshot,
                                               runningSince: now.addingTimeInterval(-60),
                                               now: now))
    }

    /// ISO8601 without fractional seconds parses through the fallback
    /// formatter — a tracker that emits whole-second stamps still reads.
    func testPlainIsoStampParses() {
        let now = Date()
        let snapshot = gazeStamp(Self.isoPlain.string(from: now.addingTimeInterval(-2)))
        XCTAssertTrue(TrackerHost.gazeIsFresh(in: snapshot,
                                              runningSince: now.addingTimeInterval(-120),
                                              now: now))
    }

    /// The wedge poll runs at 1.5s — two sightings still gate escalation,
    /// so a bad boot escalates in ~3s instead of the old ~6s.
    func testWedgePollCadenceIsOneAndHalfSeconds() {
        XCTAssertEqual(TrackerHost.wedgePollInterval, .milliseconds(1500))
    }
}
