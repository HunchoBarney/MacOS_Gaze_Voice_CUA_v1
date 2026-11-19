import XCTest
@testable import JevVoice

final class TypeSafeStartupTests: XCTestCase {
    private final class Keys: APIKeyStore {
        enum Failure: Error { case locked }
        var value: String?
        var locked = false
        var rejectWrite = false
        var reads = 0
        var writes = 0
        var deletes = 0
        var migrations = 0
        var quiet: Keys?
        var noninteractive: APIKeyStore { quiet ?? self }

        func read() throws -> String? {
            reads += 1
            if locked { throw Failure.locked }
            return value
        }

        func save(_ key: String) throws {
            writes += 1
            if rejectWrite { throw Failure.locked }
            value = key
        }

        func delete() throws { deletes += 1; value = nil }

        func migrateLegacyKey(_ key: String) throws {
            migrations += 1
            if rejectWrite || value != nil { throw Failure.locked }
            value = key
        }
    }

    private let launch = Keys()
    private let settings = Keys()
    private let voice = Keys()
    private let suite = "typesafe-startup-\(UUID())"
    private lazy var defaults = UserDefaults(suiteName: suite)!

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func config(environment: [String: String] = [:]) -> Config {
        settings.quiet = launch
        voice.value = "fixture-voice"
        return Config(defaults: defaults, keyStore: settings, openAIKeyStore: voice,
                      environment: environment, codexAuth: CodexAuth(binary: nil))
    }

    func testLockedOptionalKeyCannotTriggerInteractiveStartupLookup() {
        launch.locked = true
        let c = config()
        XCTAssertEqual(settings.reads, 0)
        XCTAssertEqual(launch.reads, 1)
        XCTAssertEqual(voice.reads, 1)
        XCTAssertTrue(c.openAIAPIKey == voice.value)
        XCTAssertTrue(c.needsAPIKeyRetry)
        XCTAssertNotNil(c.apiKeyError)
        XCTAssertFalse(c.saveAPIKey(""))
        XCTAssertEqual(settings.deletes, 0)
        XCTAssertEqual(launch.migrations, 0)
        settings.locked = true
        _ = c.retryAPIKeyAccess(keeping: c.apiKey)
        XCTAssertTrue(c.needsAPIKeyRetry)
        XCTAssertEqual(settings.reads, 1)
        settings.locked = false
        settings.value = "fixture-saved"
        let retainedDraft = c.retryAPIKeyAccess(keeping: "fixture-edit")
        XCTAssertTrue(retainedDraft == "fixture-edit")
        XCTAssertTrue(c.apiKey == settings.value)
        XCTAssertNil(c.apiKeyError)
        _ = c.retryAPIKeyAccess(keeping: c.apiKey)
        XCTAssertEqual(settings.reads, 2)
        XCTAssertEqual(settings.writes, 0)
        XCTAssertEqual(voice.reads, 1)
    }

    func testAbsentIsNotBlockedAndRetryDoesNotRequestAccess() {
        let c = config()
        XCTAssertTrue(c.apiKey.isEmpty)
        XCTAssertFalse(c.needsAPIKeyRetry)
        XCTAssertNil(c.apiKeyError)
        _ = c.retryAPIKeyAccess(keeping: c.apiKey)
        XCTAssertEqual(settings.reads, 0)
        XCTAssertEqual(launch.migrations, 0)
        XCTAssertEqual(launch.deletes, 0)
    }

    func testReadableStoredKeyWinsWithoutMigratingOverIt() {
        launch.value = "fixture-current"
        defaults.set("fixture-legacy", forKey: "typesafeAPIKey")
        let c = config(environment: ["TYPESAFE_API_KEY": "fixture-env", "OPENAI_API_KEY": "fixture-voice-env"])
        XCTAssertTrue(c.apiKey == launch.value)
        XCTAssertFalse(c.needsAPIKeyRetry)
        XCTAssertEqual(launch.writes, 0)
        XCTAssertEqual(launch.migrations, 0)
        XCTAssertEqual(settings.reads, 0)
        XCTAssertNil(defaults.string(forKey: "typesafeAPIKey"))
        XCTAssertEqual(voice.reads, 0)
        XCTAssertTrue(c.openAIAPIKey == "fixture-voice-env")
    }

    func testReadFailureLeavesLegacyUntouchedAndKeepsEnvironmentFallback() {
        launch.locked = true
        defaults.set("fixture-legacy", forKey: "typesafeAPIKey")
        let c = config(environment: ["TYPESAFE_API_KEY": "fixture-env"])
        XCTAssertTrue(c.apiKey == "fixture-env")
        XCTAssertTrue(c.needsAPIKeyRetry)
        XCTAssertFalse(c.saveAPIKey("fixture-env"))
        XCTAssertTrue(defaults.string(forKey: "typesafeAPIKey") == "fixture-legacy")
        XCTAssertEqual(launch.migrations, 0)
        XCTAssertEqual(launch.writes, 0)
        XCTAssertEqual(settings.reads, 0)
    }

    func testLegacyMigrationUsesOnlyNoninteractiveStore() {
        defaults.set("fixture-legacy", forKey: "typesafeAPIKey")
        let c = config()
        XCTAssertTrue(c.apiKey == "fixture-legacy")
        XCTAssertTrue(launch.value == c.apiKey)
        XCTAssertFalse(c.needsAPIKeyRetry)
        XCTAssertEqual(launch.migrations, 1)
        XCTAssertEqual(launch.writes, 0)
        XCTAssertEqual(settings.reads, 0)
        XCTAssertNil(defaults.string(forKey: "typesafeAPIKey"))
    }

    func testFailedMigrationKeepsSourceAndRetryReadsBeforeWriting() {
        launch.rejectWrite = true
        defaults.set("fixture-legacy", forKey: "typesafeAPIKey")
        let c = config()
        XCTAssertTrue(c.apiKey == "fixture-legacy")
        XCTAssertTrue(c.needsAPIKeyRetry)
        XCTAssertFalse(c.saveAPIKey("fixture-legacy"))
        XCTAssertEqual(settings.writes, 0)
        XCTAssertTrue(defaults.string(forKey: "typesafeAPIKey") == c.apiKey)
        XCTAssertNil(launch.value)
        settings.value = "fixture-existing"
        let restoredDraft = c.retryAPIKeyAccess(keeping: c.apiKey)
        XCTAssertTrue(restoredDraft == settings.value)
        XCTAssertTrue(c.apiKey == settings.value)
        XCTAssertEqual(settings.migrations, 0)
        XCTAssertEqual(settings.writes, 0)
        XCTAssertFalse(c.needsAPIKeyRetry)
        XCTAssertNil(defaults.string(forKey: "typesafeAPIKey"))
    }

    func testExplicitSaveAndRemoveStillUseOriginalStore() {
        let c = config()
        XCTAssertTrue(c.saveAPIKey("fixture-new"))
        XCTAssertEqual(settings.writes, 1)
        XCTAssertEqual(launch.writes, 0)
        XCTAssertTrue(c.saveAPIKey(""))
        XCTAssertEqual(settings.deletes, 1)
        XCTAssertEqual(launch.deletes, 0)
    }

    func testUneditedFallbackCannotOverwriteAfterRetryMigrationFails() {
        launch.locked = true
        defaults.set("fixture-legacy", forKey: "typesafeAPIKey")
        let c = config(environment: ["TYPESAFE_API_KEY": "fixture-env"])
        let initialDraft = c.apiKey
        settings.rejectWrite = true
        let draft = c.retryAPIKeyAccess(keeping: initialDraft)
        XCTAssertTrue(c.needsAPIKeyRetry)
        XCTAssertTrue(draft == "fixture-legacy")
        XCTAssertFalse(c.canSaveAPIKey(draft))
        XCTAssertFalse(c.saveAPIKey(draft))
        XCTAssertEqual(settings.writes, 0)
        XCTAssertEqual(settings.deletes, 0)
        XCTAssertTrue(defaults.string(forKey: "typesafeAPIKey") == "fixture-legacy")
    }
}
