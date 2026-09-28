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
    private let controller: VoiceController
    private let microphones: MicrophoneCatalog
    private let input: FnInputMonitor
    private var panel: VoicePanel!
    private var overlay: OverlayHostingView<OverlayView>!
    private var settingsWindow: NSWindow?
    private var targetScreen: NSScreen?
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshQueued = false
    private var previousStatus: VoiceController.Status = .idle

    init(controller: VoiceController, microphones: MicrophoneCatalog, input: FnInputMonitor) {
        self.controller = controller; self.microphones = microphones; self.input = input
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
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &subscriptions)
    }

    func show(_ section: SettingsNavigation.Section) {
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
                collapse: { [weak self] in self?.settingsWindow?.close() }))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        guard status != .idle, !controller.isMicrophoneTest else { panel.orderOut(nil); return }
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
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.displayIfNeeded()
        controller.recordOverlayPresentation()
    }

    static func frame(contentSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let width = min(contentSize.width, visibleFrame.width)
        let height = min(contentSize.height, max(0, visibleFrame.height - 32))
        return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.minY + 16, width: width, height: height)
    }
}
