import Foundation
import Combine
import ServiceManagement

final class Config: ObservableObject {
    static func startupKeychainInteractionAllowed(environment: [String: String], arguments: [String]) -> Bool {
        !(environment["JARVIS_P3_GUI_AUDIT"] == "1" && arguments.contains("--p3-user-audit"))
    }
    static let shared: Config = {
        let allow = startupKeychainInteractionAllowed(environment: ProcessInfo.processInfo.environment,
                                                       arguments: ProcessInfo.processInfo.arguments)
        return Config(keyStore: KeychainAPIKeyStore(allowUserInteraction: allow),
                      openAIKeyStore: KeychainAPIKeyStore(account: "openAIAPIKey", allowUserInteraction: allow))
    }()

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

    /// Cue-tone gate — the chimes that mark hold start, task done and
    /// refusals. On by default; off keeps the interface silent.
    @Published var sounds: Bool {
        didSet { defaults.set(sounds, forKey: "soundsEnabled") }
    }

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
    @Published var handsFreeEnabled: Bool {
        didSet { defaults.set(handsFreeEnabled, forKey: "handsFreeEnabled") }
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

    /// Launch the eye tracker with the app so gaze-referent verbs resolve:
    /// "click", "scroll down", "open this", "what is this". Off leaves the
    /// tracker alone — the verbs then refuse honestly instead of guessing.
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
        codexAuth: CodexAuth = .shared
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.openAIKeyStore = openAIKeyStore
        self.codexAuth = codexAuth
        self.environment = environment
        self.chatGPTAuthStatus = codexAuth.chatGPTAuthStatus
        self.apiKey = environment["TYPESAFE_API_KEY"] ?? ""
        self.openAIAPIKey = environment["OPENAI_API_KEY"] ?? ""
        self.microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        self.autoExecute = defaults.object(forKey: "autoExecute") as? Bool ?? true
        self.alwaysAllowComputerUse = defaults.object(forKey: "cuaStandingGrant.computerUseInput") as? Bool ?? false
        self.agentCursorEnabled = defaults.object(forKey: "agentCursorEnabled") as? Bool ?? true
        self.sounds = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
        self.persistentNumbers = defaults.object(forKey: "persistentNumbers") as? Bool ?? false
        self.ttsEnabled = defaults.object(forKey: "ttsEnabled") as? Bool ?? true
        self.handsFreeEnabled = defaults.object(forKey: "handsFreeEnabled") as? Bool ?? false
        self.semanticAppSuggestions = defaults.object(forKey: "semanticAppSuggestions") == nil
            ? true : defaults.bool(forKey: "semanticAppSuggestions")
        self.latchMode = defaults.object(forKey: "latchMode") as? Bool ?? false
        self.dictationHotkey = defaults.object(forKey: "dictationHotkey") as? Bool ?? true
        self.gazeTracking = defaults.object(forKey: "gazeTracking") as? Bool ?? true
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
