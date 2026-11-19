import Foundation
import LocalAuthentication
import Security

protocol APIKeyStore {
    var noninteractive: APIKeyStore { get }
    func read() throws -> String?
    func save(_ apiKey: String) throws
    func migrateLegacyKey(_ apiKey: String) throws
    func delete() throws
}

extension APIKeyStore {
    var noninteractive: APIKeyStore { self }
    func migrateLegacyKey(_ apiKey: String) throws { try save(apiKey) }
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

    var noninteractive: APIKeyStore {
        KeychainAPIKeyStore(service: service, account: account, allowUserInteraction: false)
    }

    init(
        service: String = "com.chriswozniczek.jevvoice",
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

    func read() throws -> String? {
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
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.status(status)
        }
    }

    func migrateLegacyKey(_ apiKey: String) throws {
        var item = query
        item[kSecValueData as String] = Data(apiKey.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.status(status) }
    }
}
