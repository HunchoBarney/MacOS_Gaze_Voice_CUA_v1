import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: VoiceWindows!
    private let speechOutput = ElevenLabsSpeechOutput()
    private lazy var controller = VoiceController(speaker: speechOutput)
    private var agentRuntime: AgentRuntime?
    private let microphones = MicrophoneCatalog()
    private let input = FnInputMonitor()
    private var subscriptions: Set<AnyCancellable> = []
    private var terminating = false
    private var sessionActive = true
    private var sleeping = false
    private var screenLocked = false
    private var canPrepareMicrophone: Bool { sessionActive && !sleeping && !screenLocked && !terminating }
    private var permissionTimer: Timer?
    private var microphonePermissionGranted = Permission.microphone.isGranted

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        windows = VoiceWindows(controller: controller, microphones: microphones, input: input)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Jev Voice")
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let activity = menu.addItem(withTitle: "Activity", action: #selector(showActivity), keyEquivalent: "")
        activity.target = self
        let agents = menu.addItem(withTitle: "Agents", action: #selector(showAgents), keyEquivalent: "")
        agents.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Jev Voice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            sessionActive = session[kCGSessionOnConsoleKey as String] as? Bool ?? false
            screenLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        }

        input.canBegin = { [weak self] in self?.controller.canBegin ?? false }
        input.operationActive = { [weak self] in self?.controller.operationActive ?? false }
        input.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .begin: self.controller.begin(inputHandlingMs: self.input.beginHandlingMs)
            case .finish: self.controller.finish()
            case .cancel: self.controller.cancel()
            case .cancelCapture: self.controller.cancelCaptureAttempt()
            case .none: break
            }
        }
        input.onInterruption = { [weak self] reason in self?.controller.interruptCapture(reason) }
        input.dictationChordEnabled = controller.config.dictationHotkey
        input.latchMode = controller.config.latchMode
        speechOutput.enabled = controller.config.ttsEnabled
        speechOutput.apiKey = controller.config.elevenLabsAPIKey
        input.onDictationBegin = { [weak self] in self?.controller.beginDictation() }
        input.onDictationConvert = { [weak self] in self?.controller.dictate() }
        input.onLatch = { [weak self] in self?.controller.latchHold() }
        controller.config.$dictationHotkey.sink { [weak self] in self?.input.dictationChordEnabled = $0 }
            .store(in: &subscriptions)
        controller.config.$latchMode.sink { [weak self] in self?.input.latchMode = $0 }
            .store(in: &subscriptions)
        controller.config.$ttsEnabled.sink { [weak self] in self?.speechOutput.enabled = $0 }
            .store(in: &subscriptions)
        controller.config.$elevenLabsAPIKey.sink { [weak self] in self?.speechOutput.apiKey = $0 }
            .store(in: &subscriptions)

        agentRuntime = Self.makeAgentRuntime()
        agentRuntime?.onConsentAsk = { [weak self] request in
            self?.speechOutput.speak(request.summary)
        }
        agentRuntime?.onAgentReply = { [weak self] _, text in
            // Agent replies are documents — speak a bounded lead, not the whole thing.
            let lead = String((text.split(separator: ".").first.map(String.init) ?? text).prefix(200))
            self?.speechOutput.speak(lead)
        }
        agentRuntime?.start()
        if let runtime = agentRuntime {
            windows.agents.bind(roster: runtime.store, runtime: runtime.bridge,
                                consent: runtime.gate)
        }
        controller.pendingConsent = { [weak self] in self?.agentRuntime?.solePendingAsk }
        controller.onConsentResolution = { [weak self] request, approved in
            self?.agentRuntime?.resolveConsent(request, approved: approved)
        }
        input.$ready.removeDuplicates().sink { [weak self] ready in
            guard let self, self.canPrepareMicrophone else { return }
            if ready { self.controller.prepareMicrophone() }
            else { self.controller.suspendMicrophone("Fn input is unavailable.") }
        }.store(in: &subscriptions)
        input.start()
        controller.config.$microphoneUID.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self, self.canPrepareMicrophone else { return }
            // @Published emits before storage changes; read the selection on the next main turn.
            Task { @MainActor in
                guard self.canPrepareMicrophone else { return }
                self.controller.prepareMicrophone(deviceChanged: true)
            }
        }.store(in: &subscriptions)
        microphones.$devices.combineLatest(microphones.$defaultHardwareID)
            .dropFirst().sink { [weak self] _ in
                guard let self, self.canPrepareMicrophone else { return }
                Task { @MainActor in
                guard self.canPrepareMicrophone else { return }
                self.controller.prepareMicrophone(deviceChanged: true)
            }
            }.store(in: &subscriptions)
        // Loginwindow posts these notifications on supported macOS builds. They
        // are not an AppKit contract; physical lock/unlock remains an acceptance check.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            DistributedNotificationCenter.default().publisher(for: Notification.Name(name))
                .receive(on: RunLoop.main).sink { [weak self] _ in
                    self?.screenLocked = locked
                    self?.refreshMicrophoneLifecycle()
                }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main).sink { [weak self] _ in
                    guard let self else { return }
                    switch name {
                    case NSWorkspace.willSleepNotification: self.sleeping = true
                    case NSWorkspace.didWakeNotification:
                        self.sleeping = false
                        // The driver's first calls after wake stall on its own
                        // cold checks — warm the session so a command doesn't pay it.
                        self.controller.cua.wakeDriverSession()
                    case NSWorkspace.sessionDidResignActiveNotification: self.sessionActive = false
                    default: self.sessionActive = true
                    }
                    self.refreshMicrophoneLifecycle()
                }.store(in: &subscriptions)
        }
        refreshMicrophoneLifecycle()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let granted = Permission.microphone.isGranted
                if granted != self.microphonePermissionGranted {
                    self.microphonePermissionGranted = granted
                    if granted { self.refreshMicrophoneLifecycle() }
                    else { self.controller.suspendMicrophone("Microphone permission was removed.") }
                }
                self.controller.refreshPermissions()
            }
        }
        controller.refreshPermissions()
        Task { await SpeechAssets.shared.refresh() }
        if ProcessInfo.processInfo.arguments.contains("--settings") {
            windows.show(.voice)
        } else if !controller.missingPermissions.isEmpty || !input.ready {
            controller.showSetup("Finish setup in Voice settings. " + input.message)
        }
    }

    private func refreshMicrophoneLifecycle() {
        guard canPrepareMicrophone else {
            controller.suspendMicrophone("Microphone paused while the session is inactive.")
            return
        }
        input.refresh(); microphones.refresh()
        if input.ready { controller.prepareMicrophone() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshPermissions(); input.refresh(); microphones.refresh()
        if canPrepareMicrophone, input.ready { controller.prepareMicrophone() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        permissionTimer?.invalidate()
        input.stop()
        Task {
            await controller.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        input.stop(); microphones.stop(); agentRuntime?.stopAll()
    }

    /// Agents need a codex binary (vendored in the bundle, dev fallback
    /// ~/.local/bin) and a configured model provider — without either the
    /// roster stays empty and the feature stays off rather than half-working.
    private static func makeAgentRuntime() -> AgentRuntime? {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("CodexRuntime/codex")
        let dev = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codex")
        guard let codex = [bundled, dev].compactMap({ $0 })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }
        let settings = TextProviderSettings.shared
        guard settings.configured else { return nil }
        let envKey = "JEV_CODEX_API_KEY"
        let provider = CodexModelProvider(name: "jev", baseURL: settings.endpoint,
                                        wireAPI: "chat", envKey: envKey,
                                        model: settings.model)
        let bridge = CodexRuntimeBridge(configuration: .init(
            codexBinary: codex, provider: provider,
            environment: [envKey: (try? settings.providerKey()) ?? ""]))
        let jevKey = Config.shared.apiKey
        let store = AgentStore(directory: AgentWorkspace.root())
        let runtime = AgentRuntime(store: store, bridge: bridge,
                                   connection: CuaConnection(), apiKey: { jevKey })
        return runtime
    }
    /// Relaunching a running accessory app (Spotlight, Finder, `open`) sends
    /// reopen — without this the user gets no window and the status item may
    /// be hidden in a crowded menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windows.show(.voice) }
        return true
    }
    @objc private func showSettings() { windows.show(.voice) }
    @objc private func showActivity() { windows.show(.activity) }
    @objc private func showAgents() { windows.showAgents() }

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(withTitle: "Quit Jev Voice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
