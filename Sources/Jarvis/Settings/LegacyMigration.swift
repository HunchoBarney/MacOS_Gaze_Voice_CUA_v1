import Foundation
import OSLog

/// One-time move of what the app stored before it was renamed to Jarvis:
/// preferences under the old bundle id, the old Application Support
/// folder, and the two API keys under the old Keychain service. Existing
/// Jarvis data always wins; the old Keychain items are left in place.
enum LegacyMigration {
    static let legacyBundleID = "com.chriswozniczek.jevvoice"
    static let legacySupportFolder = "JevVoice"
    static let supportFolder = "Jarvis"
    static let doneKey = "legacyMigrationDone"
    static let keyAccounts = ["typesafeAPIKey", "openAIAPIKey"]

    private static let log = Logger(subsystem: "com.karanvirkang.jarvis", category: "LegacyMigration")

    static func runOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        run(defaults: defaults,
            legacyDefaults: defaults.persistentDomain(forName: legacyBundleID),
            applicationSupport: support,
            keys: keyAccounts.map {
                (KeychainAPIKeyStore(service: legacyBundleID, account: $0),
                 KeychainAPIKeyStore(account: $0))
            })
        defaults.set(true, forKey: doneKey)
    }

    static func run(defaults: UserDefaults,
                    legacyDefaults: [String: Any]?,
                    applicationSupport: URL,
                    keys: [(legacy: any APIKeyStore, current: any APIKeyStore)],
                    fileManager: FileManager = .default) {
        for (key, value) in legacyDefaults ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }

        let legacy = applicationSupport.appendingPathComponent(legacySupportFolder, isDirectory: true)
        let current = applicationSupport.appendingPathComponent(supportFolder, isDirectory: true)
        if fileManager.fileExists(atPath: legacy.path) && !fileManager.fileExists(atPath: current.path) {
            do {
                try fileManager.moveItem(at: legacy, to: current)
            } catch {
                log.error("could not move \(legacy.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        for (old, new) in keys {
            do {
                guard try new.read() == nil, let value = try old.read() else { continue }
                try new.save(value)
            } catch {
                log.error("could not migrate a Keychain item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
