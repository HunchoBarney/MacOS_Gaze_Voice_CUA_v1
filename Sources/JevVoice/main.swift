import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: VoiceWindows!
    private let controller = VoiceController()
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
                    case NSWorkspace.didWakeNotification: self.sleeping = false
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

    func applicationWillTerminate(_ notification: Notification) { input.stop(); microphones.stop() }
    @objc private func showSettings() { windows.show(.voice) }
    @objc private func showActivity() { windows.show(.activity) }

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
