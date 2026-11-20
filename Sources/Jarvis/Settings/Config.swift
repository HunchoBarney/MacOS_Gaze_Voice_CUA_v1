import Foundation
import Combine
import JarvisCore
import ServiceManagement

final class Config: ObservableObject {
    static let shared: Config = {
        Config(keyStore: KeychainAPIKeyStore(allowUserInteraction: true),
               openAIKeyStore: KeychainAPIKeyStore(account: "openAIAPIKey", allowUserInteraction: true),
               hosted: HostedCredentials.serviceURL(
                   environment: ProcessInfo.processInfo.environment,
                   infoValue: Bundle.main.object(forInfoDictionaryKey: "JarvisCredentialsURL")
               ).map { HostedCredentials(baseURL: $0, tokenStore: KeychainAPIKeyStore(account: "installToken")) })
    }()

    private let defaults: UserDefaults
    private let keyStore: APIKeyStore
    private let openAIKeyStore: APIKeyStore
    @Published private(set) var apiKeyError: String?

    @Published private(set) var apiKey: String
    /// A developer's own OpenAI key — env `OPENAI_API_KEY` first, Keychain
    /// `openAIAPIKey` second. When set it replaces Jarvis's service for
    /// Realtime.
    @Published private(set) var openAIAPIKey: String
    /// Jarvis's credential service (KAR-38), when this build names one.
    /// People then never handle a key; the two above are a developer
    /// override.
    let hosted: HostedCredentials?
    var hostedCredentialsConfigured: Bool { hosted != nil }
    /// A key Jarvis needs is missing and can only be typed into Settings →
    /// Advanced, because this build has no credential service.
    var needsKeys: Bool { !hostedCredentialsConfigured && (openAIAPIKey.isEmpty || apiKey.isEmpty) }
    /// Settings shows the key fields: always without the service, and with
    /// it only as a developer override — a key is already set, or
    /// `defaults write com.karanvirkang.jarvis developerKeys -bool YES`.
    var showsKeyFields: Bool {
        !hostedCredentialsConfigured || !openAIAPIKey.isEmpty || !apiKey.isEmpty
            || defaults.bool(forKey: "developerKeys")
    }

    /// The credential for the next Realtime socket: the developer key when
    /// set, else a fresh client secret from the service, else nil.
    func realtimeCredential() async throws -> RealtimeCredential? {
        let key = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return RealtimeCredential(key: key, model: nil) }
        return try await hosted?.realtimeCredential()
    }

    /// Where Jev calls go: TypeSafe with the developer key when set, else
    /// the service's Jev proxy with this Mac's install token, else nil.
    func jevRoute() async throws -> ServiceRoute? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return ServiceRoute(url: JevClient.systemOneURL, bearer: key) }
        guard let hosted else { return nil }
        return ServiceRoute(url: hosted.jevURL, bearer: try await hosted.installToken())
    }

    /// Where Terra calls go, chosen the same way with the OpenAI key.
    func responsesRoute() async throws -> ServiceRoute? {
        let key = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return ServiceRoute(url: TerraClient.endpoint, bearer: key) }
        guard let hosted else { return nil }
        return ServiceRoute(url: hosted.responsesURL, bearer: try await hosted.installToken())
    }

    /// The Jev credential an agent's drive server gets in its environment.
    /// Agents spawn without waiting on the network, so this reads only a
    /// token already registered.
    var jevEnvironment: [String: String] {
        if !apiKey.isEmpty { return ["TYPESAFE_API_KEY": apiKey] }
        guard let hosted, let token = hosted.storedToken else { return [:] }
        return ["TYPESAFE_API_KEY": token, "TYPESAFE_BASE_URL": hosted.jevURL.absoluteString]
    }

    @Published var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: "microphoneUID") }
    }
    /// The name in the wake phrase, "Hey <name>". Settings stores only a
    /// name the wake-word engine can hear.
    @Published var assistantName: String {
        didSet { defaults.set(assistantName, forKey: "assistantName") }
    }
    /// The hands-free GPT-Live work (JARA-49 L1–L10) runs only while this
    /// is on. Off by default until L11; there is no Settings toggle, so it
    /// is turned on with `defaults write com.karanvirkang.jarvis voice.live -bool true`.
    @Published var voiceLive: Bool {
        didSet { defaults.set(voiceLive, forKey: "voice.live") }
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

    /// Cue-tone gate for every non-speech sound: the Glass and Basso
    /// chimes for a finished task, a failure, a refusal, a stall, a
    /// question waiting on you, and a lost outcome. Off by default:
    /// Jarvis is always listening, so the glow and the indicator carry
    /// these and only speech is heard. Settings → Replies → Sounds turns
    /// them back on.
    @Published var sounds: Bool {
        didSet { defaults.set(sounds, forKey: "soundsEnabled") }
    }
    /// Set once the quiet default has been applied, so installs that had
    /// sounds on turn them off exactly once and a later choice sticks.
    static let quietByDefaultKey = "soundsQuietByDefault"

    /// Aim number-chip persistence — on keeps the overlay's numbered
    /// targets painted until dismissed; off lets them fade with the
    /// action that used them.
    @Published var persistentNumbers: Bool {
        didSet { defaults.set(persistentNumbers, forKey: "persistentNumbers") }
    }

    /// ChatGPT/codex login state for the planner UI and runtime — mirrors
    /// `codexAuth.chatGPTAuthStatus` so a Config handle alone is enough to
    /// observe it.
    @Published private(set) var chatGPTAuthStatus: CodexAuth.Status
    /// ChatGPT sign-in surface: status probes and the device-auth flow.
    let codexAuth: CodexAuth

    /// Spoken replies through the SpeechSynthesizing seam.
    @Published var ttsEnabled: Bool {
        didSet { defaults.set(ttsEnabled, forKey: "ttsEnabled") }
    }
    /// How a turn starts — the user's choice. `handsFreeEnabled` follows
    /// it: a mode that streams between turns keeps hands-free on.
    @Published var listeningMode: ListeningMode {
        didSet {
            defaults.set(listeningMode.rawValue, forKey: "listeningMode")
            let streams = ListeningPolicy.current.streamsContinuously(listeningMode)
            if handsFreeEnabled != streams { handsFreeEnabled = streams }
        }
    }
    @Published var handsFreeEnabled: Bool {
        didSet {
            defaults.set(handsFreeEnabled, forKey: "handsFreeEnabled")
            let streams = ListeningPolicy.current.streamsContinuously(listeningMode)
            if handsFreeEnabled != streams { listeningMode = handsFreeEnabled ? .conversation : .pushToTalk }
        }
    }
    /// The three-step first run finished (or was skipped). Settings can
    /// start it again.
    @Published var firstRunCompleted: Bool {
        didSet { defaults.set(firstRunCompleted, forKey: "firstRunCompleted") }
    }
    @Published var handsFreePaused: Bool {
        didSet { defaults.set(handsFreePaused, forKey: "handsFreePaused") }
    }
    /// Core semantic assist defaults on; an explicit opt-out is retained.
    @Published var semanticAppSuggestions: Bool {
        didSet { defaults.set(semanticAppSuggestions, forKey: "semanticAppSuggestions") }
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

    /// Eye tracking — optional and off by default. On, the tracker launches
    /// with the app so "click this" and "what is this" resolve and the
    /// camera is requested. Off, those phrases answer with what to say
    /// instead and the camera is never asked for.
    @Published var gazeTracking: Bool {
        didSet { defaults.set(gazeTracking, forKey: "gazeTracking") }
    }

    /// Tap-to-click with the eyes: a Fn tap while looking at a target
    /// clicks it directly instead of opening a voice turn. On by default.
    @Published var tapToGazeClick: Bool {
        didSet { defaults.set(tapToGazeClick, forKey: "tapToGazeClick") }
    }

    /// Launch at login — the persisted value is the user's choice; the real
    /// registration goes through SMAppService on every change and is
    /// reconciled once at boot. `loginServiceStatus` mirrors what
    /// ServiceManagement actually reports so the UI never claims "on" while
    /// the system says otherwise.
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }
    /// What `SMAppService.mainApp.status` last reported — .notFound outside
    /// an installed bundle (a bare `swift run` binary can't register).
    @Published private(set) var loginServiceStatus: SMAppService.Status = .notRegistered
    /// The last register/unregister failure — surfaced under the toggle so
    /// a ServiceManagement rejection never reads as silently enabled.
    @Published private(set) var launchAtLoginError: String?

    /// The launch environment snapshot — consulted for credentials
    /// (TYPESAFE_API_KEY, OPENAI_API_KEY) so tests can inject values
    /// without touching the process environment.
    let environment: [String: String]

    init(
        defaults: UserDefaults = .standard,
        keyStore: APIKeyStore = KeychainAPIKeyStore(),
        openAIKeyStore: APIKeyStore = KeychainAPIKeyStore(account: "openAIAPIKey"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexAuth: CodexAuth = .shared,
        hosted: HostedCredentials? = nil
    ) {
        self.defaults = defaults
        self.hosted = hosted
        self.keyStore = keyStore
        self.openAIKeyStore = openAIKeyStore
        self.codexAuth = codexAuth
        self.environment = environment
        self.chatGPTAuthStatus = codexAuth.chatGPTAuthStatus
        self.apiKey = environment["TYPESAFE_API_KEY"] ?? ""
        self.openAIAPIKey = environment["OPENAI_API_KEY"] ?? ""
        self.microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        self.assistantName = defaults.string(forKey: "assistantName") ?? AssistantName.standard
        self.voiceLive = defaults.bool(forKey: "voice.live")
        self.autoExecute = defaults.object(forKey: "autoExecute") as? Bool ?? true
        self.alwaysAllowComputerUse = defaults.object(forKey: "cuaStandingGrant.computerUseInput") as? Bool ?? false
        self.agentCursorEnabled = defaults.object(forKey: "agentCursorEnabled") as? Bool ?? true
        if !defaults.bool(forKey: Self.quietByDefaultKey) {
            defaults.set(false, forKey: "soundsEnabled")
            defaults.set(true, forKey: Self.quietByDefaultKey)
        }
        self.sounds = defaults.bool(forKey: "soundsEnabled")
        self.persistentNumbers = defaults.object(forKey: "persistentNumbers") as? Bool ?? false
        self.ttsEnabled = defaults.object(forKey: "ttsEnabled") as? Bool ?? true
        let policy = ListeningPolicy.current
        let storedMode = defaults.string(forKey: "listeningMode").flatMap(ListeningMode.init(rawValue:))
        let legacyHandsFree = defaults.object(forKey: "handsFreeEnabled") as? Bool
        let mode = storedMode ?? legacyHandsFree.map { $0 ? .conversation : .pushToTalk } ?? policy.defaultMode
        self.listeningMode = mode
        self.handsFreeEnabled = policy.streamsContinuously(mode)
        self.firstRunCompleted = defaults.bool(forKey: "firstRunCompleted")
        self.handsFreePaused = defaults.object(forKey: "handsFreePaused") as? Bool ?? false
        self.semanticAppSuggestions = defaults.object(forKey: "semanticAppSuggestions") == nil
            ? true : defaults.bool(forKey: "semanticAppSuggestions")
        self.latchMode = defaults.object(forKey: "latchMode") as? Bool ?? false
        self.dictationHotkey = defaults.object(forKey: "dictationHotkey") as? Bool ?? true
        self.gazeTracking = defaults.object(forKey: "gazeTracking") as? Bool ?? false
        self.tapToGazeClick = defaults.object(forKey: "tapToGazeClick") as? Bool ?? true
        // ServiceManagement is the truth when it knows the app — a bare
        // `swift run` binary reports .notFound, where the persisted choice
        // is all there is to go on.
        let loginStatus = SMAppService.mainApp.status
        self.loginServiceStatus = loginStatus
        self.launchAtLogin = switch loginStatus {
        case .enabled, .requiresApproval: true
        case .notFound: defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        default: false
        }
        self.launchAtLoginError = nil

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

        codexAuth.$chatGPTAuthStatus.assign(to: &$chatGPTAuthStatus)

        // Reconcile once at boot: a persisted "on" that never registered
        // (fresh install, cleaned login items) registers without a manual
        // toggle; a revoked registration just reports its real status.
        if launchAtLogin, loginServiceStatus == .notRegistered {
            applyLaunchAtLogin()
        }
    }

    /// Register or unregister the app as a login item. Errors land in
    /// `launchAtLoginError` and the live status in `loginServiceStatus` —
    /// the desired-state flag stays whatever the user picked so the toggle
    /// and the system can be compared honestly.
    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                // unregister() throws when nothing is registered — guard it
                // so a benign "off" never lands as an error.
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        loginServiceStatus = SMAppService.mainApp.status
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
