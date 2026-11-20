import AppKit
import Combine
import SwiftUI

/// A floating, borderless panel that never takes focus from the app you're
/// using. It hosts the listening tab under the menu bar.
private final class IndicatorPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a panel that never becomes key still answer the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns every window Jarvis shows: the listening tab, Settings, Agents and
/// the first run.
@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    let navigation = SettingsNavigation()
    /// Agents surface — the app delegate binds its store and runtime.
    let agents = AgentsViewModel()
    let cursorLabels = AgentCursorLabels()

    private let controller: VoiceController
    private let microphones: MicrophoneCatalog
    private let input: FnInputMonitor
    private let indicator = IndicatorPanel()
    private let indicatorHost: FirstClickHostingView<ListeningIndicatorView>
    private var settingsWindow: NSWindow?
    private var agentsWindow: NSWindow?
    private var firstRunWindow: NSWindow?
    private var indicatorScreen: NSScreen?
    private var shownPhase: IndicatorPhase = .hidden
    private var observers: Set<AnyCancellable> = []

    init(controller: VoiceController, microphones: MicrophoneCatalog, input: FnInputMonitor) {
        self.controller = controller
        self.microphones = microphones
        self.input = input
        indicatorHost = FirstClickHostingView(rootView: ListeningIndicatorView(controller: controller))
        super.init()
        indicatorHost.rootView = ListeningIndicatorView(controller: controller, openSettings: { [weak self] anchor in
            self?.show(.voice, anchor: anchor)
        })
        indicator.contentView = indicatorHost
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIndicator() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.indicatorScreen = nil
                self?.updateIndicator()
            }
            .store(in: &observers)
    }

    // MARK: - Listening tab

    private func updateIndicator() {
        let phase = IndicatorPhase.current(controller)
        let appeared = shownPhase == .hidden
        if phase != shownPhase { announce(phase) }
        shownPhase = phase
        guard phase != .hidden else {
            indicator.orderOut(nil)
            return
        }
        if appeared || indicatorScreen.map({ !NSScreen.screens.contains($0) }) ?? true {
            let mouse = NSEvent.mouseLocation
            indicatorScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        }
        guard let screen = indicatorScreen else { return }
        let frame = Self.frame(contentSize: indicatorHost.fittingSize, visibleFrame: screen.visibleFrame)
        if indicator.frame != frame { indicator.setFrame(frame, display: true) }
        if !indicator.isVisible { indicator.orderFrontRegardless() }
        controller.recordOverlayPresentation()
    }

    /// One VoiceOver announcement per change, never per meter tick.
    private func announce(_ phase: IndicatorPhase) {
        let text: String
        switch phase {
        case .hidden: return
        case .hearing: text = "Listening"
        case .working: text = "Working"
        case .asking:
            text = controller.pendingTaskApproval?.askPrompt
                ?? controller.pendingQuestions.last?.prompt ?? "Jarvis has a question"
        case .problem:
            if case .error(let message) = controller.status { text = message } else { text = "Something went wrong" }
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The tab hangs from the menu bar, centred under the notch.
    static func frame(contentSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let size = NSSize(width: min(contentSize.width, visibleFrame.width),
                          height: min(contentSize.height, visibleFrame.height))
        return NSRect(origin: NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.maxY - size.height),
                      size: size)
    }

    // MARK: - Windows

    func show(_ section: SettingsNavigation.Section, anchor: SettingsNavigation.Anchor? = nil) {
        controller.refreshPermissions()
        microphones.refresh()
        input.refresh()
        if section != .voice { controller.stopMicrophoneTest() }
        navigation.section = section
        navigation.anchor = anchor
        let window = settingsWindow ?? makeWindow(
            title: "Jarvis", size: NSSize(width: 820, height: 640), minimum: NSSize(width: 740, height: 520),
            content: SettingsView(controller: controller, config: controller.config,
                                  microphones: microphones, input: input, navigation: navigation)
                .environmentObject(agents)
                .environment(\.openAgents) { [weak self] in self?.showAgents() })
        window.delegate = self
        settingsWindow = window
        bringForward(window)
    }

    func showAgents() {
        let window = agentsWindow ?? makeWindow(
            title: "Agents", size: NSSize(width: 880, height: 560), minimum: NSSize(width: 720, height: 440),
            content: AgentsView(model: agents))
        agentsWindow = window
        bringForward(window)
    }

    /// The four-step first run. Closing it early is fine: Settings has
    /// the same permissions, and it shows again until it's finished.
    func showFirstRun() {
        let window = firstRunWindow ?? makeWindow(
            title: "Set up Jarvis", size: NSSize(width: 520, height: 440), minimum: nil,
            content: FirstRunView(config: controller.config, finish: { [weak self] in self?.firstRunWindow?.close() }))
        firstRunWindow = window
        bringForward(window)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, minimum: NSSize?,
                                           content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if minimum != nil { style.formUnion([.miniaturizable, .resizable]) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        if let minimum { window.minSize = minimum }
        window.contentView = NSHostingView(rootView: content)
        window.center()
        return window
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { controller.stopMicrophoneTest() }
    }
}
