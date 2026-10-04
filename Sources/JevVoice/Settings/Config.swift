import Foundation
import Combine

final class Config: ObservableObject {
    static let shared = Config()

    private let defaults: UserDefaults
    private let keyStore: APIKeyStore
    private let elevenLabsKeyStore: APIKeyStore
    @Published private(set) var apiKeyError: String?

    @Published private(set) var apiKey: String
    /// ElevenLabs TTS credential — env `ELEVENLABS_API_KEY` first, Keychain
    /// `elevenLabsAPIKey` second. Empty routes spoken replies to the system
    /// voice instead of the cloud voice.
    @Published private(set) var elevenLabsAPIKey: String

    @Published var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: "microphoneUID") }
    }

    @Published var autoExecute: Bool {
        didSet { defaults.set(autoExecute, forKey: "autoExecute") }
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
        elevenLabsKeyStore: APIKeyStore = KeychainAPIKeyStore(account: "elevenLabsAPIKey"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.elevenLabsKeyStore = elevenLabsKeyStore
        self.apiKey = environment["TYPESAFE_API_KEY"] ?? ""
        self.elevenLabsAPIKey = environment["ELEVENLABS_API_KEY"] ?? ""
        self.microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        self.autoExecute = defaults.object(forKey: "autoExecute") as? Bool ?? true
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

        if elevenLabsAPIKey.isEmpty {
            elevenLabsAPIKey = (try? elevenLabsKeyStore.read()) ?? ""
        }
    }

    @discardableResult
    func saveElevenLabsAPIKey(_ value: String) -> Bool {
        do {
            if value.isEmpty {
                try elevenLabsKeyStore.delete()
            } else {
                try elevenLabsKeyStore.save(value)
            }
            elevenLabsAPIKey = value
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
