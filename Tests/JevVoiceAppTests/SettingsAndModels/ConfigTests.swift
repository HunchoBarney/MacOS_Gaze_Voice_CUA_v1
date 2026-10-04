import XCTest
@testable import JevVoice

final class ConfigTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "JevVoice.ConfigTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMigratesLegacyKeyBeforeRemovingPlaintext() {
        defaults.set("synthetic-legacy", forKey: "typesafeAPIKey")
        let store = FakeAPIKeyStore()
        store.beforeSave = { XCTAssertEqual(self.defaults.string(forKey: "typesafeAPIKey"), "synthetic-legacy") }

        let config = Config(defaults: defaults, keyStore: store, environment: [:])

        XCTAssertEqual(config.apiKey, "synthetic-legacy")
        XCTAssertEqual(try store.read(), "synthetic-legacy")
        XCTAssertNil(defaults.object(forKey: "typesafeAPIKey"))
        XCTAssertNil(config.apiKeyError)
    }

    func testExistingKeychainKeyWinsAndRemovesStalePlaintext() {
        defaults.set("synthetic-stale", forKey: "typesafeAPIKey")
        let store = FakeAPIKeyStore(value: "synthetic-stored")
        let config = Config(defaults: defaults, keyStore: store, environment: ["TYPESAFE_API_KEY": "synthetic-env"])

        XCTAssertEqual(config.apiKey, "synthetic-stored")
        XCTAssertNil(defaults.object(forKey: "typesafeAPIKey"))
        XCTAssertEqual(store.saveCount, 0)
    }

    func testFailedMigrationPreservesLegacyKeyAndReportsFailure() {
        defaults.set("synthetic-legacy", forKey: "typesafeAPIKey")
        let store = FakeAPIKeyStore()
        store.failSave = true
        let config = Config(defaults: defaults, keyStore: store, environment: [:])

        XCTAssertEqual(config.apiKey, "synthetic-legacy")
        XCTAssertEqual(defaults.string(forKey: "typesafeAPIKey"), "synthetic-legacy")
        XCTAssertNotNil(config.apiKeyError)
        XCTAssertNil(store.value)

        store.failSave = false
        XCTAssertTrue(config.saveAPIKey(config.apiKey))
        XCTAssertNil(config.apiKeyError)
        XCTAssertNil(defaults.object(forKey: "typesafeAPIKey"))
    }

    func testKeychainReadFailureDoesNotOverwriteUnknownCredential() {
        defaults.set("synthetic-legacy", forKey: "typesafeAPIKey")
        let store = FakeAPIKeyStore(value: "synthetic-inaccessible")
        store.failRead = true
        let config = Config(defaults: defaults, keyStore: store, environment: ["TYPESAFE_API_KEY": "synthetic-env"])

        XCTAssertEqual(config.apiKey, "synthetic-env")
        XCTAssertNotNil(config.apiKeyError)
        XCTAssertEqual(store.value, "synthetic-inaccessible")
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(defaults.string(forKey: "typesafeAPIKey"), "synthetic-legacy")
    }

    func testEnvironmentFallbackIsNotPersisted() {
        let store = FakeAPIKeyStore()
        let config = Config(defaults: defaults, keyStore: store, environment: ["TYPESAFE_API_KEY": "synthetic-env"])

        XCTAssertEqual(config.apiKey, "synthetic-env")
        XCTAssertNil(store.value)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(defaults.object(forKey: "typesafeAPIKey"))
    }

    func testExplicitSavePersistsAndClearsLegacyValue() {
        let store = FakeAPIKeyStore()
        let config = Config(defaults: defaults, keyStore: store, environment: [:])
        defaults.set("synthetic-stale", forKey: "typesafeAPIKey")

        XCTAssertTrue(config.saveAPIKey("synthetic-new"))
        XCTAssertEqual(config.apiKey, "synthetic-new")
        XCTAssertEqual(try store.read(), "synthetic-new")
        XCTAssertNil(defaults.object(forKey: "typesafeAPIKey"))
        XCTAssertNil(config.apiKeyError)
    }

    func testFailedSaveKeepsLastUsableKeyWithoutPlaintextFallback() {
        let store = FakeAPIKeyStore(value: "synthetic-original")
        let config = Config(defaults: defaults, keyStore: store, environment: [:])
        store.failSave = true

        XCTAssertFalse(config.saveAPIKey("synthetic-replacement"))
        XCTAssertEqual(config.apiKey, "synthetic-original")
        XCTAssertEqual(store.value, "synthetic-original")
        XCTAssertNil(defaults.object(forKey: "typesafeAPIKey"))
        XCTAssertNotNil(config.apiKeyError)
    }

    func testClearingKeyDeletesStoredAndLegacyCredentials() {
        let store = FakeAPIKeyStore(value: "synthetic-original")
        let config = Config(defaults: defaults, keyStore: store, environment: [:])
        defaults.set("synthetic-stale", forKey: "typesafeAPIKey")

        XCTAssertTrue(config.saveAPIKey(""))
        XCTAssertEqual(config.apiKey, "")
        XCTAssertNil(store.value)
        XCTAssertNil(defaults.object(forKey: "typesafeAPIKey"))
    }

    func testFailedDeleteRetainsCurrentKeyAndReportsFailure() {
        let store = FakeAPIKeyStore(value: "synthetic-original")
        let config = Config(defaults: defaults, keyStore: store, environment: [:])
        store.failDelete = true

        XCTAssertFalse(config.saveAPIKey(""))
        XCTAssertEqual(config.apiKey, "synthetic-original")
        XCTAssertEqual(store.value, "synthetic-original")
        XCTAssertNotNil(config.apiKeyError)
    }

    func testNonSecretPreferencesStillPersistInDefaults() {
        let config = Config(defaults: defaults, keyStore: FakeAPIKeyStore(), environment: [:])
        XCTAssertTrue(config.autoExecute)
        config.autoExecute = false

        let reloaded = Config(defaults: defaults, keyStore: FakeAPIKeyStore(), environment: [:])
        XCTAssertFalse(reloaded.autoExecute)
    }
}

private final class FakeAPIKeyStore: APIKeyStore {
    enum Failure: Error { case denied }
    var value: String?
    var failRead = false
    var failSave = false
    var failDelete = false
    var beforeSave: (() -> Void)?
    var saveCount = 0

    init(value: String? = nil) { self.value = value }

    func read() throws -> String? {
        if failRead { throw Failure.denied }
        return value
    }

    func save(_ apiKey: String) throws {
        beforeSave?()
        if failSave { throw Failure.denied }
        saveCount += 1
        value = apiKey
    }

    func delete() throws {
        if failDelete { throw Failure.denied }
        value = nil
    }
}
