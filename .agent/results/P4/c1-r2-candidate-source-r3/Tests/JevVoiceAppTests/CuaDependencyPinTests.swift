import Foundation
import XCTest
@testable import JevVoice

final class CuaDependencyPinTests: XCTestCase {
    private let expectedExecutable = "b4d974a9c1c92a700cd7be7ede987aea4a1e6835e37039ce3d628b71bd5f0ca8"

    func testRequestedReleasePinMatchesRuntimeAndPublisherManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("ThirdParty/Cua/source-manifest.json"))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let binaries = try XCTUnwrap(manifest["vendored_binaries"] as? [String: [String: Any]])
        let driver = try XCTUnwrap(binaries["cua-driver"])
        XCTAssertEqual(driver["version"] as? String, "0.38.0")
        XCTAssertEqual(driver["sha256"] as? String, expectedExecutable)
        XCTAssertEqual(driver["tarball_sha256"] as? String,
                       "5f71191c082ca07c9dfc13b7c9a6eec60a82818c245a93534cc0eb7911471d72")
        XCTAssertEqual(driver["member"] as? String,
                       "cua-driver-rs-0.38.0-darwin-arm64/CuaDriver.app/Contents/MacOS/cua-driver")
        XCTAssertEqual(CuaDependency.executableSHA256, expectedExecutable)
        XCTAssertEqual(CuaDependency.sourceRevision, "85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19")
    }

    func testWrongExecutableStillFailsClosed() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cua-bad-pin-\(UUID())")
        try Data("not the requested executable".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertThrowsError(try CuaDependency.verify(file, expectedSHA256: expectedExecutable))
    }
}
