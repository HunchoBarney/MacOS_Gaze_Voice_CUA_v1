import SwiftUI

@MainActor
final class SettingsNavigation: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case voice = "Voice", commands = "Commands", activity = "Activity"
        var id: String { rawValue }
        var symbol: String { switch self { case .voice: return "waveform"; case .commands: return "command"; case .activity: return "clock" } }
        var subtitle: String {
            switch self {
            case .voice: return "Your voice, one key away."
            case .commands: return "Choose how your Mac responds."
            case .activity: return "Review what you said and what happened."
            }
        }
    }
    @Published var section: Section = .voice
}

struct SettingsView: View {
    @ObservedObject private var speechAssets = SpeechAssets.shared
    @ObservedObject var controller: VoiceController
    @ObservedObject var config: Config
    @ObservedObject var microphones: MicrophoneCatalog
    @ObservedObject var input: FnInputMonitor
    @ObservedObject var navigation: SettingsNavigation
    var collapse: () -> Void
    @StateObject private var cuaSetup = CuaSetup()
    @State private var apiKeyDraft = ""
    @State private var apiKeySaved = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 23, weight: .semibold)).foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jev Voice").font(.system(size: 16, weight: .semibold))
                        Text("Made for your Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 18)
                VStack(spacing: 5) {
                    ForEach(SettingsNavigation.Section.allCases) { section in
                        Button {
                            if navigation.section == .voice && section != .voice { controller.stopMicrophoneTest() }
                            navigation.section = section
                        } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(navigation.section == section ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Text("HOLD fn TO SPEAK").font(.system(size: 10, weight: .semibold)).tracking(0.7)
                    Text("Release to finish.\nEscape to cancel.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                }.padding(.bottom, 12)
            }.padding(.horizontal, 18).frame(width: 170).background(.ultraThinMaterial)
            Divider()
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(navigation.section.rawValue).font(.system(size: 28, weight: .semibold))
                            Spacer()
                            Button(action: collapse) {
                                Label("Collapse", systemImage: "arrow.down.right.and.arrow.up.left")
                            }.help("Return to the pill").accessibilityLabel("Collapse to pill")
                        }
                        Text(navigation.section.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    }.padding(.top, 8).id("settingsTop")
                    switch navigation.section {
                    case .voice: voiceSettings
                    case .commands: commandSettings
                    case .activity: ActivityView(controller: controller)
                    }
                    Spacer(minLength: 8)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
              }.background(Color(nsColor: .windowBackgroundColor))
                .onAppear { proxy.scrollTo("settingsTop", anchor: .top) }
                .onChange(of: navigation.section) { proxy.scrollTo("settingsTop", anchor: .top) }
            }
        }
        .frame(minWidth: 740, minHeight: 520)
        .tint(.accentColor)
        .onAppear { apiKeyDraft = config.apiKey }
        .onChange(of: apiKeyDraft) { apiKeySaved = false }
    }

    private var voiceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VoiceCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("On-device speech", systemImage: "waveform").font(.headline)
                    Text(speechAssets.message).font(.callout)
                    Button("Prepare speech") { Task { await speechAssets.refresh(install: true) } }
                        .disabled(speechAssets.preparing || speechAssets.ready)
                }.task { await speechAssets.refresh() }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Push to talk", systemImage: "keyboard").font(.headline)
                    HStack(alignment: .top, spacing: 20) {
                        Text("fn").font(.system(size: 27, weight: .medium)).frame(width: 58, height: 54)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Hold. Speak. Release.").font(.system(size: 14, weight: .medium))
                            Text(input.message).font(.callout).foregroundStyle(input.ready ? Color.secondary : Color.orange)
                            Text("If the Globe key opens emoji or Dictation, set “Press 🌐 key to” to “Do Nothing” in Keyboard settings.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Keyboard settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
                        Button("Check shortcut") { input.refresh(); controller.refreshPermissions() }
                    }.controlSize(.small)
                }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Microphone", systemImage: "mic").font(.headline)
                    Picker("Input", selection: $config.microphoneUID) {
                        Text("System Default — \(microphones.defaultName)").tag("")
                        ForEach(microphones.devices) { device in Text(device.name).tag(device.uid) }
                        if !config.microphoneUID.isEmpty && !microphones.devices.contains(where: { $0.uid == config.microphoneUID }) {
                            Text("Selected microphone unavailable").tag(config.microphoneUID)
                        }
                    }.labelsHidden()
                    Text("The microphone stays ready while the app is active. Only Fn-held audio is transcribed; idle audio is discarded. Changing input ends the current hold.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(controller.microphoneReadiness).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(controller.isMicrophoneTest ? "Stop test" : "Test microphone") {
                            controller.isMicrophoneTest ? controller.stopMicrophoneTest() : controller.startMicrophoneTest()
                        }.disabled(!controller.canBegin && !controller.isMicrophoneTest)
                        Spacer()
                        VoiceWaveform(level: controller.isMicrophoneTest ? controller.audioLevel : 0, color: .mint)
                    }
                    if controller.isMicrophoneTest {
                        Text(controller.inputName.isEmpty ? "Starting microphone…" : "Listening to \(controller.inputName). No command will run.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if case .error(let message) = controller.status {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Permissions", systemImage: "hand.raised").font(.headline)
                    ForEach(Permission.allCases) { permission in
                        HStack {
                            Image(systemName: controller.missingPermissions.contains(permission) ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(controller.missingPermissions.contains(permission) ? Color.secondary : Color.mint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.rawValue).font(.callout)
                                Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if controller.missingPermissions.contains(permission) {
                                Button(permission.canPrompt ? "Allow" : "Open settings") {
                                    Task { await permission.request(); controller.refreshPermissions(); input.refresh() }
                                }.controlSize(.small)
                            }
                        }
                    }
                    Text("If access looks enabled in macOS but unavailable here after a rebuild, remove the old app entry and add this build again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var commandSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextProviderCard()
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Jev connection", systemImage: "bolt").font(.headline)
                    Text("TypeSafe API key").font(.callout)
                    HStack {
                        SecureField("ts-…", text: $apiKeyDraft).textFieldStyle(.roundedBorder).onSubmit(saveAPIKey)
                        Button("Save", action: saveAPIKey).buttonStyle(.borderedProminent)
                    }
                    Text("Stored in macOS Keychain. Clear the field and save to remove the stored key.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = config.apiKeyError { Text(error).font(.caption).foregroundStyle(.orange) }
                    else if apiKeySaved { Text(apiKeyDraft.isEmpty ? "Saved key removed" : "Saved in Keychain").font(.caption).foregroundStyle(.secondary) }
                }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Cua computer control", systemImage: "cursorarrow.motionlines").font(.headline)
                    Text(cuaSetup.message).font(.caption).foregroundStyle(.secondary)
                    Text("This check opens its own disposable TextEdit document and verifies a Jev-selected insertion. Voice migration is still in progress.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Test Cua + Jev") { cuaSetup.verify(apiKey: config.apiKey) }.disabled(cuaSetup.busy)
                        Button("Test browser") { cuaSetup.verify(apiKey: config.apiKey, browser: true) }.disabled(cuaSetup.busy)
                        if cuaSetup.busy { ProgressView().controlSize(.small); Button("Cancel") { cuaSetup.cancel() } }
                    }
                }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Command confirmation", systemImage: "checkmark.shield").font(.headline)
                    Toggle("Run commands automatically", isOn: $config.autoExecute)
                    Text("Completed commands can run while you hold Fn. Release to finish remaining speech and dictated text. Turn this off to review commands before they run.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Model confidence is available in Activity diagnostics. It does not interrupt ordinary commands. Deletion and purchasing are not supported by this app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func saveAPIKey() { apiKeySaved = config.saveAPIKey(apiKeyDraft) }
}
