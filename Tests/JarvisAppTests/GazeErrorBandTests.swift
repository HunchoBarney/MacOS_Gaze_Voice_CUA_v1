import CoreGraphics
import Foundation
import XCTest
@testable import Jarvis

final class GazeErrorBandTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ object: [String: Any], modified: Date) throws {
        let url = dir.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// Never measured means invisible calibration hasn't learned yet: the
    /// band starts wide (~4° median) instead of claiming calibrated accuracy.
    func testNoReportFallsBackToTheUncalibratedBand() {
        XCTAssertNil(GazeErrorBand.medianErrorPt(in: dir))
        XCTAssertEqual(GazeErrorBand.sigmaPt(in: dir), 150)
        XCTAssertEqual(GazeErrorBand.sigmaPt(in: nil), 150)
    }

    /// The running learning report competes like the others: newest wins.
    func testLearningReportWinsWhenNewest() throws {
        try write("calibration_report.json", ["median_pt": 50], modified: Date(timeIntervalSinceNow: -60))
        try write("learning_report.json", ["median_pt": 100], modified: Date())
        XCTAssertEqual(GazeErrorBand.medianErrorPt(in: dir), 100)
        try write("accuracy_report.json", ["error_px": ["overall": ["median": 70]]], modified: Date(timeIntervalSinceNow: 5))
        XCTAssertEqual(GazeErrorBand.medianErrorPt(in: dir), 70)
    }

    /// σ = median / √(2 ln 2): a 100 pt median radial error is σ ≈ 84.9 pt.
    func testSigmaComesFromTheMeasuredMedian() throws {
        try write("accuracy_report.json", ["error_px": ["overall": ["median": 100.0]]], modified: Date())
        XCTAssertEqual(GazeErrorBand.medianErrorPt(in: dir), 100)
        XCTAssertEqual(GazeErrorBand.sigmaPt(in: dir), 100 / (2 * log(2.0)).squareRoot(), accuracy: 1e-9)
    }

    func testNewerReportWinsSoRecalibrationSupersedesAnOldAccuracyRun() throws {
        let now = Date()
        try write("accuracy_report.json", ["error_px": ["overall": ["median": 120.0]]], modified: now.addingTimeInterval(-60))
        try write("calibration_report.json", ["median_pt": 70.0], modified: now)
        XCTAssertEqual(GazeErrorBand.medianErrorPt(in: dir), 70)
        try write("accuracy_report.json", ["error_px": ["overall": ["median": 90.0]]], modified: now.addingTimeInterval(60))
        XCTAssertEqual(GazeErrorBand.medianErrorPt(in: dir), 90)
    }

    func testTinyMedianIsFloored() throws {
        try write("calibration_report.json", ["median_pt": 5.0], modified: Date())
        XCTAssertEqual(GazeErrorBand.sigmaPt(in: dir), GazeErrorBand.minimumSigmaPt)
    }

    func testMeasuredConfigCarriesSigma() throws {
        try write("calibration_report.json", ["median_pt": 117.74], modified: Date())
        XCTAssertEqual(IntentScorerCore.Config.measured(in: dir).sigmaPx, 100, accuracy: 0.01)
    }

    /// Containing frames come first, smallest first; then nearest edges
    /// inside the band; frames beyond the band and missing frames drop out.
    func testNearestRanksContainmentThenEdgeDistance() {
        let point = CGPoint(x: 100, y: 100)
        let frames: [CGRect?] = [
            CGRect(x: 0, y: 0, width: 400, height: 400),
            CGRect(x: 90, y: 90, width: 20, height: 20),
            CGRect(x: 130, y: 95, width: 20, height: 10),
            CGRect(x: 300, y: 300, width: 10, height: 10),
            nil,
        ]
        let near = GazeErrorBand.nearest(frames: frames, to: point, bandPt: 50)
        XCTAssertEqual(near.map(\.index), [1, 0, 2])
        XCTAssertEqual(near[2].distance, 30, accuracy: 1e-9)
    }
}
