import AppKit
import XCTest
@testable import JevVoice

@MainActor
extension VoiceLaneAuditTests {
    func testWitnessKeepsWindowIdentityButNeverObservedContent() throws {
        let window: [String: Any] = [
            kCGWindowOwnerPID as String: 44,
            kCGWindowNumber as String: 99,
            kCGWindowLayer as String: 0,
            kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String: 1.0,
            kCGWindowName as String: "DO NOT STORE THIS",
            kCGWindowOwnerName as String: "DO NOT STORE THIS",
            kCGWindowBounds as String: [
                "X": 0, "Y": 0, "Width": 1200, "Height": 800,
                "private": "DO NOT STORE THIS",
            ],
        ]
        let witness = try XCTUnwrap(VoiceUserAudit.nativeWindowWitness(
            stage: .nativeForegroundReadBegin, rows: [window], frontmostPID: 77, at: 1.25))
        XCTAssertEqual(witness["frontmost_pid"] as? Int, 77)
        XCTAssertEqual(witness["monotonic"] as? Double, 1.25)
        let rows = try XCTUnwrap(witness["normal_window_metadata"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][kCGWindowNumber as String] as? Int, 99)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: witness), as: UTF8.self)
        XCTAssertFalse(encoded.contains("DO NOT STORE THIS"))
        let bounds = try XCTUnwrap(rows[0][kCGWindowBounds as String] as? [String: Double])
        XCTAssertEqual(Set(bounds.keys), ["X", "Y", "Width", "Height"])
    }

    func testWitnessDoesNotRecordOtherStagesOrTruncateWindowOrder() throws {
        let rows: [[String: Any]] = (1...70).map {
            [kCGWindowOwnerPID as String: 44, kCGWindowNumber as String: $0,
             kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: true]
        }
        XCTAssertNil(VoiceUserAudit.nativeWindowWitness(
            stage: .driverBegin, rows: rows, frontmostPID: nil, at: 1))
        let witness = try XCTUnwrap(VoiceUserAudit.nativeWindowWitness(
            stage: .nativeForegroundReadEnd, rows: rows, frontmostPID: nil, at: 2))
        let observed = try XCTUnwrap(witness["normal_window_metadata"] as? [[String: Any]])
        XCTAssertEqual(observed.count, 70)
        XCTAssertEqual(observed.last?[kCGWindowNumber as String] as? Int, 70)
    }

    func testAuditReceiptPersistsWitnessForEveryOutcome() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-witness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics: [String: Any] = [
            "native_window_witness": [["stage": "nativeForegroundReadBegin", "monotonic": 1.0]],
        ]
        for status in ["passed", "reproduction_observed", "blocked_or_failed", "running"] {
            let url = directory.appendingPathComponent("\(status).json")
            try VoiceUserAudit.save(["status": status], url, diagnostics: diagnostics)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(saved["status"] as? String, status)
            let metadata = try XCTUnwrap(saved["focus_diagnostics"] as? [String: Any])
            let witnesses = try XCTUnwrap(metadata["native_window_witness"] as? [[String: Any]])
            XCTAssertEqual(witnesses.count, 1)
        }
    }
}
