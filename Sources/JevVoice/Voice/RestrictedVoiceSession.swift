import AppKit
import Combine
import Darwin

enum RestrictedVoiceEntry {
    static let marker = "c1-voice-badge-no-model-1"

    static func consoleAvailable(_ info: [String: Any]?, protectedDataAvailable: Bool) -> Bool {
        protectedDataAvailable && info?[kCGSessionOnConsoleKey as String] as? Bool == true
            && info?[kCGSessionLoginDoneKey as String] as? Bool == true
            && info?["CGSSessionScreenIsLocked"] as? Bool == false
    }

    static func accepts(marker: Any?, arguments: [String], environmentKeys: [String]) -> Bool {
        guard marker as? String == Self.marker, arguments.isEmpty else { return false }
        let forbidden = ["JARVIS_", "JEV_", "CUA_", "CODEX_", "OPENAI_", "TYPESAFE_", "DYLD_"]
        return !environmentKeys.contains { name in
            let upper = name.uppercased()
            return forbidden.contains(where: upper.hasPrefix) || upper.hasSuffix("_PROXY")
        }
    }

    static func environmentKeys() -> [String] {
        var keys: [String] = []
        var cursor = Darwin.environ
        while let entry = cursor.pointee {
            let length = strcspn(entry, "=")
            keys.append(String(decoding: UnsafeRawBufferPointer(start: entry, count: length), as: UTF8.self))
            cursor = cursor.advanced(by: 1)
        }
        return keys
    }
}

@MainActor
final class RestrictedVoiceSession {
    let controller: VoiceController
    private let monitorStart: () -> Void
    private let monitorStop: () -> Void
    private let observeUp: () -> UUID?
    private var active = false
    private var finished = false
    private var preparedObservation: UUID?

    init(controller: VoiceController, monitorStart: @escaping () -> Void, monitorStop: @escaping () -> Void,
         observeUp: @escaping () -> UUID?) {
        precondition(controller.config.isRestrictedVoice)
        self.controller = controller
        self.monitorStart = monitorStart
        self.monitorStop = monitorStop
        self.observeUp = observeUp
        controller.handsFreeSessionAvailable = { [weak self] in self?.active == true && self?.finished == false }
    }

    func setActive(_ value: Bool) {
        guard !finished else { return }
        guard value != active else {
            if value { refresh() } else { controller.inputObservationLost() }
            return
        }
        active = value
        if value {
            monitorStart()
            refresh()
        } else {
            preparedObservation = nil
            controller.inputObservationLost()
            monitorStop()
        }
    }

    func refresh() {
        guard !finished, active else { return }
        controller.refreshPermissions()
        inputChanged()
    }

    func inputChanged() {
        guard !finished, active else { return }
        guard controller.config.handsFreeEnabled, !controller.config.handsFreePaused else {
            preparedObservation = nil
            return
        }
        guard let observation = observeUp(), controller.missingPermissions.isEmpty else {
            preparedObservation = nil
            controller.inputObservationLost()
            return
        }
        guard observation != preparedObservation else { return }
        if preparedObservation != nil { controller.inputObservationLost() }
        preparedObservation = observation
        controller.prepareMicrophone()
    }

    func escape() {
        guard active, !finished else { return }
        controller.cancel()
    }

    func retry() {
        guard active, !finished, controller.config.handsFreeEnabled,
              !controller.config.handsFreePaused, case .unavailable = controller.handsFreeState else { return }
        controller.refreshPermissions()
        guard controller.missingPermissions.isEmpty, observeUp() != nil else { return }
        preparedObservation = nil
        controller.inputObservationLost()
        inputChanged()
    }

    func toggle() {
        guard active, !finished, let action = controller.handsFreeControls.toggle else { return }
        controller.applyHandsFreeToggle(action)
    }

    func shutdown() async {
        guard !finished else { return }
        finished = true
        active = false
        preparedObservation = nil
        controller.inputObservationLost()
        monitorStop()
        await controller.shutdown()
    }
}

@MainActor
final class RestrictedVoiceAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var instanceLock: FileHandle?
    private let monitor = FnInputMonitor(mode: .restrictedObservation)
    private var session: RestrictedVoiceSession?
    private var windows: VoiceWindows?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var awake = true
    private var consoleActive = false
    private var lockOpen = false
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        instanceLock = VoiceInstanceLock.acquire()
        guard instanceLock != nil else { exit(0) }
        let config = Config.restrictedVoice()
        let lane = RealtimeVoiceLane(apiKey: config.restrictedRealtimeKey, literalOnly: true)
        guard let controller = try? VoiceController(restrictedConfig: config, lane: lane,
            observedFnUpGeneration: { [monitor] in monitor.restrictedObservationGeneration },
            permissionStatusReader: { Permission.restrictedVoiceMissing() }) else { exit(78) }
        let session = RestrictedVoiceSession(controller: controller, monitorStart: monitor.start,
            monitorStop: monitor.stop, observeUp: { [monitor] in monitor.restrictedObservationGeneration })
        self.session = session
        monitor.onRestrictedObservationChanged = { [weak session] _ in session?.inputChanged() }
        monitor.onRestrictedEscape = { [weak session] in session?.escape() }
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Jev Voice")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        windows = VoiceWindows(controller: controller, microphones: nil, input: monitor,
                               reviewRestricted: { [weak self] in self?.statusItem?.button?.performClick(nil) })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                switch name {
                case NSWorkspace.willSleepNotification: self.awake = false
                case NSWorkspace.didWakeNotification: self.awake = true; self.readConsole()
                case NSWorkspace.sessionDidResignActiveNotification: self.consoleActive = false
                default: self.readConsole()
                }
                self.reconcile()
            }.store(in: &subscriptions)
        }
        for (name, open) in [("com.apple.screenIsLocked", false), ("com.apple.screenIsUnlocked", true)] {
            DistributedNotificationCenter.default().publisher(for: .init(name)).receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    if open { self?.readConsole() } else { self?.lockOpen = false }
                    self?.reconcile()
                }.store(in: &subscriptions)
        }
        readConsole()
        reconcile()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.refresh() }
        }
    }

    private func readConsole() {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        consoleActive = (info?[kCGSessionOnConsoleKey as String] as? Bool) == true
        lockOpen = RestrictedVoiceEntry.consoleAvailable(info, protectedDataAvailable: NSApp.isProtectedDataAvailable)
    }

    func applicationProtectedDataWillBecomeUnavailable(_ notification: Notification) {
        lockOpen = false
        reconcile()
    }

    func applicationProtectedDataDidBecomeAvailable(_ notification: Notification) {
        readConsole()
        reconcile()
    }

    private func reconcile() { session?.setActive(!terminating && awake && consoleActive && lockOpen) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let session, !terminating else { return }
        session.refresh()
        let controller = session.controller
        menu.removeAllItems()
        menu.addItem(withTitle: controller.handsFreeLabel, action: nil, keyEquivalent: "")
        if !awake || !consoleActive || !lockOpen {
            menu.addItem(withTitle: "The active, unlocked login session could not be confirmed.", action: nil, keyEquivalent: "")
        } else if !controller.missingPermissions.isEmpty {
            menu.addItem(withTitle: "Required: " + controller.missingPermissions.map(\.rawValue).joined(separator: ", "),
                         action: nil, keyEquivalent: "")
        } else if !controller.handsFreeDetail.isEmpty {
            menu.addItem(withTitle: controller.handsFreeDetail, action: nil, keyEquivalent: "")
        }
        if let toggle = controller.handsFreeControls.toggle {
            menu.addItem(withTitle: toggle.rawValue, action: #selector(toggleVoice), keyEquivalent: "").target = self
        } else if case .unavailable = controller.handsFreeState, controller.config.handsFreeEnabled {
            let retry = menu.addItem(withTitle: "Retry hands-free", action: #selector(retryVoice), keyEquivalent: "")
            retry.target = self
            retry.isEnabled = controller.missingPermissions.isEmpty && monitor.restrictedObservationGeneration != nil
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Jev Voice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleVoice() { session?.toggle() }
    @objc private func retryVoice() { session?.retry() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        session?.refresh()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        reconcile()
        refreshTimer?.invalidate()
        subscriptions.removeAll()
        Task { await session.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
