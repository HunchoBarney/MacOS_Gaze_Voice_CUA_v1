import Foundation
import LocalAuthentication
import Security
import Synchronization

protocol APIKeyStore {
    func read() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
}

/// Unit tests never reach the Mac's Keychain: under a test runner every
/// KeychainAPIKeyStore keeps its items in this process instead, so no test
/// can read the person's keys or raise a Keychain prompt, whatever the
/// items' access lists say. A live test opts in with JARVIS_LIVE_KEYCHAIN=1.
enum KeychainTestGuard {
    static let blocksRealKeychain = runningTests(
        hasXCTest: NSClassFromString("XCTestCase") != nil,
        processName: ProcessInfo.processInfo.processName,
        environment: ProcessInfo.processInfo.environment)

    static func runningTests(hasXCTest: Bool, processName: String, environment: [String: String]) -> Bool {
        (hasXCTest || processName == "swiftpm-testing-helper") && environment["JARVIS_LIVE_KEYCHAIN"] != "1"
    }

    /// Items stored while the guard is on, by service and account.
    static let items = Mutex<[String: String]>([:])
    /// Calls that reached the real Keychain; a test asserts it stays 0.
    static let realKeychainCalls = Atomic<Int>(0)
}

struct KeychainAPIKeyStore: APIKeyStore {
    enum StoreError: LocalizedError {
        case status(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .status(let status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error (\(status))"
            case .invalidData:
                return "The API key stored in Keychain could not be read."
            }
        }
    }

    private let service: String
    private let account: String
    private let allowUserInteraction: Bool

    init(
        service: String = "com.karanvirkang.jarvis",
        account: String = "typesafeAPIKey",
        allowUserInteraction: Bool = true
    ) {
        self.service = service
        self.account = account
        self.allowUserInteraction = allowUserInteraction
    }

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        query.merge(Self.authenticationPolicy(allowUserInteraction: allowUserInteraction)) { _, policy in policy }
        return query
    }

    static func authenticationPolicy(allowUserInteraction: Bool) -> [String: Any] {
        var query: [String: Any] = [:]
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // Legacy file-based macOS Keychain may ignore LAContext alone.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    private var testKey: String { service + "\u{0}" + account }

    func read() throws -> String? {
        if KeychainTestGuard.blocksRealKeychain {
            return KeychainTestGuard.items.withLock { $0[testKey] }
        }
        KeychainTestGuard.realKeychainCalls.add(1, ordering: .relaxed)
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidData
        }
        return value
    }

    func save(_ apiKey: String) throws {
        if KeychainTestGuard.blocksRealKeychain {
            KeychainTestGuard.items.withLock { $0[testKey] = apiKey }
            return
        }
        KeychainTestGuard.realKeychainCalls.add(1, ordering: .relaxed)
        let attributes = [kSecValueData as String: Data(apiKey.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(apiKey.utf8)
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.status(addStatus) }
        } else if status != errSecSuccess {
            throw StoreError.status(status)
        }
    }

    func delete() throws {
        if KeychainTestGuard.blocksRealKeychain {
            _ = KeychainTestGuard.items.withLock { $0.removeValue(forKey: testKey) }
            return
        }
        KeychainTestGuard.realKeychainCalls.add(1, ordering: .relaxed)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.status(status)
        }
    }
}
