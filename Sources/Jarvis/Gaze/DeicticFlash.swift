import AppKit
import QuartzCore

/// D6: a small ring flashes on the element "this" resolved to, so the
/// person sees what Jarvis took them to mean. It is not a gaze pointer:
/// it shows once per resolution and retires itself. The panel is kept
/// out of screenshots and screen sharing, so Jarvis's own captures never
/// see it.
@MainActor
final class DeicticFlash {
    static let shared = DeicticFlash()

    /// The ring settles onto the element from slightly larger.
    static let settleScale: CGFloat = 1.08
    static let settleSeconds: CFTimeInterval = 0.12
    static let holdSeconds: CFTimeInterval = 0.35
    static let fadeSeconds: CFTimeInterval = 0.2
    static let lineWidth: CGFloat = 2
    /// Canvas room around the ring for the stroke and the settle.
    static let canvasPad: CGFloat = 8

    /// Reduce Motion keeps the fades and drops the settle.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var panel: NSPanel?
    private let ring = CAShapeLayer()
    /// Bumped per flash, so an older flash's retire never hides a newer ring.
    private var generation = 0
    /// The ring's rect in top-left points while it shows — tests read it.
    private(set) var shownRect: CGRect?

    /// Borderless, nonactivating, above full-screen windows, blind to the
    /// mouse, and invisible to screen capture.
    static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        return panel
    }

    /// `frame` is the element in global top-left points.
    func flash(frame: CGRect) {
        let shape = TargetOverlay.ringTarget(frame: frame)
        let canvas = shape.rect.insetBy(dx: -Self.canvasPad, dy: -Self.canvasPad)
        let panel = self.panel ?? makeRingPanel()
        generation += 1
        let current = generation
        shownRect = shape.rect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.removeAllAnimations()
        ring.frame = CGRect(origin: .zero, size: canvas.size)
        ring.path = TargetOverlay.ringPath(shape, in: canvas)
        ring.opacity = 1
        CATransaction.commit()
        panel.setFrame(TargetOverlay.appKitFrame(for: canvas), display: true)
        panel.orderFrontRegardless()

        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0 as NSNumber
        appear.toValue = 1 as NSNumber
        appear.duration = Self.settleSeconds
        appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(appear, forKey: "appear")
        if !reduceMotion() {
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = Self.settleScale as NSNumber
            settle.toValue = 1 as NSNumber
            settle.duration = Self.settleSeconds
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(settle, forKey: "settle")
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleSeconds + Self.holdSeconds))
            guard let self, self.generation == current else { return }
            self.ring.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1 as NSNumber
            fade.toValue = 0 as NSNumber
            fade.duration = Self.fadeSeconds
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.ring.add(fade, forKey: "fade")
            try? await Task.sleep(for: .seconds(Self.fadeSeconds))
            guard self.generation == current else { return }
            self.panel?.orderOut(nil)
            self.shownRect = nil
        }
    }

    private func makeRingPanel() -> NSPanel {
        let panel = Self.makePanel()
        let view = NSView()
        view.wantsLayer = true
        ring.strokeColor = NSColor.systemBlue.cgColor
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = Self.lineWidth
        view.layer?.addSublayer(ring)
        panel.contentView = view
        self.panel = panel
        return panel
    }
}
