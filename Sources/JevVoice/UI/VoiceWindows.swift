// Nonactivating panel pattern adapted from FluidVoice; see ThirdParty/FluidVoice/NOTICE.md.
import AppKit
import Combine
import SwiftUI

private final class VoicePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class VoiceWindows: NSObject, NSWindowDelegate {
    let navigation = SettingsNavigation()
    /// Agents surface — coordinator binds store/runtime/gate via
    /// `agents.bind(...)`; cursorLabels receives per-agent cursor positions.
    lazy var agents = AgentsViewModel()
    lazy var cursorLabels = AgentCursorLabels()
    private let controller: VoiceController
    private let microphones: MicrophoneCatalog?
    private let reviewRestricted: (() -> Void)?
    private let input: FnInputMonitor
    private var panel: VoicePanel!
    private var overlay: OverlayHostingView<OverlayView>!
    private let handsFreeIndicator = HandsFreeIndicator()
    private var settingsWindow: NSWindow?
    private var agentsWindow: NSWindow?
    private var targetScreen: NSScreen?
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshQueued = false
    private var previousStatus: VoiceController.Status = .idle
    /// Settled-task ids already granted an idle linger — each fresh outcome
    /// gets one showing, never a re-show on later refresh ticks.
    private var lingeredOutcomeIDs: Set<UUID> = []
    private var outcomeLingerTask: Task<Void, Never>?
    /// Seconds a fresh task outcome stays on the idle card — long enough
    /// to read, short enough not to feel stuck.
    private static let outcomeLinger: TimeInterval = 4.5

    init(controller: VoiceController, microphones: MicrophoneCatalog?, input: FnInputMonitor,
         reviewRestricted: (() -> Void)? = nil) {
        self.controller = controller; self.microphones = microphones; self.input = input
        self.reviewRestricted = reviewRestricted
        super.init()
        panel = VoicePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = false
        panel.appearance = NSAppearance(named: .darkAqua)
        overlay = OverlayHostingView(rootView: OverlayView(controller: controller,
            openReview: { [weak self] in self?.show(.activity) },
            openSettings: { [weak self] in self?.show(.voice) }))
        panel.contentView = overlay
        controller.objectWillChange.sink { [weak self] in self?.queueRefresh() }.store(in: &subscriptions)
        controller.config.$handsFreeEnabled.combineLatest(controller.config.$handsFreePaused)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.handsFreeIndicator.refreshPlacement()
                self?.queueRefresh()
            }.store(in: &subscriptions)
    }

    func show(_ section: SettingsNavigation.Section) {
        if controller.config.isRestrictedVoice { reviewRestricted?(); return }
        guard let microphones else { return }
        controller.refreshPermissions(); microphones.refresh(); input.refresh()
        navigation.section = section
        if section != .voice { controller.stopMicrophoneTest() }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Jev Voice"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 740, height: 520)
            window.contentView = NSHostingView(rootView: SettingsView(controller: controller, config: controller.config,
                microphones: microphones, input: input, navigation: navigation,
                collapse: { [weak self] in self?.settingsWindow?.close() },
                spend: SpendCounter.shared)
                .environmentObject(agents)
                .environment(\.openAgents) { [weak self] in self?.showAgents() })
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Roster + per-agent chat window. Lives outside SettingsNavigation —
    /// its Section enum is owned by SettingsView.
    func showAgents() {
        guard !controller.config.isRestrictedVoice else { return }
        if agentsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Agents"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 440)
            window.contentView = NSHostingView(rootView: AgentsView(model: agents))
            window.center()
            agentsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        agentsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { controller.stopMicrophoneTest() }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshOverlay()
        }
    }

    private func refreshOverlay() {
        let status = controller.status
        defer { previousStatus = status }
        // A task that settles while the card is idle is otherwise never
        // seen — hold the panel on the fresh outcome before ordering out.
        // Every settled row is consumed so only a NEWER outcome re-arms;
        // the card always renders the newest settled one.
        let automatic = controller.quietHandsFreePresentation
        if automatic {
            lingeredOutcomeIDs.formUnion(controller.cuaTasks.filter { $0.outcome != nil }.map(\.id))
            outcomeLingerTask?.cancel(); outcomeLingerTask = nil
        } else if status == .idle, !controller.isMicrophoneTest,
                  controller.cuaTasks.contains(where: { $0.outcome != nil && !lingeredOutcomeIDs.contains($0.id) }) {
            for work in controller.cuaTasks where work.outcome != nil {
                lingeredOutcomeIDs.insert(work.id)
            }
            outcomeLingerTask?.cancel()
            outcomeLingerTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.outcomeLinger * 1e9))
                guard !Task.isCancelled else { return }
                self?.outcomeLingerTask = nil
                self?.queueRefresh()
            }
        }
        let show = Self.showsPanel(status: status, automatic: automatic,
                                   hasAsk: controller.pendingTaskApproval != nil || !controller.pendingQuestions.isEmpty,
                                   linger: outcomeLingerTask != nil, microphoneTest: controller.isMicrophoneTest)
        handsFreeIndicator.update(.current(controller, obscured: show))
        panel.ignoresMouseEvents = !show
        let order = Self.panelOrder(show: show, visible: panel.isVisible)
        guard show else {
            if order == .out { panel.orderOut(nil) }
            return
        }
        if status == .starting && previousStatus != .starting || targetScreen == nil {
            targetScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        if !NSScreen.screens.contains(where: { $0 == targetScreen }) { targetScreen = NSScreen.main ?? NSScreen.screens.first }
        guard let screen = targetScreen else { return }
        overlay.layoutSubtreeIfNeeded()
        let size = overlay.fittingSize
        let frame = Self.frame(contentSize: size, visibleFrame: screen.visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // Meter updates arrive at 25Hz; they must not repeatedly reorder a visible panel.
        if order == .front { panel.orderFrontRegardless() }
        panel.displayIfNeeded()
        controller.recordOverlayPresentation()
    }

    static func showsPanel(status: VoiceController.Status, automatic: Bool, hasAsk: Bool,
                           linger: Bool, microphoneTest: Bool) -> Bool {
        guard !microphoneTest else { return false }
        if hasAsk { return true }
        guard automatic else { return status != .idle || linger }
        switch status {
        case .error, .awaitingAnswer, .awaitingConfirm, .reviewTranscript: return true
        default: return false
        }
    }

    enum PanelOrder { case front, out, unchanged }

    static func panelOrder(show: Bool, visible: Bool) -> PanelOrder {
        guard show != visible else { return .unchanged }
        return show ? .front : .out
    }

    static func frame(contentSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let width = min(contentSize.width, visibleFrame.width)
        let height = min(contentSize.height, max(0, visibleFrame.height - 32))
        return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.minY + 16, width: width, height: height)
    }
}
