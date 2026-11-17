import XCTest
@testable import JevVoice

/// The spend counter keeps one bucket per day in a sidecar JSON and
/// reports "model calls today" — bump math, persistence shape, rollover.
@MainActor
final class LedgerSpendTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spend-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private let fixedDay = Date(timeIntervalSince1970: 1_761_000_000)

    func testBumpCountsPerKindAndTotal() {
        let counter = SpendCounter(fileURL: fileURL, now: { self.fixedDay })
        counter.bump(.realtimeTurn)
        counter.bump(.realtimeTurn)
        counter.bump(.responseCreate)
        counter.bump(.systemOneRTT)
        counter.bump(.systemOneRTT)
        counter.bump(.systemOneRTT)

        XCTAssertEqual(counter.today, 6)
        XCTAssertEqual(counter.count(.realtimeTurn), 2)
        XCTAssertEqual(counter.count(.responseCreate), 1)
        XCTAssertEqual(counter.count(.systemOneRTT), 3)
    }

    /// The sidecar persists {"days": {"yyyy-mm-dd": {kind: n}}} — the
    /// shape a fresh counter reads back.
    func testPersistedShapeAndReload() throws {
        let counter = SpendCounter(fileURL: fileURL, now: { self.fixedDay })
        counter.bump(.realtimeTurn)
        counter.bump(.systemOneRTT)
        counter.bump(.systemOneRTT)
        counter.flush()

        let data = try Data(contentsOf: fileURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let days = root?["days"] as? [String: [String: Int]]
        let key = SpendCounter.dayKey(for: fixedDay)
        XCTAssertEqual(days?[key]?["realtime_turn"], 1)
        XCTAssertEqual(days?[key]?["system_one_rtt"], 2)

        // A fresh counter over the same file reads the day back.
        let reloaded = SpendCounter(fileURL: fileURL, now: { self.fixedDay })
        XCTAssertEqual(reloaded.today, 3)
        XCTAssertEqual(reloaded.count(.systemOneRTT), 2)
    }

    /// Midnight re-keys: yesterday's count stays put, today starts at 0.
    func testDayRollover() {
        var current = fixedDay
        let counter = SpendCounter(fileURL: fileURL, now: { current })
        counter.bump(.realtimeTurn)
        counter.bump(.realtimeTurn)
        XCTAssertEqual(counter.today, 2)

        current = fixedDay.addingTimeInterval(86_400)
        counter.bump(.systemOneRTT)
        XCTAssertEqual(counter.today, 1)
        XCTAssertEqual(counter.count(.realtimeTurn), 0)

        let keyYesterday = SpendCounter.dayKey(for: fixedDay)
        let keyToday = SpendCounter.dayKey(for: fixedDay.addingTimeInterval(86_400))
        XCTAssertEqual(counter.dayCounts[keyYesterday]?["realtime_turn"], 2)
        XCTAssertEqual(counter.dayCounts[keyToday]?["system_one_rtt"], 1)
    }

    /// An absent/corrupt sidecar reads as zero, never a crash.
    func testMissingFileReadsZero() {
        let counter = SpendCounter(fileURL: fileURL, now: { self.fixedDay })
        XCTAssertEqual(counter.today, 0)

        try? "not json".write(to: fileURL, atomically: true, encoding: .utf8)
        let corrupt = SpendCounter(fileURL: fileURL, now: { self.fixedDay })
        XCTAssertEqual(corrupt.today, 0)
    }
}
