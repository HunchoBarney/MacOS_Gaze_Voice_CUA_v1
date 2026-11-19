import SwiftUI
import ServiceManagement

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
    @ObservedObject var controller: VoiceController
    @ObservedObject var config: Config
    @ObservedObject var microphones: MicrophoneCatalog
    @ObservedObject var input: FnInputMonitor
    @ObservedObject var navigation: SettingsNavigation
    var collapse: () -> Void
    @StateObject private var cuaSetup = CuaSetup()
    @State private var apiKeyDraft = ""
    @State private var apiKeySaved = false
    @FocusState private var typeSafeFieldFocused: Bool
    private enum HandsFreeFocus { case mode, action }
    @FocusState private var handsFreeFocus: HandsFreeFocus?
    @State private var openAIKeyDraft = ""
    @State private var openAIKeySaved = false
    /// Tracker-side settings — optimistic local copies, read back from
    /// `/snapshot.settings` when the card appears. `eyeSettingsTouched`
    /// marks a user edit so a late read can't overwrite a newer choice.
    @State private var eyeDotScale = 1.0
    /// Tracker default is ON — an unset `dwell_lock` leaves the runtime's
    /// `anchorEnabled = true` in charge (electron/main.cjs checks the tray
    /// item with `!== false`). Mirroring that keeps an un-read-back card
    /// from claiming the anchor is off while the tracker is locking.
    @State private var eyeDwellLock = true
    /// Gaze-cursor visibility — default hidden (Vision Pro-style); this
    /// mirrors the tracker's `gaze_dot_visible` setting.
    @State private var eyeDotVisible = false
    @State private var eyeSettingsTouched = false
    /// Dwell auto-click — app-side UserDefaults; the service reloads on
    /// the write (`DwellPolicy.modeKey`, values are `DwellPolicy.Mode`
    /// raws). Defaults match `DwellPolicy.load()`.
    @State private var dwellMode = DwellPolicy.load().mode.rawValue
    /// Tracker launch geometry — written straight to UserDefaults; the
    /// spawn code maps the keys to the tracker's launch flags
    /// (--display-size-inch, --gaze-projection-mode, --camera-fov), so
    /// changes only take effect on the next tracker start. 0/"" = unset,
    /// which leaves the tracker's own default in charge.
    @State private var trackerDisplaySize = UserDefaults.standard.object(forKey: "trackerDisplaySizeInch") as? Double ?? 0
    @State private var trackerProjectionMode = UserDefaults.standard.string(forKey: "trackerProjectionMode") ?? ""
    @State private var trackerCameraFov = UserDefaults.standard.integer(forKey: "trackerCameraFovDeg")
    /// The spend gauge — injected from the @MainActor shell (its shared
    /// singleton is MainActor-isolated, so a property default can't
    /// reach it from a nonisolated view init).
    @ObservedObject var spend: SpendCounter

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
                            selectSection(section)
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
        .onAppear {
            apiKeyDraft = config.apiKey
            openAIKeyDraft = config.openAIAPIKey
            config.codexAuth.refresh()
        }
        .onChange(of: apiKeyDraft) { apiKeySaved = false }
        .onChange(of: openAIKeyDraft) { openAIKeySaved = false }
    }

    private var voiceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingChecklistCard(afterFix: {
                controller.refreshPermissions()
                input.refresh()
            })
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Voice", systemImage: "bolt.horizontal.circle").font(.headline)
                    Text("OpenAI API key").font(.callout)
                    HStack {
                        SecureField("sk-…", text: $openAIKeyDraft).textFieldStyle(.roundedBorder).onSubmit(saveOpenAIKey)
                        Button("Save", action: saveOpenAIKey).buttonStyle(.borderedProminent)
                    }
                    if openAIKeySaved {
                        Text(openAIKeyDraft.isEmpty ? "Saved key removed" : "Saved in Keychain")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("OpenAI handles live speech and replies. Jev and native Mac controls handle your tasks. Your key is stored in macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Speak replies aloud", isOn: $config.ttsEnabled)
                    Toggle("Hands-free conversation", isOn: $config.handsFreeEnabled)
                        .focused($handsFreeFocus, equals: .mode)
                    if config.handsFreeEnabled {
                        let controls = controller.handsFreeControls
                        HStack {
                            Label(controls.label, systemImage: controls.symbol)
                            Spacer()
                            if let action = controls.toggle {
                                Button(action.rawValue) {
                                    controller.applyHandsFreeToggle(action)
                                    if handsFreeFocus == .action, controller.handsFreeControls.toggle == nil {
                                        handsFreeFocus = .mode
                                    }
                                }
                                .focused($handsFreeFocus, equals: .action)
                            }
                        }
                        .onChange(of: controls.toggle) { next in
                            if next == nil, handsFreeFocus == .action { handsFreeFocus = .mode }
                        }
                        Text(controls.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Use TypeSafe for unfamiliar requests", isOn: $config.semanticAppSuggestions)
                    if config.needsAPIKeyRetry {
                        Button("Review TypeSafe Keychain access…") { selectSection(.commands) }
                    }
                    Text("Enabled by default when a TypeSafe key is available. "
                         + "Sends unfamiliar final request text, app names/identities "
                         + "and default browser/mail app roles to TypeSafe. "
                         + "Clear requests to open or focus an app run without another approval. "
                         + "Unclear targets ask which app. Other requests keep the existing workflow.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                    Text("While hands-free listening is on, microphone audio goes to OpenAI. Pause listening to stop sending audio. Fn is an optional manual turn. Changing input ends the current capture.")
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
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("App", systemImage: "app").font(.headline)
                    Toggle("Launch at login", isOn: $config.launchAtLogin)
                    Text(loginServiceStatusText)
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = config.launchAtLoginError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Divider()
                    Text("Model calls today: \(spend.today)")
                        .font(.callout)
                    Text("Realtime turns, command calls, and chooser rounds — counted locally, never sent anywhere.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The login-item row reports what ServiceManagement actually holds —
    /// never just the toggle's desired state.
    private var loginServiceStatusText: String {
        switch config.loginServiceStatus {
        case .enabled:
            return "Registered — Jev Voice opens when you log in."
        case .requiresApproval:
            return "Needs approval — allow Jev Voice in System Settings → General → Login Items."
        case .notRegistered:
            return "Not registered — Jev Voice won't start at login."
        case .notFound:
            return "Unavailable outside an installed app bundle."
        @unknown default:
            return ""
        }
    }

    private var commandSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Jev connection", systemImage: "bolt").font(.headline)
                    Text("TypeSafe API key").font(.callout)
                    HStack {
                        SecureField("ts-…", text: $apiKeyDraft).textFieldStyle(.roundedBorder).onSubmit(saveAPIKey)
                            .accessibilityLabel("TypeSafe API key")
                            .focused($typeSafeFieldFocused)
                        Button("Save", action: saveAPIKey).buttonStyle(.borderedProminent)
                            .disabled(!config.canSaveAPIKey(apiKeyDraft))
                    }
                    if !config.needsAPIKeyRetry {
                        Text("Stored in macOS Keychain. Clear the field and save to remove the stored key.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = config.apiKeyError { Text(error).font(.caption).foregroundStyle(.orange) }
                    else if apiKeySaved { Text(apiKeyDraft.isEmpty ? "Saved key removed" : "Saved in Keychain").font(.caption).foregroundStyle(.secondary) }
                    if config.needsAPIKeyRetry {
                        Button("Retry Keychain access") {
                            apiKeyDraft = config.retryAPIKeyAccess(keeping: apiKeyDraft)
                            if !config.needsAPIKeyRetry { typeSafeFieldFocused = true }
                        }
                    }
                }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Computer control", systemImage: "cursorarrow.motionlines").font(.headline)
                    Text(cuaSetup.message).font(.caption).foregroundStyle(.secondary)
                    Text("This check opens its own disposable TextEdit document and verifies a Jev-selected insertion.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Test computer control") { cuaSetup.verify(apiKey: config.apiKey) }.disabled(cuaSetup.busy)
                        Button("Test browser") { cuaSetup.verify(apiKey: config.apiKey, browser: true) }.disabled(cuaSetup.busy)
                        if cuaSetup.busy { ProgressView().controlSize(.small); Button("Cancel") { cuaSetup.cancel() } }
                    }
                    Toggle("Show agent cursor", isOn: $config.agentCursorEnabled)
                    Text(config.agentCursorEnabled
                         ? "The agent cursor glides to each action it can place. Accessibility-only actions still act directly — the driver cannot draw a pointer for a call that has no on-screen point."
                         : "Actions dispatch directly to the target without an animated cursor. Every click follows this rule — the mode never mixes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Interface sounds", isOn: $config.sounds)
                }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Eye tracking", systemImage: "eye").font(.headline)
                    Toggle("Track my eyes", isOn: $config.gazeTracking)
                    Text("Launches the bundled tracker so gaze verbs — “click”, “what is this” — act where you're looking. Off leaves the tracker closed and those verbs decline.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Dot size", selection: Binding(
                        get: { eyeDotScale },
                        set: { value in
                            eyeSettingsTouched = true
                            eyeDotScale = value
                            Task { try? await TrackerControl.post(action: "dot_scale", value: value) }
                        })) {
                        Text("Small").tag(0.8)
                        Text("Default").tag(1.0)
                        Text("Large").tag(1.25)
                    }.pickerStyle(.segmented)
                    Toggle("Show gaze dot", isOn: Binding(
                        get: { eyeDotVisible },
                        set: { value in
                            eyeSettingsTouched = true
                            eyeDotVisible = value
                            Task { try? await TrackerControl.post(action: "gaze_dot", value: value) }
                        }))
                    Text("Off is the Vision Pro posture — the thing you're looking at highlights itself instead of a dot chasing your eyes. Turn it on while you dial in accuracy.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Dwell lock", isOn: Binding(
                        get: { eyeDwellLock },
                        set: { value in
                            eyeSettingsTouched = true
                            eyeDwellLock = value
                            Task { try? await TrackerControl.post(action: "dwell_lock", value: value) }
                        }))
                    Picker("Dwell auto-click", selection: Binding(
                        get: { dwellMode },
                        set: { value in
                            guard let mode = DwellPolicy.Mode(rawValue: value) else { return }
                            var policy = DwellPolicy.load()
                            policy.mode = mode
                            policy.save()
                            dwellMode = policy.mode.rawValue
                            Task { @MainActor in GazeService.shared.reloadPolicy() }
                        })) {
                        Text("Off").tag(DwellPolicy.Mode.off.rawValue)
                        Text("Safe").tag(DwellPolicy.Mode.safe.rawValue)
                        Text("All").tag(DwellPolicy.Mode.all.rawValue)
                    }.pickerStyle(.segmented)
                    Text("Holding your gaze clicks for you — Safe only on verified controls, All adds windows and text hits, Off keeps gaze verbs voice-only. Denied phrases never fire.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Tap Fn to click what I'm looking at", isOn: $config.tapToGazeClick)
                    Text("A Fn tap while your eyes are on a target clicks it directly — no voice turn needed. Off keeps Fn taps as ordinary captures.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Dot size and dwell lock are tracker-side settings — read back when this opens, applied on change.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Tracker geometry") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Display size", selection: Binding(
                                get: { trackerDisplaySize },
                                set: { value in
                                    trackerDisplaySize = value
                                    if value > 0 {
                                        UserDefaults.standard.set(value, forKey: "trackerDisplaySizeInch")
                                    } else {
                                        UserDefaults.standard.removeObject(forKey: "trackerDisplaySizeInch")
                                    }
                                })) {
                                Text("Auto").tag(0.0)
                                Text("24″").tag(24.0)
                                Text("27″").tag(27.0)
                                Text("32″").tag(32.0)
                            }
                            Picker("Projection", selection: Binding(
                                get: { trackerProjectionMode },
                                set: { value in
                                    trackerProjectionMode = value
                                    if value.isEmpty {
                                        UserDefaults.standard.removeObject(forKey: "trackerProjectionMode")
                                    } else {
                                        UserDefaults.standard.set(value, forKey: "trackerProjectionMode")
                                    }
                                })) {
                                Text("Auto").tag("")
                                Text("Binocular (screen)").tag("binocular-screen")
                                Text("Legacy").tag("legacy")
                            }
                            Picker("Camera FOV", selection: Binding(
                                get: { trackerCameraFov },
                                set: { value in
                                    trackerCameraFov = value
                                    if value > 0 {
                                        UserDefaults.standard.set(value, forKey: "trackerCameraFovDeg")
                                    } else {
                                        UserDefaults.standard.removeObject(forKey: "trackerCameraFovDeg")
                                    }
                                })) {
                                Text("Auto").tag(0)
                                Text("60°").tag(60)
                                Text("90°").tag(90)
                                Text("120°").tag(120)
                            }
                            Text("Launch flags for the tracker — Auto leaves the key unset. Changes apply on the next tracker start.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 6)
                    }.font(.callout)
                }
                .task {
                    guard let status = try? await TrackerControl().status() else { return }
                    // A read that resolved after the user edited must not
                    // paint over the newer choice.
                    guard !eyeSettingsTouched else { return }
                    if let scale = status.dotScale {
                        eyeDotScale = [0.8, 1.0, 1.25].min(by: { abs($0 - scale) < abs($1 - scale) }) ?? scale
                    }
                    if let lock = status.dwellLock { eyeDwellLock = lock }
                    if let visible = status.dotVisible { eyeDotVisible = visible }
                }
            }
            PlannerCard(auth: config.codexAuth, config: config)
            VoiceCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Command confirmation", systemImage: "checkmark.shield").font(.headline)
                    Toggle("Run commands automatically", isOn: $config.autoExecute)
                    Text("Completed commands can run while you hold Fn. Release to finish remaining speech and dictated text. Turn this off to review commands before they run.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Always allow computer use", isOn: $config.alwaysAllowComputerUse)
                    Text(config.alwaysAllowComputerUse
                         ? "Input actions run without asking — every task and delegated agent included. Deny lists and focus rules still apply."
                         : "Actions that change something ask first. Turn this on to approve all computer use up front.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Model confidence is available in Activity diagnostics. It does not interrupt ordinary commands. Deletion and purchasing are not supported by this app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset remembered permissions") { CuaStandingGrants.reset() }.controlSize(.small)
                    Text("Capabilities you approve — like browser page access or menu focus per app — are remembered so they are never re-asked. Reset to be asked again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("On-device", systemImage: "cpu").font(.headline)
                    Text("Local recognition supplies the transcript for every voice turn. Commands are admitted only after the whole hold is finalized.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("If speech is unavailable or a target is uncertain, Jev asks or refuses rather than running a second transcription path.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectSection(_ section: SettingsNavigation.Section) {
        if navigation.section == .voice && section != .voice { controller.stopMicrophoneTest() }
        navigation.section = section
    }

    private func saveAPIKey() { apiKeySaved = config.saveAPIKey(apiKeyDraft) }
    private func saveOpenAIKey() { openAIKeySaved = config.saveOpenAIAPIKey(openAIKeyDraft) }
}

/// Planner lane card — ChatGPT sign-in through the vendored codex binary
/// plus the live planner toggle. Watches CodexAuth directly so the spinner,
/// device code and status line update as the flow progresses.
private struct PlannerCard: View {
    @ObservedObject var auth: CodexAuth
    @ObservedObject var config: Config

    var body: some View {
        VoiceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Planner", systemImage: "sparkles").font(.headline)
                HStack(spacing: 8) {
                    statusLine
                    Spacer()
                    if auth.signInInFlight { ProgressView().controlSize(.small) }
                    if case .signedIn = auth.chatGPTAuthStatus, !auth.signInInFlight {
                        // Signed in — nothing to do.
                    } else {
                        Button("Sign in with ChatGPT") { auth.beginChatGPTSignIn() }
                            .disabled(auth.signInInFlight || !auth.binaryAvailable)
                    }
                }
                if !auth.binaryAvailable {
                    Text("The bundled agent runtime is missing — rebuild the app bundle to sign in.")
                        .font(.caption).foregroundStyle(.orange)
                } else if let code = auth.signInCode {
                    Text("A sign-in page opened in your browser — enter code \(code) there. It's on your clipboard.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if auth.signInOpenedTerminal {
                    Text("Finish signing in in the Terminal window that opened; this updates when it completes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Signs in Codex for delegated agents. Multi-step voice requests plan through your text provider or OpenAI key — no sign-in needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch auth.chatGPTAuthStatus {
            case .signedIn(let label):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                Text(label.map { "Signed in as \($0)" } ?? "Signed in").font(.callout)
            case .signedOut:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("Not signed in").font(.callout)
            case .unreachable:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text("Codex runtime unavailable").font(.callout)
            }
        }
    }
}
