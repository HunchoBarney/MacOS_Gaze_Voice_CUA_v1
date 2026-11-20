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

    /// A feed entry stamped at the ledger's wall clock — `uptime(for:)`
    /// maps it onto exactly `fakeNow`, however long the test is preempted.
    private func feed(_ kind: DecisionFeed.Kind, _ text: String) {
        ledger.record(DecisionFeed.Entry(at: ledger.wall(), kind: kind, text: text))
    }

    /// The coordinator's hand-off span opens a task record on its own,
    /// keeps the first value, and ignores other spans.
    func testFirstDesktopCallSpanOpensATaskRecord() {
        ledger.coordinatorSpan("driver.list_windows", 100, 100.5)
        ledger.coordinatorSpan("task.first_desktop_call", 100, 100.25)
        ledger.coordinatorSpan("task.first_desktop_call", 100, 101)
        ledger.closeCurrent(reason: "settled")
        let records = ledger.completedInteractions
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.origin, .task)
        XCTAssertEqual(records.first?.spans["handoff_to_desktop_call_ms"] ?? -1, 250, accuracy: 0.5)
        XCTAssertNil(records.first?.spans["driver.list_windows"])
    }

    /// A cancelled interaction still writes — with only the spans it reached.
    func testCancelledInteractionWritesPartialRecord() {
        feed(.heard, "\"open notes\"")
        fakeNow += 0.4
        feed(.route, "Opening notes → drive loop")
        ledger.closeCurrent(reason: "cancelled")

        let interactions = ledger.completedInteractions
        XCTAssertEqual(interactions.count, 1)
        let s = interactions[0].spans
        XCTAssertEqual(s["transcript_to_dispatch_ms"] ?? -1, 400, accuracy: 2)
        XCTAssertNil(s["dispatch_to_effect_ms"])
        XCTAssertEqual(interactions[0].result, "cancelled")
    }

    /// The heard line opens the record, transcript→dispatch→effect measure,
    /// and the round splits into its decide and dispatch spans.
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
        XCTAssertEqual(interactions[0].rounds.count, 1)
        XCTAssertEqual(interactions[0].rounds[0].decideMs ?? -1, 900, accuracy: 2)
        XCTAssertEqual(interactions[0].rounds[0].dispatchMs ?? -1, 300, accuracy: 2)
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
        feed(.heard, "\"open notes\"")
        fakeNow += 1.0
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
        XCTAssertEqual(object?["origin"] as? String, "typed")
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
            small.record(DecisionFeed.Entry(at: small.wall(), kind: .heard, text: "\"open notes\""))
            t += 0.1
            small.closeCurrent(reason: "done")
        }
        XCTAssertEqual(small.completedInteractions.count, 5)
    }

    /// p50/p95 land on real values and the report names every stage.
    func testReportListsStages() {
        XCTAssertEqual(LatencyLedger.percentile([100, 200, 300, 400], 0.5), 200)
        XCTAssertEqual(LatencyLedger.percentile([100, 200, 300, 400], 0.95), 400)

        feed(.heard, "\"open notes\"")
        fakeNow += 1.0
        feed(.route, "Opening notes → drive loop")
        ledger.closeCurrent(reason: "done")

        let report = ledger.report()
        for key in LatencyLedger.spanKeys {
            XCTAssertTrue(report.contains(key), "report missing \(key)")
        }
        XCTAssertTrue(report.contains("p50"))
        XCTAssertTrue(report.contains("1000"))
    }
}
