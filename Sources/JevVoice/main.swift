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
        input.start()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.controller.interruptCapture("Recording stopped because the session became inactive.") }.store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.input.refresh(); self?.microphones.refresh() }.store(in: &subscriptions)
        controller.refreshPermissions()
        Task { await SpeechAssets.shared.refresh() }
        if ProcessInfo.processInfo.arguments.contains("--settings") {
            windows.show(.voice)
        } else if !controller.missingPermissions.isEmpty || !input.ready {
            controller.showSetup("Finish setup in Voice settings. " + input.message)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshPermissions(); input.refresh(); microphones.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
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
#if SPEECH_FIXTURE_PROBE
if let index = CommandLine.arguments.firstIndex(of: "--voice-workflow-fixture"), CommandLine.arguments.count > index + 2 {
    let fixture = MainActor.assumeIsolated {
        SpeechFixtureWindow(input: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
            output: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
    }
    withExtendedLifetime(fixture) { app.run() }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--speech-fixture"), CommandLine.arguments.count > index + 2 {
    Task { @MainActor in
        await SpeechFixtureProbe.run(input: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
            output: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
        NSApp.terminate(nil)
    }
    app.run()
    exit(0)
}
#endif
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
