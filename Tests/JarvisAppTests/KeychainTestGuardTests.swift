import XCTest
@testable import Jarvis

/// No unit test reaches the Mac's Keychain. Its items carry access lists for
/// the signed app, so a test binary that reads them raises a password prompt
/// on the person's screen, once for every new test build.
final class KeychainTestGuardTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JARVIS_LIVE_KEYCHAIN"] == "1",
                      "a live run has opted in to the Keychain")
    }

    func testEveryKeychainStoreStaysInTheTestProcess() throws {
        XCTAssertTrue(KeychainTestGuard.blocksRealKeychain)
        let store = KeychainAPIKeyStore(service: "com.karanvirkang.jarvis.test-guard", account: UUID().uuidString,
                                        allowUserInteraction: false)
        XCTAssertNil(try store.read())
        guard KeychainTestGuard.realKeychainCalls.load(ordering: .relaxed) == 0 else {
            return XCTFail("a unit test read the real Keychain")
        }
        try store.save("fixture-value")
        XCTAssertEqual(try store.read(), "fixture-value")
        try store.delete()
        XCTAssertNil(try store.read())
        XCTAssertEqual(KeychainTestGuard.realKeychainCalls.load(ordering: .relaxed), 0)
    }

    func testTheSharedConfigNeverReadsTheRealKeychain() {
        _ = Config.shared.apiKey
        _ = Config.shared.openAIAPIKey
        _ = Config.shared.hosted
        XCTAssertEqual(KeychainTestGuard.realKeychainCalls.load(ordering: .relaxed), 0)
    }

    func testOnlyALiveRunOptsIn() {
        XCTAssertTrue(KeychainTestGuard.runningTests(hasXCTest: true, processName: "xctest", environment: [:]))
        XCTAssertTrue(KeychainTestGuard.runningTests(hasXCTest: false, processName: "swiftpm-testing-helper",
                                                     environment: [:]))
        XCTAssertFalse(KeychainTestGuard.runningTests(hasXCTest: true, processName: "xctest",
                                                      environment: ["JARVIS_LIVE_KEYCHAIN": "1"]))
        XCTAssertFalse(KeychainTestGuard.runningTests(hasXCTest: false, processName: "Jarvis", environment: [:]))
    }
}
