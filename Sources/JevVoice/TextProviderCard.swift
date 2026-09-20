import SwiftUI

struct TextProviderCard: View {
    @ObservedObject private var provider = TextProviderSettings.shared
    @State private var endpoint = ""
    @State private var model = ""
    @State private var key = ""
    var body: some View {
        VoiceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Reasoning and text", systemImage: "text.bubble").font(.headline)
                Menu("Provider preset") {
                    Button("Groq · Qwen 3.8") { endpoint = "https://api.groq.com/openai/v1"; model = "qwen/qwen3.8-27b"; key = "" }
                    Button("Cerebras") { endpoint = "https://api.cerebras.ai/v1"; model = "qwen-3.8-27b"; key = "" }
                    Button("Gemini compatible") { endpoint = "https://generativelanguage.googleapis.com/v1beta/openai"; model = "gemini-3.8-flash"; key = "" }
                    Button("Local / custom") { endpoint = "http://127.0.0.1:8080/v1"; model = ""; key = "" }
                }
                TextField("Provider base URL", text: $endpoint).textFieldStyle(.roundedBorder)
                TextField("Model ID", text: $model).textFieldStyle(.roundedBorder)
                SecureField("New provider API key (leave blank to keep saved key)", text: $key).textFieldStyle(.roundedBorder)
                Text("Keys are stored separately from Jev and bound to this endpoint. Tests use disposable text. Other presets have not been live-verified.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save provider") { if provider.save(endpoint: endpoint, model: model, newKey: key) { key = "" } }
                    Button("Test saved provider") { provider.test() }.disabled(provider.busy)
                    if provider.busy { Button("Cancel test") { provider.cancel() } }
                    Button("Remove saved key") { provider.removeKey() }
                }
                Text(provider.message).font(.caption).textSelection(.enabled)
            }
        }.onAppear { endpoint = provider.endpoint; model = provider.model }
    }
}
