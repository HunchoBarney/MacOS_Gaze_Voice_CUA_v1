import XCTest
import JevVoiceCore
@testable import JevVoice

private actor PermissionStatusProbe: CuaPermissionStatusClient {
    private(set) var requestedPrompt: Bool?

    func checkPermissions(prompt: Bool) async throws -> JSONValue {
        requestedPrompt = prompt
        return .object(["accessibility": .bool(false), "screen_recording": .bool(false)])
    }
}

final class CuaSetupTests: XCTestCase {
    @MainActor
    func testDocumentSetupFlowThroughPinnedCuaOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_SETUP_TEST"] == "1" else {
            throw XCTSkip("Opt-in disposable TextEdit setup proof through the installed Driver")
        }
        let setup = CuaSetup()
        setup.verify(apiKey: try CuaLiveCredential.jev())
        for _ in 0..<50 where !setup.busy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(setup.busy, "The setup task did not start")
        for _ in 0..<900 where setup.busy { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(setup.verified, setup.message)
        XCTAssertFalse(setup.busy)
        print("Pinned Cua setup result:", setup.message)
    }

    func testDisposableDocumentLivesInTheSystemTemporaryDirectory() {
        let first = CuaSetupFixture.documentURL()
        let second = CuaSetupFixture.documentURL()
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL

        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, temporaryDirectory)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Jarvis-Check-"))
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".txt"))
        XCTAssertNotEqual(first, second)
    }

    func testSetupPermissionProbeUsesSchemaBoundReadOnlyCall() async throws {
        let probe = PermissionStatusProbe()

        let result = try await CuaPermissionProbe.read(using: probe)

        let requestedPrompt = await probe.requestedPrompt
        XCTAssertEqual(requestedPrompt, false)
        XCTAssertEqual(result["accessibility"], JSONValue.bool(false))
        XCTAssertEqual(result["screen_recording"], JSONValue.bool(false))
    }
}
