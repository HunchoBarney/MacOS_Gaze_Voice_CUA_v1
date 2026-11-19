import AppKit
import AVFoundation
import Combine
import OSLog

#if !JEV_C1_VOICE_BADGE_ONLY
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Single-instance guard: a second launch exits cleanly instead of
    /// spawning duplicate driver daemons and overlays.
    private var instanceLock: FileHandle?
    private var statusItem: NSStatusItem!
    private var voiceHeader: NSMenuItem!
    private var voiceToggle: NSMenuItem!
    private var voiceStop: NSMenuItem!
    private var displayedVoiceMenu: HandsFreeMenuState?
    private var windows: VoiceWindows!
    private let speechOutput = SpeechOutput()
    private lazy var controller: VoiceController = {
        let config = VoiceUserAudit.enabled
            ? VoiceUserAudit.diagnosticConfiguration()
            : Config.shared
        let controller = VoiceController(config: config, speaker: speechOutput)
        controller.handsFreeSessionAvailable = { [weak self] in self?.canPrepareMicrophone == true }
        return controller
    }()
    private var agentRuntime: AgentRuntime?
    private let microphones = MicrophoneCatalog()
    private let input = FnInputMonitor()
    private var subscriptions: Set<AnyCancellable> = []
    private var terminating = false
    private var sessionActive = true
    private var sleeping = false
    private var screenLocked = false
    private var canPrepareMicrophone: Bool {
        sessionActive && !sleeping && !screenLocked && !terminating && !VoiceUserAudit.enabled
    }
    private var permissionTimer: Timer?
    /// The Eyes section of the status menu — state arrives from one
    /// `/snapshot` read per menu open plus a slow poll while tracking;
    /// a dead or disabled tracker collapses to the Enable affordance.
    private var eyesStatus: TrackerStatus?
    private var eyesTask: Task<Void, Never>?
    private var eyesPollTimer: Timer?
    private var eyesHeader: NSMenuItem?
    private var eyesEnable: NSMenuItem?
    private var eyesRestart: NSMenuItem?
    private var eyesPause: NSMenuItem?
    private var eyesRecalibrate: NSMenuItem?
    /// Driver maintenance affordance — disabled while a restart is in
    /// flight so a second request can't queue behind the kill/spawn.
    private var driverRestartItem: NSMenuItem?
    private var driverRestarting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        instanceLock = VoiceInstanceLock.acquire()
        guard instanceLock != nil else {
            Self.log.error("Jev Voice is already running; terminating duplicate launch.")
            // Never route this through NSApp.terminate — it lands in
            // applicationShouldTerminate, whose shutdown path touches the
            // lazy controller and would build the whole voice stack inside
            // a dying process.
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        // The status item is the only launch feedback an accessory app has —
        // it goes up before the controller, whose init reads Keychain and
        // Config and can block on a keychain prompt.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Jev Voice")
        windows = VoiceWindows(controller: controller, microphones: microphones, input: input)
        let menu = NSMenu()
        voiceHeader = menu.addItem(withTitle: "Hands-free off", action: nil, keyEquivalent: "")
        voiceToggle = menu.addItem(withTitle: "Pause Hands-Free", action: #selector(pauseVoice), keyEquivalent: "")
        voiceToggle.target = self
        voiceStop = menu.addItem(withTitle: "Stop All Tasks", action: #selector(stopVoiceTasks), keyEquivalent: "")
        voiceStop.target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let activity = menu.addItem(withTitle: "Activity", action: #selector(showActivity), keyEquivalent: "")
        activity.target = self
        let agents = menu.addItem(withTitle: "Agents", action: #selector(showAgents), keyEquivalent: "")
        agents.target = self
        menu.addItem(.separator())
        // The host owns the one menu-bar icon — the tracker's own tray is
        // suppressed at spawn (--no-tray), so its controls live here.
        eyesHeader = menu.addItem(withTitle: "Eyes", action: nil, keyEquivalent: "")
        eyesHeader?.isEnabled = false
        eyesEnable = menu.addItem(withTitle: "Enable Eye Tracking", action: #selector(enableEyeTracking), keyEquivalent: "")
        eyesEnable?.target = self
        eyesRestart = menu.addItem(withTitle: "Restart Eye Tracking", action: #selector(restartEyeTracking), keyEquivalent: "")
        eyesRestart?.target = self
        eyesRestart?.isHidden = true
        eyesPause = menu.addItem(withTitle: "Pause Tracking", action: #selector(toggleEyePause), keyEquivalent: "")
        eyesPause?.target = self
        eyesRecalibrate = menu.addItem(withTitle: "Recalibrate", action: #selector(recalibrateEyes), keyEquivalent: "")
        eyesRecalibrate?.target = self
        let eyeSettings = menu.addItem(withTitle: "Eye Tracking Settings…", action: #selector(showEyeSettings), keyEquivalent: "")
        eyeSettings.target = self
        menu.addItem(.separator())
        let driverRestart = menu.addItem(withTitle: "Restart Driver", action: #selector(restartDriver), keyEquivalent: "")
        driverRestart.target = self
        driverRestartItem = driverRestart
        let latencyReport = menu.addItem(withTitle: "Copy Latency Report", action: #selector(copyLatencyReport), keyEquivalent: "")
        latencyReport.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Jev Voice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        menu.delegate = self
        applyEyesState()
        refreshAskBadge()
        controller.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.refreshAskBadge()
        }.store(in: &subscriptions)

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
        input.onPhysicalFnChanged = { [weak self] down in self?.controller.physicalFnChanged(down) }
        input.onInterruption = { [weak self] reason in self?.controller.interruptCapture(reason) }
        input.onReleaseRecovery = { [weak self] observed, confirmed, latch in
            self?.controller.recordRecoveredFnRelease(observed: observed, confirmed: confirmed, latch: latch)
        }
        input.dictationChordEnabled = controller.config.dictationHotkey
        input.latchMode = controller.config.latchMode
        speechOutput.enabled = controller.config.ttsEnabled
        input.onDictationBegin = { [weak self] in self?.controller.beginDictation() }
        input.onDictationConvert = { [weak self] in self?.controller.dictate() }
        input.onLatch = { [weak self] in self?.controller.latchHold() }
        controller.config.$dictationHotkey.sink { [weak self] in self?.input.dictationChordEnabled = $0 }
            .store(in: &subscriptions)
        controller.config.$latchMode.sink { [weak self] in self?.input.latchMode = $0 }
            .store(in: &subscriptions)
        controller.config.$ttsEnabled.sink { [weak self] in self?.speechOutput.enabled = $0 }
            .store(in: &subscriptions)

        // Telemetry taps — read-only subscriptions over streams the app
        // already publishes; they observe, never feed back.
        wireTelemetry()
        // Composition seams — gaze-tap commit + universal stop are live;
        // local STT/router/voice stay a documented stub until the
        // Intelligence lane's types land (see the method's doc comment).
        wireLocalIntelligence()

        agentRuntime = Self.makeAgentRuntime()
        // The agents runtime boots after the controller exists — the voice
        // delegation seam is wired late, never guessed at init time. A user
        // who signs in mid-session revives it lazily on first use.
        controller.cua.agentBridge = VoiceAgentBridge(
            runtime: agentRuntime,
            ensureRuntime: { [weak self] in self?.ensureAgentRuntime() })
        controller.refreshVoiceContext()
        if let agentRuntime { wireAgentRuntime(agentRuntime) }
        // Cold-connect the Cua driver now so the first voice command doesn't
        // pay the process spawn + MCP handshake inside the turn.
        controller.cua.warm()
        // The eye tracker is a required component — gaze verbs answer "where"
        // from it. Adopt a hand-started tracker; never duplicate one.
        // @Published replays nothing: without the prepend a persisted-on
        // feature (the default IS on) never emits, and neither the tracker
        // nor the gaze service would ever start — every gaze verb dead on
        // a fresh or returning launch until the user re-toggled the switch.
        controller.config.$gazeTracking
            .prepend(controller.config.gazeTracking)
            .sink { enabled in
            // The always-on second cursor rides the same toggle — the
            // service owns the /events stream for the app's life while
            // tracking is on.
            if enabled { GazeService.shared.start() } else { GazeService.shared.stop() }
            Task { enabled ? await TrackerHost.shared.userRequestedStart()
                           : await TrackerHost.shared.stop() }
        }.store(in: &subscriptions)
        // Agent MCP children read the standing grant from this file —
        // published at boot and on every change so consent stays in sync
        // across processes.
        CuaPolicy.publishStateFile(standingGrant: controller.config.alwaysAllowComputerUse)
        controller.config.$alwaysAllowComputerUse
            .sink { CuaPolicy.publishStateFile(standingGrant: $0) }
            .store(in: &subscriptions)
        input.$ready.removeDuplicates().sink { [weak self] ready in
            guard let self, self.canPrepareMicrophone else { return }
            self.controller.recordQualificationInputReady(ready)
            if ready || self.controller.config.handsFreeEnabled { self.controller.prepareMicrophone() }
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
                self.controller.refreshPermissionsInBackground(
                    canPrepareMicrophone: { [weak self] in self?.canPrepareMicrophone ?? false }
                ) { [weak self] in
                    self?.refreshMicrophoneLifecycle()
                }
            }
        }
        controller.refreshPermissions()
        if ProcessInfo.processInfo.arguments.contains("--settings") {
            windows.show(.voice)
        } else if !controller.missingPermissions.isEmpty || !input.ready {
            controller.showSetup("Finish setup in Voice settings. " + input.message)
        }
        if VoiceUserAudit.enabled {
            input.stop()
            VoiceUserAudit.start(controller: controller)
        }
    }

    private func refreshMicrophoneLifecycle() {
        guard canPrepareMicrophone else {
            controller.suspendMicrophone("Microphone paused while the session is inactive.", resumeHandsFreeOnRecovery: true)
            return
        }
        input.refresh(); microphones.refresh()
        if input.ready || controller.config.handsFreeEnabled { controller.prepareMicrophone() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshPermissions(); input.refresh(); microphones.refresh()
        if canPrepareMicrophone, input.ready || controller.config.handsFreeEnabled { controller.prepareMicrophone() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        permissionTimer?.invalidate()
        input.stop()
        // Teardown is bounded: a wedged CoreAudio teardown, a stuck agent
        // daemon or a tracker that won't die must not hold the process —
        // and the instance lock, which only a process death releases —
        // forever. Whichever answers first lets the app terminate.
        Task {
            // The always-on gaze service dies with the app — its socket
            // and ring can't outlive the process they read.
            GazeService.shared.stop()
            // Each reaper gets its own DETACHED task: a plain Task {}
            // inherits the main actor, so a synchronously wedged main
            // thread starves the very kills meant to free it — the
            // tracker survives the quit that was supposed to reap it.
            // TrackerHost is a real actor, so its stop truly runs
            // off-main. controller.shutdown() stays on the main actor —
            // it touches audio/AppKit state that expects it, and the
            // 10s fuse below covers it regardless.
            let trackerStop = Task.detached { await TrackerHost.shared.stop() }
            let agentsStop = Task.detached { [agentRuntime] in
                await agentRuntime?.stopAll()
            }
            await controller.shutdown()
            _ = await (trackerStop.value, agentsStop.value)
            replyToTermination()
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            Self.log.error("shutdown exceeded 5s — replying to terminate without waiting on teardown")
            replyToTermination()
        }
        // Last-resort fuse, off the main actor: if the main actor itself is
        // the thing that's wedged even the 5s reply can't run, so after
        // 10s the process dies outright and the instance lock frees.
        Task.detached {
            try? await Task.sleep(for: .seconds(10))
            FileHandle.standardError.write(Data("Jev Voice: shutdown wedged — forcing exit\n".utf8))
            exit(0)
        }
        return .terminateLater
    }

    /// First answer wins — the shutdown chain and the timeout fuse can both
    /// arrive at the reply, and a double reply is a logged AppKit error.
    private var terminationReplied = false
    private func replyToTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        input.stop(); microphones.stop()
        Task { await agentRuntime?.stopAll() }
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
        // The user's own codex login preferred (real OpenAI models on
        // their subscription). Without it, agents run on the app's OpenAI
        // key via env — agent homes symlink the login's auth.json rather
        // than copying it (rotation stays in the real file).
        let codexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let auth = codexHome.appendingPathComponent("auth.json")
        let provider: CodexModelProvider
        var environment: [String: String] = [:]
        if FileManager.default.fileExists(atPath: auth.path) {
            provider = .chatGPT(model: Self.codexConfigModel(codexHome: codexHome) ?? "")
        } else {
            let key = Config.shared.openAIAPIKey
            guard !key.isEmpty else { return nil }
            provider = CodexModelProvider(name: "openai",
                                          baseURL: "https://api.openai.com/v1",
                                          envKey: "OPENAI_API_KEY", model: "")
            environment["OPENAI_API_KEY"] = key
        }
        let bridge = CodexRuntimeBridge(configuration: .init(
            codexBinary: codex, provider: provider, environment: environment))
        let store = AgentStore(directory: AgentWorkspace.root())
        return AgentRuntime(store: store, bridge: bridge)
    }

    /// Boot path for an existing runtime; the voice bridge calls this
    /// lazily when codex auth appears mid-session (nil-runtime revival).
    @discardableResult
    private func ensureAgentRuntime() -> AgentRuntime? {
        if let agentRuntime { return agentRuntime }
        guard let runtime = Self.makeAgentRuntime() else { return nil }
        agentRuntime = runtime
        wireAgentRuntime(runtime)
        return runtime
    }

    /// One wiring pass per runtime — reply/event/cursor sinks, the agent
    //  UI binding, and the per-agent MCP stdio server surface.
    private func wireAgentRuntime(_ runtime: AgentRuntime) {
        runtime.onAgentReply = { [weak self] _, text in
            // Agent replies are documents — speak a bounded lead, not the whole
            // thing. Push as a task_outcome so the lane voices `say` verbatim
            // instead of answering bare text as if it were a question.
            let lead = String((text.split(separator: ".").first.map(String.init) ?? text).prefix(200))
            let say = VoiceToolResult.spoken(lead, words: 30)
            let payload = VoiceToolResult(
                kind: VoiceToolResult.Kind.taskOutcome,
                status: VoiceToolResult.Status.ok,
                say: say.isEmpty ? "The agent replied." : say).encoded()
            if self?.controller.voiceAgentEvent(payload) != true {
                self?.speechOutput.speak(lead)
            }
        }
        // Each agent's codex gets a stdio MCP server entry — the same
        // binary re-execed as `JevVoice --mcp-stdio --agent <slug>` — plus
        // TYPESAFE_API_KEY in its environment so codex's `env_vars`
        // pass-through hands it to the MCP child without touching disk.
        // The key is read live at spawn so a mid-session key set works.
        runtime.start(
            mcpServersFor: { agent in
                [CodexMCPServer(name: "jev-drive",
                                command: Bundle.main.executablePath
                                    ?? ProcessInfo.processInfo.arguments[0],
                                args: ["--mcp-stdio", "--agent", agent.slug],
                                envVars: ["TYPESAFE_API_KEY"],
                                cwd: agent.workspacePath)]
            },
            environmentFor: { _ in ["TYPESAFE_API_KEY": Config.shared.apiKey] })
        // The runtime owns the single event-stream consumer, fanning
        // events out to the UI here.
        windows.agents.bind(roster: runtime.store, runtime: runtime)
        runtime.onAgentEvent = { [weak self] event in
            self?.windows.agents.handle(event)
        }
        // Name chips track each agent session's drawn cursor — the
        // driver draws the cursor, the app labels whose it is.
        controller.cua.cursorLabelSink = { [weak self] slug, point in
            guard let self else { return }
            if let point {
                self.windows.cursorLabels.show(runtime.cursor(for: slug), at: point)
            } else {
                self.windows.cursorLabels.hide(agentSlug: slug)
            }
        }
    }

    /// `model = "…"` from the user's own ~/.codex/config.toml — agents inherit
    /// whichever model their account is already tuned to. Nil → codex default.
    private static func codexConfigModel(codexHome: URL) -> String? {
        guard let text = try? String(contentsOf: codexHome.appendingPathComponent("config.toml"),
                                     encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("model"), t.contains("=") else { continue }
            let v = t.split(separator: "=", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let unquoted = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !unquoted.isEmpty { return unquoted }
        }
        return nil
    }
    /// Relaunching a running accessory app (Spotlight, Finder, `open`) sends
    /// reopen — without this the user gets no window and the status item may
    /// be hidden in a crowded menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windows.show(.voice) }
        return true
    }
    @objc private func showSettings() { windows.show(.voice) }
    @objc private func showEyeSettings() { windows.show(.commands) }
    @objc private func showActivity() { windows.show(.activity) }
    @objc private func showAgents() { windows.showAgents() }

    // MARK: - Telemetry + driver maintenance

    /// Read-only subscriptions over the streams the app already publishes —
    /// the latency ledger taps Fn edges, capture-state transitions, the
    /// decision feed and the gaze event sink; the spend counter taps the
    /// same feed and capture edges. Nothing in the voice/drive lanes knows
    /// they exist, which is the point of wiring them here.
    private func wireTelemetry() {
        LatencyLedger.shared.attach(controller: controller, input: input,
                                    gaze: GazeService.shared)
        SpendCounter.shared.attach(controller: controller)
    }

    /// Re-mint the embedded computer-use daemon — the host's own
    /// `restartDriver()` stops the current generation and re-spawns with
    /// the same socket-readiness wait a normal mint pays (a failed re-mint
    /// stays non-fatal: the next `socket()` retries lazily). The menu item
    /// disables while a restart is in flight so a second request can't
    /// queue behind the kill/spawn window.
    @objc private func restartDriver() {
        guard !driverRestarting else { return }
        driverRestarting = true
        driverRestartItem?.title = "Restarting Driver…"
        driverRestartItem?.isEnabled = false
        Task { [weak self] in
            await CuaDaemonHost.shared.restartDriver()
            await MainActor.run {
                guard let self else { return }
                self.driverRestarting = false
                self.driverRestartItem?.title = "Restart Driver"
                self.driverRestartItem?.isEnabled = true
                // Rebind the coordinator's cached transport to the new
                // socket now instead of letting the next task pay it.
                self.controller.cua.warm()
            }
        }
    }

    /// p50/p95 per stage onto the pasteboard — the report is derived from
    /// the ledger's ring, never re-reads the JSONL.
    @objc private func copyLatencyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(LatencyLedger.shared.report(), forType: .string)
    }

    /// Composition-seam + local-intelligence wiring.
    ///
    ///   - `controller.gazeTapHandler` → `GazeService.commitTarget` +
    ///     `cua.actuateCommitted`: a speechless Fn tap (sub-100ms of
    ///     audio) commits the referent under the eyes instead of the
    ///     silent dismiss. The voice lane fires it only for a tap that
    ///     sent audio upstream; `config.tapToGazeClick` is read inside
    ///     the handler so the Settings toggle needs no restart.
    ///   - `controller.cancelAllTasks` → `cua.cancelAllRunning()`: the
    ///     universal stop — Escape settles every voice task, parked ask,
    ///     and in-flight agent turn, not just the capture.
    ///   - Local capture/final admission belongs to RealtimeVoiceLane;
    ///     composition never wires a second transcript/action authority.
    private func wireLocalIntelligence() {
        controller.gazeTapHandler = { [weak self] in
            guard !Task.isCancelled else { return false }
            guard let self, await self.controller.config.tapToGazeClick
            else { return false }
            guard let (candidate, _) = await GazeService.shared.commitTarget()
            else { return false }
            guard !Task.isCancelled else { return false }
            return await self.controller.cua.actuateCommitted(candidate, permitted: {
                self.controller.config.tapToGazeClick
            })
        }
        // Universal stop — Escape lands on every lane: running tasks,
        // parked asks (a cancel resolves their continuation like the
        // deadline does), and agent turns in flight.
        controller.cancelAllTasks = { [weak self] in
            _ = await self?.controller.cua.cancelAllRunning()
        }
        // The voice lane owns local capture, final admission and display.
        // No independently wired speculative transcript router may dispatch.
        controller.localSpeechWindow = nil
        controller.localSpeechSink = nil
    }

    // MARK: - Eyes section

    /// The host's own state composes the label first — a starting tracker
    /// reads "Starting…" (not "Unavailable"), a failed one names the reason
    /// and offers Restart, and only a running tracker defers to the last
    /// `/snapshot` read. A failed action POST flips nothing — the next poll
    /// corrects the label, never an optimistic guess.
    private func applyEyesState() {
        Task { [weak self] in
            guard let self else { return }
            let hostState = await TrackerHost.shared.state
            self.paintEyes(hostState: hostState)
        }
    }

    private func paintEyes(hostState: TrackerHost.State) {
        // Every repaint re-picks the affordance set — a state that hid an
        // item last pass can't strand it hidden in the next.
        eyesEnable?.isEnabled = true
        switch hostState {
        case .starting:
            eyesHeader?.title = "Eyes — Starting…"
            // The affordance stays visible but disabled: the honest state
            // is "a start is already in flight", not "the feature is gone".
            eyesEnable?.isHidden = false
            eyesEnable?.isEnabled = false
            eyesRestart?.isHidden = true
            eyesPause?.isHidden = true
            eyesRecalibrate?.isHidden = true
        case .failed(let message):
            eyesHeader?.title = "Eyes — Stopped (\(Self.shortTrackerFailure(message)))"
            eyesEnable?.isHidden = true
            eyesRestart?.isHidden = false
            eyesPause?.isHidden = true
            eyesRecalibrate?.isHidden = true
        case .stopped:
            eyesHeader?.title = "Eyes — Off"
            eyesEnable?.isHidden = false
            eyesRestart?.isHidden = true
            eyesPause?.isHidden = true
            eyesRecalibrate?.isHidden = true
        case .running:
            eyesHeader?.title = eyesStatus.map { "Eyes — \($0.label)" } ?? "Eyes — Running"
            eyesEnable?.isHidden = true
            eyesRestart?.isHidden = true
            if let status = eyesStatus {
                eyesPause?.isHidden = false
                eyesPause?.title = status.paused ? "Resume Tracking" : "Pause Tracking"
                eyesRecalibrate?.isHidden = false
            } else {
                // Host reports running but /snapshot hasn't landed yet —
                // pause/recalibrate would just post to a dead socket.
                eyesPause?.isHidden = true
                eyesRecalibrate?.isHidden = true
            }
        }
    }

    /// Menu titles stay short: keep the first clause of the failure reason
    /// (the messages all start "The eye tracker …") and cap the length.
    private static func shortTrackerFailure(_ message: String) -> String {
        var first = message.components(separatedBy: ".").first ?? message
        for prefix in ["The eye tracker ", "the eye tracker "] {
            if first.hasPrefix(prefix) { first.removeFirst(prefix.count) }
        }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
    }

    /// Parked agent/voice asks surface on the status item itself — the
    /// one always-visible affordance — so a waiting question never
    /// depends on the menu happening to open. The count is polled on
    /// open and on every snapshot refresh; it comes from the task
    /// coordinator's seam.
    private var voiceMenu: HandsFreeMenuState {
        controller.handsFreeControls
    }

    private func refreshAskBadge() {
        let voice = voiceMenu
        guard displayedVoiceMenu != voice else { return }
        displayedVoiceMenu = voice
        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: voice.symbol, accessibilityDescription: voice.label)
        button?.setAccessibilityLabel("Jev Voice")
        button?.setAccessibilityValue(voice.accessibilityValue)
        button?.toolTip = "Jev Voice — " + voice.label
        button?.title = voice.pending > 0 ? " ·\(voice.pending)" : ""
        voiceHeader.title = voice.label
        voiceHeader.toolTip = voice.detail
        voiceToggle.isHidden = voice.toggle == nil
        if let toggle = voice.toggle {
            voiceToggle.title = toggle.rawValue
            voiceToggle.action = toggle == .pause ? #selector(pauseVoice) : #selector(resumeVoice)
        }
        voiceStop.isHidden = !voice.stoppable
    }

    @objc private func pauseVoice() { controller.applyHandsFreeToggle(.pause) }

    @objc private func resumeVoice() {
        controller.applyHandsFreeToggle(.resume)
    }

    @objc private func stopVoiceTasks() {
        if voiceMenu.stoppable { controller.stopAll() }
    }

    /// One snapshot read, then repaint — cancelled reads can't paint over
    /// a newer one.
    private func refreshEyes() {
        eyesTask?.cancel()
        eyesTask = Task { [weak self] in
            let status = try? await TrackerControl().status()
            guard let self, !Task.isCancelled else { return }
            self.eyesStatus = status
            self.refreshAskBadge()
            self.applyEyesState()
        }
    }

    /// Polling stays cheap: one read on open, then a slow timer only
    /// while the menu is actually tracking — never a hot loop.
    func menuWillOpen(_ menu: NSMenu) {
        applyEyesState()
        refreshEyes()
        refreshAskBadge()
        eyesPollTimer?.invalidate()
        eyesPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEyes() }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        eyesPollTimer?.invalidate()
        eyesPollTimer = nil
    }

    /// Enable runs through the Config sink alone — one write, one
    /// userRequestedStart, one spawn. A second ensureRunning here would
    /// race the sink's and orphan a tracker process.
    @objc private func enableEyeTracking() {
        controller.config.gazeTracking = true
        applyEyesState()
        refreshEyes()
    }

    /// Restart after a failed spawn — `userRequestedStart` resets the
    /// spawn-attempt budget a crash or stop exhausted. When the feature is
    /// disabled the Enable path already funnels through the Config sink,
    /// which lands in the same call.
    @objc private func restartEyeTracking() {
        if controller.config.gazeTracking {
            Task { await TrackerHost.shared.userRequestedStart() }
        } else {
            controller.config.gazeTracking = true
        }
        applyEyesState()
        refreshEyes()
    }

    @objc private func toggleEyePause() {
        Task {
            try? await TrackerControl.post(action: "pause_toggle")
            refreshEyes()
        }
    }

    @objc private func recalibrateEyes() {
        Task {
            try? await TrackerControl.post(action: "recalibrate")
            refreshEyes()
        }
    }

    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "AppDelegate")

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

#endif

// `JevVoice --mcp-stdio --agent <slug>` is an agent's MCP server process —
// short-circuit before the app boots so codex children never become a
// second Jev Voice instance.
#if JEV_C1_VOICE_BADGE_ONLY
guard RestrictedVoiceEntry.accepts(marker: Bundle.main.object(forInfoDictionaryKey: "JevLocalProfile"),
                                  arguments: Array(CommandLine.arguments.dropFirst()),
                                  environmentKeys: RestrictedVoiceEntry.environmentKeys()) else { exit(78) }
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { RestrictedVoiceAppDelegate() }
#else
guard Bundle.main.object(forInfoDictionaryKey: "JevLocalProfile") == nil else { exit(78) }
if NoFnTrace.entry == .refuse { exit(78) }
if CommandLine.arguments.dropFirst().contains(where: { argument in
    let flag = argument.prefix { $0 != "=" }
    return flag == "--p3-voice-replay" || flag == "--p3-record-holdouts"
}) {
    fputs("Local speech replay and holdout recording are retired from this app. Use the historical developer checkout at 073fedeb1101d50466ff46b7c007d085e08d9e15.\n", stderr)
    exit(2)
}
MainActor.assumeIsolated { VoiceNormalQualification.preflight() }
if ProcessInfo.processInfo.arguments.contains("--p3-live") {
    VoiceLiveTrial.main()
}
if ProcessInfo.processInfo.arguments.contains("--p3-remote-live") {
    VoiceRemoteTrial.main()
}
if ProcessInfo.processInfo.arguments.contains("--mcp-stdio") {
    CuaDriveServer.main()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
#endif
app.delegate = delegate
app.run()
