import Security
import XCTest
@testable import JevVoice

final class KeychainAPIKeyStoreTests: XCTestCase {
    func testSyntheticCredentialRoundTripUpdateAndDelete() throws {
        let service = "JevVoice.KeychainTests.\(UUID().uuidString)"
        let store = KeychainAPIKeyStore(service: service, account: "synthetic", allowUserInteraction: false)
        defer { try? store.delete() }

        do {
            XCTAssertNil(try store.read())
            try store.save("synthetic-first")
            let reloaded = KeychainAPIKeyStore(service: service, account: "synthetic", allowUserInteraction: false)
            XCTAssertEqual(try reloaded.read(), "synthetic-first")
            try reloaded.save("synthetic-replacement")
            XCTAssertEqual(try store.read(), "synthetic-replacement")
            try store.delete()
            XCTAssertNil(try reloaded.read())
            XCTAssertNoThrow(try store.delete())
        } catch KeychainAPIKeyStore.StoreError.status(let status)
            where status == errSecInteractionNotAllowed || status == errSecNotAvailable || status == errSecNoSuchKeychain {
            throw XCTSkip("Synthetic Keychain test cannot run noninteractively (OSStatus \(status)).")
        }
    }
}
