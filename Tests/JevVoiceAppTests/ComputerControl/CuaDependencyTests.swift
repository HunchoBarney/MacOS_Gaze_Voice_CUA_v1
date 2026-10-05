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

    /// A stat-fingerprint hit is bound to the pin it was hashed against —
    /// the same untouched file must rehash and fail under a different pin.
    func testStatCacheIsBoundToTheExpectedPin() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("driver-pin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data("abc".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertNoThrow(try CuaDependency.verify(file, expectedSHA256: abcHash))
        XCTAssertThrowsError(try CuaDependency.verify(file, expectedSHA256: String(repeating: "0", count: 64)))
        XCTAssertNoThrow(try CuaDependency.verify(file, expectedSHA256: abcHash))
    }

    /// Same-size replacement with a restored mtime still misses the cached
    /// fingerprint — ctime advances on any write and cannot be wound back —
    /// so the swapped bytes rehash to a rejection.
    func testSameSizeRewriteWithRestoredMtimeStillRehashes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("driver-pin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data("abc".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertNoThrow(try CuaDependency.verify(file, expectedSHA256: abcHash))
        let mtime = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
        try Data("xyz".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: mtime as Any], ofItemAtPath: file.path)
        XCTAssertThrowsError(try CuaDependency.verify(file, expectedSHA256: abcHash))
    }
}
