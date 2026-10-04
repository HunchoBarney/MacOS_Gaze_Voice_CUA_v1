import Foundation
import Combine

final class Config: ObservableObject {
    static let shared = Config()

    private let defaults: UserDefaults
    private let keyStore: APIKeyStore
    @Published private(set) var apiKeyError: String?

    @Published private(set) var apiKey: String

    @Published var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: "microphoneUID") }
    }

    @Published var confidenceThreshold: Double {
        didSet { defaults.set(confidenceThreshold, forKey: "confidenceThreshold") }
    }

    @Published var autoExecute: Bool {
        didSet { defaults.set(autoExecute, forKey: "autoExecute") }
    }

    /// Whether the driver draws its animated agent cursor while acting.
    /// Off = silent direct dispatch; on = the overlay glides to each click.
    @Published var agentCursorEnabled: Bool {
        didSet { defaults.set(agentCursorEnabled, forKey: "agentCursorEnabled") }
    }

    init(
        defaults: UserDefaults = .standard,
        keyStore: APIKeyStore = KeychainAPIKeyStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.apiKey = environment["TYPESAFE_API_KEY"] ?? ""
        self.microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        self.confidenceThreshold = defaults.object(forKey: "confidenceThreshold") == nil
            ? 0.7
            : defaults.double(forKey: "confidenceThreshold")
        self.autoExecute = defaults.object(forKey: "autoExecute") as? Bool ?? true
        self.agentCursorEnabled = defaults.object(forKey: "agentCursorEnabled") as? Bool ?? false

        do {
            if let stored = try keyStore.read() {
                apiKey = stored
                defaults.removeObject(forKey: "typesafeAPIKey")
            } else if let legacy = defaults.string(forKey: "typesafeAPIKey"), !legacy.isEmpty {
                apiKey = legacy
                // Keep the old value until the durable Keychain write succeeds.
                try keyStore.save(legacy)
                defaults.removeObject(forKey: "typesafeAPIKey")
            } else {
                defaults.removeObject(forKey: "typesafeAPIKey")
            }
        } catch {
            apiKeyError = "Could not load or migrate the API key in Keychain: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        do {
            if value.isEmpty {
                try keyStore.delete()
            } else {
                try keyStore.save(value)
            }
            apiKey = value
            defaults.removeObject(forKey: "typesafeAPIKey")
            apiKeyError = nil
            return true
        } catch {
            apiKeyError = "Could not save the API key in Keychain: \(error.localizedDescription)"
            return false
        }
    }
}
