import XCTest
@testable import Jarvis

/// The latency ledger turns feed/capture/input edges into per-interaction
/// spans and a JSONL record. Driven through the same seams `attach` wires —
/// `mark`, `captureStateChanged`, and `record(entry)` — so tests never need
/// a real controller, feed, or tracker.
final class LedgerLatencyTests: XCTestCase {

    private var ledger: LatencyLedger!
    private var fileURL: URL!
    private var fakeNow: TimeInterval = 100

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("latency-\(UUID().uuidString).jsonl")
        ledger = LatencyLedger(fileURL: fileURL, synchronousWrites: true)
        fakeNow = 100
        ledger.now = { [weak self] in self?.fakeNow ?? 0 }
        ledger.wall = { Date(timeIntervalSince1970: 1_760_000_000) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    /// A feed entry stamped "right now" — `uptime(for:)` maps it onto
    /// `fakeNow` because the wall clock difference is ~0.
    private func feed(_ kind: DecisionFeed.Kind, _ text: String) {
        ledger.record(DecisionFeed.Entry(at: Date(), kind: kind, text: text))
    }

    /// The canonical hold→commit→transcript→dispatch→effect interaction
    /// fills every primary span plus one round's decide/dispatch pair.
    func testFullHoldPipelineProducesSpans() {
        ledger.mark(.fnDown)                            // t = 100.00
        fakeNow += 1.5
        ledger.mark(.fnRelease)                         // t = 101.50
        fakeNow += 0.05
        ledger.captureStateChanged(.finishing, transcript: "")
        fakeNow += 0.4
        ledger.captureStateChanged(.idle, transcript: "open notes")
        fakeNow += 0.3
        feed(.heard, "\"open notes\"")                  // t = 102.25
        fakeNow += 0.2
        feed(.route, "Opening notes → drive loop")      // t = 102.45
        fakeNow += 1.1
        feed(.dispatch, "round 1: el_4 — New note")     // t = 103.55
        fakeNow += 0.6
        feed(.dispatch, "click → confirmed")            // t = 104.15
        fakeNow += 0.2
        feed(.outcome, "Done.")                         // t = 104.35

        let interactions = ledger.completedInteractions
        XCTAssertEqual(interactions.count, 1)
        let record = interactions[0]
        XCTAssertEqual(record.origin, .hold)
        XCTAssertEqual(record.result, "settled")

        let s = record.spans
        XCTAssertEqual(s["fn_hold_ms"] ?? -1, 1500, accuracy: 2)
        XCTAssertEqual(s["release_to_commit_ms"] ?? -1, 50, accuracy: 2)
        XCTAssertEqual(s["commit_to_transcript_ms"] ?? -1, 400, accuracy: 2)
        // heard arrives after the transcript mark — dispatch is the
        // "→ drive loop" line, so the span covers heard→route too.
        XCTAssertEqual(s["transcript_to_dispatch_ms"] ?? -1, 500, accuracy: 2)
        XCTAssertEqual(s["dispatch_to_effect_ms"] ?? -1, 1700, accuracy: 2)
        XCTAssertEqual(s["fn_to_effect_ms"] ?? -1, 4150, accuracy: 2)

        XCTAssertEqual(record.rounds.count, 1)
        XCTAssertEqual(record.rounds[0].n, 1)
        XCTAssertEqual(record.rounds[0].decideMs ?? -1, 1100, accuracy: 2)
        XCTAssertEqual(record.rounds[0].dispatchMs ?? -1, 600, accuracy: 2)
    }

    /// A cancelled hold still writes — with only the spans it reached.
    func testCancelledHoldWritesPartialRecord() {
        ledger.mark(.fnDown)
        fakeNow += 0.8
        ledger.mark(.fnRelease)
        fakeNow += 0.02
        ledger.captureStateChanged(.finishing, transcript: "")
        ledger.closeCurrent(reason: "cancelled")

        let interactions = ledger.completedInteractions
        XCTAssertEqual(interactions.count, 1)
        let s = interactions[0].spans
        XCTAssertEqual(s["fn_hold_ms"] ?? -1, 800, accuracy: 2)
        XCTAssertEqual(s["release_to_commit_ms"] ?? -1, 20, accuracy: 2)
        XCTAssertNil(s["commit_to_transcript_ms"])
        XCTAssertNil(s["dispatch_to_effect_ms"])
        XCTAssertEqual(interactions[0].result, "cancelled")
    }

    /// A typed turn has no fn edges — the heard line opens the record and
    /// transcript→dispatch→effect still measure.
    func testTypedTurnOpensOnHeard() {
        feed(.heard, "\"open notes\"")
        fakeNow += 0.4
        feed(.route, "Opening notes → drive loop")
        fakeNow += 0.9
        feed(.dispatch, "round 1: el_2 — Notes icon")
        fakeNow += 0.3
        feed(.dispatch, "click → confirmed")
        feed(.outcome, "Done.")

        let interactions = ledger.completedInteractions
        XCTAssertEqual(interactions.count, 1)
        XCTAssertEqual(interactions[0].origin, .typed)
        let s = interactions[0].spans
        XCTAssertEqual(s["transcript_to_dispatch_ms"] ?? -1, 400, accuracy: 2)
        XCTAssertEqual(s["dispatch_to_effect_ms"] ?? -1, 1200, accuracy: 2)
        XCTAssertNil(s["fn_hold_ms"])
    }

    /// eyes_land→effect consumes the land once: dwell commit inside the
    /// window resolves the span and closes a gaze-origin record outright.
    func testEyesLandToDwellEffect() {
        ledger.noteEyesLand()                           // t = 100
        fakeNow += 0.8
        feed(.dispatch, "dwell → Save")

        let interactions = ledger.completedInteractions
        XCTAssertEqual(interactions.count, 1)
        XCTAssertEqual(interactions[0].origin, .gaze)
        XCTAssertEqual(interactions[0].result, "effect")
        XCTAssertEqual(interactions[0].spans["eyes_land_to_effect_ms"] ?? -1,
                       800, accuracy: 2)
    }

    /// An eyes-land older than the window is a different glance — no span.
    func testStaleEyesLandIgnored() {
        ledger.noteEyesLand()
        fakeNow += LatencyLedger.eyesLandWindow + 1
        feed(.dispatch, "dwell → Save")
        XCTAssertEqual(ledger.completedInteractions.count, 0)
    }

    /// Each closed interaction appends one parseable JSON object per line
    /// with the documented record keys.
    func testJSONLRecordShape() throws {
        ledger.mark(.fnDown)
        fakeNow += 1.0
        ledger.mark(.fnRelease)
        ledger.closeCurrent(reason: "cancelled")

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let object = try JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertNotNil(object)
        for key in ["v", "id", "origin", "began", "ended", "result",
                    "marks", "spans", "rounds", "measurements"] {
            XCTAssertNotNil(object?[key], "missing key \(key)")
        }
        XCTAssertEqual(object?["origin"] as? String, "hold")
        XCTAssertEqual(object?["result"] as? String, "cancelled")
        XCTAssertNotNil(object?["spans"] as? [String: Double])
    }

    /// The ring caps at capacity — old records drop, never grow unbounded.
    func testRingBufferCapacity() {
        let small = LatencyLedger(fileURL: fileURL, capacity: 5,
                                  synchronousWrites: true)
        var t: TimeInterval = 0
        small.now = { t }
        for _ in 0..<8 {
            small.mark(.fnDown)
            t += 0.1
            small.closeCurrent(reason: "done")
        }
        XCTAssertEqual(small.completedInteractions.count, 5)
    }

    /// p50/p95 land on real values and the report names every stage.
    func testReportListsStages() {
        XCTAssertEqual(LatencyLedger.percentile([100, 200, 300, 400], 0.5), 200)
        XCTAssertEqual(LatencyLedger.percentile([100, 200, 300, 400], 0.95), 400)

        ledger.mark(.fnDown)
        fakeNow += 1.0
        ledger.mark(.fnRelease)
        ledger.closeCurrent(reason: "done")

        let report = ledger.report()
        for key in LatencyLedger.spanKeys {
            XCTAssertTrue(report.contains(key), "report missing \(key)")
        }
        XCTAssertTrue(report.contains("p50"))
        XCTAssertTrue(report.contains("1500") || report.contains("1000"))
    }
}
