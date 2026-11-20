import SwiftUI
import ServiceManagement

@MainActor
final class SettingsNavigation: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case voice = "Settings", activity = "Activity"
        var id: String { rawValue }
        var symbol: String { switch self { case .voice: return "gearshape"; case .activity: return "clock" } }
        var subtitle: String {
            switch self {
            case .voice: return "How Jarvis listens, talks and helps."
            case .activity: return "What you asked and what Jarvis did."
            }
        }
    }
    enum Anchor: String { case eyeTracking, permissions, advanced }
    @Published var section: Section = .voice
    /// Part of the page to bring into view when the window opens.
    @Published var anchor: Anchor?
}

/// One page of settings, in the order people reach for them.
struct SettingsView: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var config: Config
    @ObservedObject var microphones: MicrophoneCatalog
    @ObservedObject var input: FnInputMonitor
    @ObservedObject var navigation: SettingsNavigation
    @StateObject private var accuracyCheck = AccuracyCheck()
    /// Eye-tracker settings — optimistic local copies, read back from the
    /// tracker when the section appears. `eyeSettingsTouched` marks a user
    /// edit so a late read can't overwrite a newer choice.
    @State private var eyeDotScale = 1.0
    /// Tracker default is ON — an unset `dwell_lock` leaves the runtime's
    /// anchor on, so an un-read-back toggle mustn't claim it's off.
    @State private var eyeDwellLock = true
    @State private var eyeDotVisible = false
    @State private var eyeSettingsTouched = false
    @State private var dwellMode = DwellPolicy.load().mode.rawValue
    @State private var openAIKeyDraft = ""
    @State private var openAIKeySaved = false
    @State private var typeSafeKeyDraft = ""
    @State private var typeSafeKeySaved = false
    @State private var advancedOpen = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 23, weight: .semibold)).foregroundStyle(.mint)
                        .accessibilityHidden(true)
                    Text("Jarvis").font(.system(size: 17, weight: .semibold))
                }.padding(.top, 18)
                VStack(spacing: 5) {
                    ForEach(SettingsNavigation.Section.allCases) { section in
                        Button {
                            if section != .voice { controller.stopMicrophoneTest() }
                            navigation.section = section
                        } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(navigation.section == section ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(navigation.section == section ? .isSelected : [])
                    }
                }
                Spacer()
            }.padding(.horizontal, 18).frame(width: 170).background(.ultraThinMaterial)
            Divider()
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(navigation.section.rawValue).font(.system(size: 28, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(navigation.section.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                    }.padding(.top, 8).id("settingsTop")
                    switch navigation.section {
                    case .voice: settings
                    case .activity: ActivityView(controller: controller)
                    }
                    Spacer(minLength: 8)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
              }.background(Color(nsColor: .windowBackgroundColor))
                .onAppear { scroll(proxy) }
                .onChange(of: navigation.section) { scroll(proxy) }
                .onChange(of: navigation.anchor) { scroll(proxy) }
            }
        }
        .frame(minWidth: 740, minHeight: 520)
        .tint(.accentColor)
        .onAppear { config.codexAuth.refresh() }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if navigation.section == .voice, let anchor = navigation.anchor {
            if anchor == .advanced { advancedOpen = true }
            proxy.scrollTo(anchor.rawValue, anchor: .top)
            navigation.anchor = nil
        } else {
            proxy.scrollTo("settingsTop", anchor: .top)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            listening
            replies
            doingThings
            eyeTracking.id(SettingsNavigation.Anchor.eyeTracking.rawValue)
            permissions.id(SettingsNavigation.Anchor.permissions.rawValue)
            general
            if config.showsKeyFields {
                advanced.id(SettingsNavigation.Anchor.advanced.rawValue)
            }
        }
    }

    // MARK: - Listening

    private var listening: some View {
        SettingsSection(title: "Listening", symbol: "ear") {
            Picker("How Jarvis listens", selection: $config.listeningMode) {
                ForEach(ListeningPolicy.current.offeredModes, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title(name: config.assistantName)).font(.system(size: 14))
                        Text(mode.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .tag(mode)
                    .padding(.vertical, 3)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("How Jarvis listens")
            if ListeningPolicy.current.wakeWordAvailable {
                AssistantNameField(config: config, controller: controller)
            }
            if controller.listensWithoutFn {
                HStack {
                    Text(controller.handsFreeLabel).font(.system(size: 14))
                    Spacer()
                    Button(controller.listeningWithoutFn ? "Pause listening" : "Start listening") {
                        if controller.listeningWithoutFn { controller.pauseHandsFree() }
                        else { controller.resumeHandsFree() }
                    }
                }
                if case .unavailable(let reason) = controller.handsFreeState {
                    Note(reason, tint: .orange)
                }
            }
            if !input.ready {
                Note(input.message, tint: .orange)
                HStack {
                    Button("Open Keyboard Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
                    Button("Check again") { input.refresh(); controller.refreshPermissions() }
                }
            }
            Divider()
            Picker("Microphone", selection: $config.microphoneUID) {
                Text("Mac default (" + microphones.defaultName + ")").tag("")
                ForEach(microphones.devices) { device in Text(device.name).tag(device.uid) }
                if !config.microphoneUID.isEmpty && !microphones.devices.contains(where: { $0.uid == config.microphoneUID }) {
                    Text("Microphone not connected").tag(config.microphoneUID)
                }
            }
            HStack {
                Button(controller.isMicrophoneTest ? "Stop test" : "Test microphone") {
                    controller.isMicrophoneTest ? controller.stopMicrophoneTest() : controller.startMicrophoneTest()
                }.disabled(!controller.canBegin && !controller.isMicrophoneTest)
                Spacer()
                LevelMeter(level: controller.isMicrophoneTest ? controller.audioLevel : 0)
            }
            if controller.isMicrophoneTest {
                Note(controller.inputName.isEmpty ? "Starting the microphone…" : "Say something. Jarvis won't do anything during the test.")
            } else if case .error(let message) = controller.status {
                Note(message, tint: .orange)
            }
            Note("While Jarvis is listening, what you say is sent to OpenAI so Jarvis can understand it. Pause listening to stop. Eye tracking never leaves your Mac.")
        }
    }

    // MARK: - Replies

    private var replies: some View {
        SettingsSection(title: "Replies", symbol: "speaker.wave.2") {
            Toggle("Say replies out loud", isOn: $config.ttsEnabled)
            Toggle("Play sounds", isOn: $config.sounds)
        }
    }

    // MARK: - Doing things for you

    private var doingThings: some View {
        SettingsSection(title: "Doing things for you", symbol: "hand.tap") {
            Toggle("Do it as soon as I finish speaking", isOn: $config.autoExecute)
            Note(config.autoExecute
                 ? "Jarvis acts on what you said straight away."
                 : "Jarvis shows what it heard and waits for you to say go.")
            Toggle("Don't ask before changing things", isOn: $config.alwaysAllowComputerUse)
            Note(config.alwaysAllowComputerUse
                 ? "Jarvis clicks and types without checking with you first."
                 : "Jarvis checks with you before it changes something.")
            Toggle("Show where Jarvis clicks", isOn: $config.agentCursorEnabled)
            Toggle("Get help with unusual requests", isOn: $config.semanticAppSuggestions)
            Note("When Jarvis isn't sure which app you mean, it asks an online helper. Only your words and the names of your apps are sent.")
            Note("Jarvis won't delete things or buy things for you.")
            Divider()
            AgentSignIn(auth: config.codexAuth)
            Divider()
            HStack {
                Button("Forget what I've allowed") { CuaStandingGrants.reset() }
                Spacer()
            }
            Note("Jarvis remembers things you've allowed, like reading a web page, so it doesn't ask twice. This makes it ask again.")
        }
    }

    // MARK: - Eye tracking

    private var eyeTracking: some View {
        SettingsSection(title: "Eye tracking", symbol: "eye") {
            Toggle("Use eye tracking", isOn: $config.gazeTracking)
            Note("Look at something and say “click that”. Uses the camera; nothing it sees leaves your Mac. Everything works by voice without it.")
            if config.gazeTracking {
                Picker("Dot size", selection: Binding(
                    get: { eyeDotScale },
                    set: { value in
                        eyeSettingsTouched = true
                        eyeDotScale = value
                        Task { try? await TrackerControl.post(action: "dot_scale", value: value) }
                    })) {
                    Text("Small").tag(0.8)
                    Text("Medium").tag(1.0)
                    Text("Large").tag(1.25)
                }.pickerStyle(.segmented)
                Toggle("Show a dot where I'm looking", isOn: Binding(
                    get: { eyeDotVisible },
                    set: { value in
                        eyeSettingsTouched = true
                        eyeDotVisible = value
                        Task { try? await TrackerControl.post(action: "gaze_dot", value: value) }
                    }))
                Note("When it's off, the thing you're looking at lights up instead.")
                Toggle("Hold the highlight steady", isOn: Binding(
                    get: { eyeDwellLock },
                    set: { value in
                        eyeSettingsTouched = true
                        eyeDwellLock = value
                        Task { try? await TrackerControl.post(action: "dwell_lock", value: value) }
                    }))
                Picker("Click by looking", selection: Binding(
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
                    Text("Buttons only").tag(DwellPolicy.Mode.safe.rawValue)
                    Text("Anything").tag(DwellPolicy.Mode.all.rawValue)
                }.pickerStyle(.segmented)
                Note("Keep your eyes on something for a moment and Jarvis clicks it.")
                Toggle("Tap fn to click what I'm looking at", isOn: $config.tapToGazeClick)
                HStack {
                    Button("Check eye-tracking accuracy") { accuracyCheck.start() }
                        .disabled(accuracyCheck.running)
                    Button("Measure accuracy (no calibration)") { accuracyCheck.start(measureOnly: true) }
                        .disabled(accuracyCheck.running)
                    if accuracyCheck.running { ProgressView().controlSize(.small) }
                }
                if !accuracyCheck.message.isEmpty { Note(accuracyCheck.message) }
            }
        }
        .task(id: config.gazeTracking) {
            guard config.gazeTracking, let status = try? await TrackerControl().status() else { return }
            // A read that resolved after the user edited must not paint
            // over the newer choice.
            guard !eyeSettingsTouched else { return }
            if let scale = status.dotScale {
                eyeDotScale = [0.8, 1.0, 1.25].min(by: { abs($0 - scale) < abs($1 - scale) }) ?? scale
            }
            if let lock = status.dwellLock { eyeDwellLock = lock }
            if let visible = status.dotVisible { eyeDotVisible = visible }
        }
    }

    // MARK: - Permissions

    private var permissions: some View {
        SettingsSection(title: "Permissions", symbol: "hand.raised") {
            ForEach(Permission.required(gaze: config.gazeTracking)) { permission in
                let missing = controller.missingPermissions.contains(permission)
                HStack {
                    Image(systemName: missing ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(missing ? Color.orange : Color.mint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.rawValue).font(.system(size: 14))
                        Text(missing ? permission.purpose : "Allowed").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if missing {
                        Button(permission.canPrompt ? "Allow" : "Open System Settings") {
                            Task { await permission.request(); controller.refreshPermissions(); input.refresh() }
                        }
                        .accessibilityLabel((permission.canPrompt ? "Allow " : "Open System Settings for ") + permission.rawValue)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - General

    private var general: some View {
        SettingsSection(title: "General", symbol: "gearshape") {
            Toggle("Open Jarvis when I log in", isOn: $config.launchAtLogin)
            if let status = loginServiceStatusText { Note(status) }
            if let error = config.launchAtLoginError { Note(error, tint: .orange) }
        }
    }

    // MARK: - Advanced

    /// Keys typed on this Mac: required in a build without Jarvis's
    /// credential service, a developer override in one with it.
    private var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
            VStack(alignment: .leading, spacing: 12) {
                Note(config.hostedCredentialsConfigured
                    ? "Jarvis connects for you. Keys typed here replace that on this Mac, for development. Remove them to go back."
                    : "This build of Jarvis needs your own keys: OpenAI to hear and answer you, TypeSafe to understand requests. They stay in your Mac's Keychain.")
                keyField("OpenAI key", placeholder: "sk-…", draft: $openAIKeyDraft, saved: openAIKeySaved) {
                    openAIKeySaved = config.saveOpenAIAPIKey(openAIKeyDraft)
                }
                keyField("TypeSafe key", placeholder: "ts-…", draft: $typeSafeKeyDraft, saved: typeSafeKeySaved) {
                    typeSafeKeySaved = config.saveAPIKey(typeSafeKeyDraft)
                }
                if let error = config.apiKeyError { Note(error, tint: .orange) }
            }
            .padding(.top, 10)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 4)
        .onAppear {
            openAIKeyDraft = config.openAIAPIKey
            typeSafeKeyDraft = config.apiKey
        }
        .onChange(of: openAIKeyDraft) { openAIKeySaved = false }
        .onChange(of: typeSafeKeyDraft) { typeSafeKeySaved = false }
    }

    private func keyField(_ title: String, placeholder: String, draft: Binding<String>,
                          saved: Bool, save: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14))
            HStack {
                SecureField(placeholder, text: draft).textFieldStyle(.roundedBorder).onSubmit(save)
                    .accessibilityLabel(title)
                Button("Save", action: save)
            }
            if saved { Note(draft.wrappedValue.isEmpty ? "Removed." : "Saved.") }
        }
    }

    /// What ServiceManagement actually holds, only when it needs saying.
    private var loginServiceStatusText: String? {
        switch config.loginServiceStatus {
        case .requiresApproval:
            return "Allow Jarvis in System Settings, under General, then Login Items."
        case .notFound:
            return "This works once Jarvis is in your Applications folder."
        case .enabled, .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// A titled block of settings on the one page.
private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        JarvisCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: symbol).font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                content.font(.system(size: 14))
            }
        }
    }
}

/// Secondary text under a setting, at a size people can read.
private struct Note: View {
    let text: String
    var tint: Color = .secondary
    init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// ChatGPT sign-in for helper agents. Watches CodexAuth directly so the
/// spinner, sign-in code and status line update as the flow progresses.
private struct AgentSignIn: View {
    @ObservedObject var auth: CodexAuth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                Text("Helper agents").font(.system(size: 14, weight: .medium))
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
                    Note("This copy of Jarvis can't sign in. Reinstalling Jarvis fixes it.", tint: .orange)
                } else if let code = auth.signInCode {
                    Note("A sign-in page opened in your browser. Enter the code " + code + " there; it's already copied.")
                } else if auth.signInOpenedTerminal {
                    Note("Finish signing in in the window that opened. This updates when you're done.")
                }
                Note("Sign in with ChatGPT to let Jarvis hand longer jobs to helper agents. Everyday requests don't need it.")
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
                Text("Can't reach sign-in right now").font(.callout)
            }
        }
    }
}
