import Foundation
import Combine

final class Config: ObservableObject {
    static let shared = Config()

    private let defaults: UserDefaults
    private let keyStore: APIKeyStore
    private let openAIKeyStore: APIKeyStore
    @Published private(set) var apiKeyError: String?

    @Published private(set) var apiKey: String
    /// OpenAI credential for the realtime duplex lane — env `OPENAI_API_KEY`
    /// first, Keychain `openAIAPIKey` second. ChatGPT sign-in cannot mint
    /// realtime sessions; this lane requires an API key.
    @Published private(set) var openAIAPIKey: String

    @Published var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: "microphoneUID") }
    }

    @Published var autoExecute: Bool {
        didSet { defaults.set(autoExecute, forKey: "autoExecute") }
    }

    /// Standing computer-use consent — when on, voice confirmations and the
    /// agent gate approve input without asking. Persisted as the same
    /// standing-grant key the runtime and gate read.
    @Published var alwaysAllowComputerUse: Bool {
        didSet { defaults.set(alwaysAllowComputerUse, forKey: "cuaStandingGrant.computerUseInput") }
    }

    /// Whether the driver draws its animated agent cursor while acting.
    /// Off = silent direct dispatch; on = the overlay glides to each click.
    @Published var agentCursorEnabled: Bool {
        didSet { defaults.set(agentCursorEnabled, forKey: "agentCursorEnabled") }
    }

    /// Spoken replies through the SpeechSynthesizing seam.
    @Published var ttsEnabled: Bool {
        didSet { defaults.set(ttsEnabled, forKey: "ttsEnabled") }
    }

    /// Tap Fn to start capture, tap again to stop — hold-to-talk stays the
    /// default when off.
    @Published var latchMode: Bool {
        didSet { defaults.set(latchMode, forKey: "latchMode") }
    }

    /// Fn+Ctrl hold dictates literal text into the focused field instead of
    /// running an intent.
    @Published var dictationHotkey: Bool {
        didSet { defaults.set(dictationHotkey, forKey: "dictationHotkey") }
    }

    init(
        defaults: UserDefaults = .standard,
        keyStore: APIKeyStore = KeychainAPIKeyStore(),
        openAIKeyStore: APIKeyStore = KeychainAPIKeyStore(account: "openAIAPIKey"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.openAIKeyStore = openAIKeyStore
        self.apiKey = environment["TYPESAFE_API_KEY"] ?? ""
        self.openAIAPIKey = environment["OPENAI_API_KEY"] ?? ""
        self.microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        self.autoExecute = defaults.object(forKey: "autoExecute") as? Bool ?? true
        self.alwaysAllowComputerUse = defaults.object(forKey: "cuaStandingGrant.computerUseInput") as? Bool ?? false
        self.agentCursorEnabled = defaults.object(forKey: "agentCursorEnabled") as? Bool ?? false
        self.ttsEnabled = defaults.object(forKey: "ttsEnabled") as? Bool ?? true
        self.latchMode = defaults.object(forKey: "latchMode") as? Bool ?? false
        self.dictationHotkey = defaults.object(forKey: "dictationHotkey") as? Bool ?? true

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

        if openAIAPIKey.isEmpty {
            openAIAPIKey = (try? openAIKeyStore.read()) ?? ""
        }
    }

    @discardableResult
    func saveOpenAIAPIKey(_ value: String) -> Bool {
        do {
            if value.isEmpty {
                try openAIKeyStore.delete()
            } else {
                try openAIKeyStore.save(value)
            }
            openAIAPIKey = value
            return true
        } catch {
            return false
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
