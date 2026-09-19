import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: VoiceController
    @ObservedObject private var config = Config.shared
    @State private var apiKeyDraft = ""
    @State private var apiKeySaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { controller.showSettings = false }
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("TypeSafe API key").font(.caption)
                HStack {
                    SecureField("ts-…", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveAPIKey)
                    Button("Save", action: saveAPIKey)
                }
                if let error = config.apiKeyError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if apiKeySaved {
                    Text(apiKeyDraft.isEmpty ? "Saved key removed" : "Saved in Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Confidence threshold: \(Int(config.confidenceThreshold * 100))%")
                    .font(.caption)
                Slider(value: $config.confidenceThreshold, in: 0...1)
            }

            Toggle("Auto-execute high-confidence decisions", isOn: $config.autoExecute)
                .font(.caption)

            Spacer()
        }
        .onAppear { apiKeyDraft = config.apiKey }
        .onChange(of: apiKeyDraft) { _ in apiKeySaved = false }
    }

    private func saveAPIKey() {
        apiKeySaved = config.saveAPIKey(apiKeyDraft)
    }
}
