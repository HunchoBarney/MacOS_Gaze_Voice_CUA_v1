import XCTest
@testable import JevVoice

final class CuaDependencyTests: XCTestCase {
    func testMissingOrReplacedDependencyIsRejectedBeforeLaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("driver-pin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertThrowsError(try CuaDependency.verify(file, expectedSHA256: abcHash))
        try Data("abc".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertNoThrow(try CuaDependency.verify(file, expectedSHA256: abcHash))
        try Data("changed".utf8).write(to: file)
        XCTAssertThrowsError(try CuaDependency.verify(file, expectedSHA256: abcHash))
    }
}
