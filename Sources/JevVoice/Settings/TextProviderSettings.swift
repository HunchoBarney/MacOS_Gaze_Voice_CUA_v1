import Foundation
import Combine
import CryptoKit
import JevVoiceCore

@MainActor
final class TextProviderSettings: ObservableObject {
    static let shared = TextProviderSettings()
    @Published private(set) var endpoint: String
    @Published private(set) var model: String
    @Published private(set) var message = "Optional Groq reasoning and text generation. Jev remains the action selector."
    @Published private(set) var busy = false
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var revision = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = defaults.string(forKey: "textProviderEndpoint") ?? "https://api.groq.com/openai/v1"
        model = defaults.string(forKey: "textProviderModel") ?? "qwen/qwen3.8-27b"
    }
    var configured: Bool { defaults.string(forKey: "textProviderEndpoint") != nil }

    private func store(_ url: URL) -> KeychainAPIKeyStore {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return KeychainAPIKeyStore(account: "textProvider-" + digest)
    }
    @discardableResult
    func save(endpoint: String, model: String, newKey: String) -> Bool {
        do {
            let url = try TextGenerationClient.endpoint(endpoint)
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextGenerationClient.Failure.missingModel }
            if !newKey.isEmpty { try store(url).save(newKey) }
            cancel()
            self.endpoint = url.absoluteString; self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(self.endpoint, forKey: "textProviderEndpoint")
            defaults.set(self.model, forKey: "textProviderModel")
            message = "Saved. Test the selected provider before using generation."
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func removeKey() {
        do { try store(TextGenerationClient.endpoint(endpoint)).delete(); cancel(); message = "Provider key removed." }
        catch { message = error.localizedDescription }
    }
    /// Raw key for the configured endpoint — the codex runtime needs the
    /// value itself to inject as a child env var, not a built client.
    func providerKey() throws -> String {
        try store(TextGenerationClient.endpoint(endpoint)).read() ?? ""
    }

    func client() throws -> TextGenerationClient {
        let url = try TextGenerationClient.endpoint(endpoint)
        let key = try store(url).read() ?? ""
        guard !key.isEmpty || ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host ?? "") else { throw TextGenerationClient.Failure.missingKey }
        return TextGenerationClient(baseURL: url, model: model, key: key)
    }
    func test() {
        guard !busy else { return }
        let id = UUID(); revision = id; busy = true; message = "Testing provider with disposable text…"
        task = Task {
            defer { if revision == id { busy = false; task = nil } }
            do {
                let start = ContinuousClock.now
                let result = try await client().generate(prompt: "Summarize the context in one short sentence.", context: "This is a disposable Jarvis connection test. The blue notebook is on the desk.", reasoning: true)
                try Task.checkCancellation()
                guard revision == id else { return }
                message = "Provider responded in \(start.duration(to: .now)): \(result)"
            } catch { if revision == id { message = error.localizedDescription } }
        }
    }
    func cancel() { revision = UUID(); task?.cancel(); task = nil; busy = false }
}
