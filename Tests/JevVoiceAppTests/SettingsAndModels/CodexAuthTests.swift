import XCTest
@testable import JevVoice

/// CodexAuth probes: auth.json gate, `login status` parsing against a fake
/// executable, unreachable when the binary can't run, and the 30s cache.
final class CodexAuthTests: XCTestCase {
    private var tempDir: URL!
    private var codexHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexauth-\(UUID().uuidString)", isDirectory: true)
        codexHome = tempDir.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        codexHome = nil
        try super.tearDownWithError()
    }

    private func fakeCodex(_ body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("codex-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    private func writeAuth(_ contents: String = "{\"tokens\":{}}") {
        try! contents.write(to: codexHome.appendingPathComponent("auth.json"),
                            atomically: true, encoding: .utf8)
    }

    func testSignedInStatusParsesAccountLabel() async throws {
        writeAuth()
        let bin = try fakeCodex("echo 'Logged in using ChatGPT'")
        let auth = CodexAuth(binary: bin, codexHome: codexHome)
        let status = await auth.status()
        XCTAssertEqual(status, .signedIn("ChatGPT"))
    }

    func testNotLoggedInReadsAsSignedOut() async throws {
        writeAuth()
        let bin = try fakeCodex("echo 'Not logged in' >&2\nexit 1")
        let auth = CodexAuth(binary: bin, codexHome: codexHome)
        let status = await auth.status()
        XCTAssertEqual(status, .signedOut)
    }

    func testMissingAuthFileIsSignedOutWithoutTrustingBinary() async throws {
        // Binary claims a login, but auth.json absent → never claim signed-in.
        let bin = try fakeCodex("echo 'Logged in using ChatGPT'")
        let auth = CodexAuth(binary: bin, codexHome: codexHome)
        let status = await auth.status()
        XCTAssertEqual(status, .signedOut)
    }

    func testEmptyAuthFileIsSignedOut() async throws {
        writeAuth("")
        let bin = try fakeCodex("echo 'Logged in using ChatGPT'")
        let auth = CodexAuth(binary: bin, codexHome: codexHome)
        let status = await auth.status()
        XCTAssertEqual(status, .signedOut)
    }

    func testMissingBinaryIsUnreachable() async throws {
        writeAuth()
        let auth = CodexAuth(binary: tempDir.appendingPathComponent("no-such-codex"),
                             codexHome: codexHome)
        let status = await auth.status()
        XCTAssertEqual(status, .unreachable)
        XCTAssertFalse(auth.binaryAvailable)
    }

    func testNonExecutableBinaryIsUnreachable() async throws {
        writeAuth()
        let script = tempDir.appendingPathComponent("codex-not-exec")
        try "#!/bin/sh\necho 'Logged in'\n".write(to: script, atomically: true, encoding: .utf8)
        let auth = CodexAuth(binary: script, codexHome: codexHome)
        let status = await auth.status()
        XCTAssertEqual(status, .unreachable)
    }

    func testUnrecognizedOutputIsUnreachable() async throws {
        writeAuth()
        let bin = try fakeCodex("echo 'something unexpected'\nexit 0")
        let auth = CodexAuth(binary: bin, codexHome: codexHome)
        let status = await auth.status()
        XCTAssertEqual(status, .unreachable)
    }

    func testStatusIsCachedAcrossCalls() async throws {
        writeAuth()
        let count = tempDir.appendingPathComponent("invocations.count")
        let bin = try fakeCodex(
            "echo x >> '\(count.path)'\necho 'Logged in using ChatGPT'")
        let auth = CodexAuth(binary: bin, codexHome: codexHome)
        let first = await auth.status()
        let second = await auth.status()
        XCTAssertEqual(first, .signedIn("ChatGPT"))
        XCTAssertEqual(second, .signedIn("ChatGPT"))
        let calls = (try? String(contentsOf: count, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        XCTAssertEqual(calls, 1, "second status() inside the cache window must not respawn codex")
    }

    func testParseStatusHandlesObservedShapes() {
        XCTAssertEqual(CodexAuth.parseStatus(exitCode: 0, output: "Logged in using ChatGPT"),
                       .signedIn("ChatGPT"))
        XCTAssertEqual(CodexAuth.parseStatus(exitCode: 0, output: "Logged in using an API Key"),
                       .signedIn("an API Key"))
        XCTAssertEqual(CodexAuth.parseStatus(exitCode: 0, output: "Logged in"),
                       .signedIn(nil))
        XCTAssertEqual(CodexAuth.parseStatus(exitCode: 1, output: "Not logged in"),
                       .signedOut)
        XCTAssertEqual(CodexAuth.parseStatus(exitCode: 1, output: "usage: codex login"),
                       .unreachable)
        XCTAssertEqual(CodexAuth.parseStatus(exitCode: 0, output: ""),
                       .unreachable)
    }

    func testDeviceAuthScraping() {
        let banner = "\u{1B}[94mhttps://auth.openai.com/codex/device\u{1B}[0m "
            + "code \u{1B}[94mGE0K-353PD\u{1B}[0m"
        XCTAssertEqual(CodexAuth.deviceAuthURL(in: banner)?.absoluteString,
                       "https://auth.openai.com/codex/device")
        XCTAssertEqual(CodexAuth.deviceAuthCode(in: banner), "GE0K-353PD")
        XCTAssertNil(CodexAuth.deviceAuthURL(in: "no link yet"))
        XCTAssertNil(CodexAuth.deviceAuthCode(in: "no code yet"))
    }
}
