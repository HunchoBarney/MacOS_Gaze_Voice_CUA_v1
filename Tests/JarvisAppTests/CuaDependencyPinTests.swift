import Foundation
import XCTest
@testable import Jarvis

final class CuaDependencyPinTests: XCTestCase {
    private let expectedExecutable = "0bb686e1e44b5e80c26f6666b29e6a613621d25f4cc7dd407e19794193186b1c"

    func testRequestedReleasePinMatchesRuntimeAndPublisherManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("ThirdParty/Cua/source-manifest.json"))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let binaries = try XCTUnwrap(manifest["vendored_binaries"] as? [String: [String: Any]])
        let driver = try XCTUnwrap(binaries["cua-driver"])
        XCTAssertEqual(driver["version"] as? String, "0.54.0")
        XCTAssertEqual(driver["sha256"] as? String, expectedExecutable)
        XCTAssertEqual(driver["commit"] as? String, "09dd7017fca72678fd707490f8d2913a55d97e72")
        XCTAssertEqual(driver["patch_sha256"] as? String,
                       "bdfa8510d58073199b507be00121979425e03c09b3ce3cf0c7ed45325f170e7a")
        XCTAssertEqual(CuaDependency.executableSHA256, expectedExecutable)
        XCTAssertEqual(CuaDependency.sourceRevision, "09dd7017fca72678fd707490f8d2913a55d97e72")
    }

    func testWrongExecutableStillFailsClosed() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cua-bad-pin-\(UUID())")
        try Data("not the requested executable".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertThrowsError(try CuaDependency.verify(file, expectedSHA256: expectedExecutable))
    }
}
