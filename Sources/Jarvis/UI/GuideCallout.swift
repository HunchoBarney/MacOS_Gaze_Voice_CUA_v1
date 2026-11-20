import AppKit
import QuartzCore

/// The guide callout (JARA-36 variant B): the step's words in a dark
/// label beside the glowing target, never on it. The layout is pure
/// top-left-space math so it tests without a window server; the panel
/// below only measures, places and fades.
enum GuideCallout {
    /// The smallest text the callout ever uses, in points.
    static let basePointSize: CGFloat = 17
    static let baseMaxWidth: CGFloat = 300
    static let basePadding = CGSize(width: 12, height: 9)
    static let cornerRadius: CGFloat = 12
    /// Clear space between the target's frame and the callout: the glow
    /// sits about 8 pt outside the frame, so the label stays off it.
    static let gap: CGFloat = 16
    /// Distance kept from the edge of the screen's visible area.
    static let margin: CGFloat = 8
    static let fadeSeconds: TimeInterval = 0.15
    static let pulseSeconds: TimeInterval = 0.7

    /// Which side of the target the callout sits on, in order of preference.
    enum Side: CaseIterable, Equatable {
        case below, above, right, left
    }

    /// How the callout moves: a fade in on each new step and one soft
    /// pulse on a re-point. Zero means instant, and nothing loops.
    struct Motion: Equatable {
        var fade: TimeInterval
        var pulse: TimeInterval
    }

    static func motion(reduceMotion: Bool) -> Motion {
        reduceMotion ? Motion(fade: 0, pulse: 0) : Motion(fade: fadeSeconds, pulse: pulseSeconds)
    }

    /// The words Jarvis speaks for the step, without the conversational
    /// lead-in: a consequential step names its effect first, as the
    /// spoken line does.
    static func text(for step: GuideStep) -> String {
        step.consequenceLine ?? step.instruction
    }

    /// Text size for a text-scale input; never below 17 pt.
    static func pointSize(textScale: CGFloat) -> CGFloat {
        max(basePointSize, (basePointSize * textScale).rounded())
    }

    static func padding(textScale: CGFloat) -> CGSize {
        let scale = max(1, textScale)
        return CGSize(width: (basePadding.width * scale).rounded(), height: (basePadding.height * scale).rounded())
    }

    /// The widest the callout grows: wider with larger text, never wider
    /// than the screen it sits on.
    static func maxWidth(textScale: CGFloat, screenWidth: CGFloat) -> CGFloat {
        min(baseMaxWidth * max(1, textScale), screenWidth - 2 * margin)
    }

    /// The screen (a visible frame in top-left points) the target sits
    /// on: the one holding its centre, else the one it overlaps most,
    /// else the nearest.
    static func screen(for target: CGRect, in screens: [CGRect]) -> CGRect? {
        let center = CGPoint(x: target.midX, y: target.midY)
        if let holding = screens.first(where: { $0.contains(center) }) { return holding }
        func overlap(_ s: CGRect) -> CGFloat {
            let i = s.intersection(target)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
        return screens.min { distance($0, center) < distance($1, center) }
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// Room for the callout on each side of the target, inside the screen.
    static func room(beside target: CGRect, on screen: CGRect) -> [Side: CGFloat] {
        [.below: screen.maxY - margin - target.maxY - gap,
         .above: target.minY - gap - screen.minY - margin,
         .right: screen.maxX - margin - target.maxX - gap,
         .left: target.minX - gap - screen.minX - margin]
    }

    /// Where the callout goes: the first side, in preference order, with
    /// room for it, centred on the target along that edge and kept on
    /// the screen. When no side has room it takes the roomiest one.
    static func placement(size: CGSize, target: CGRect, screen: CGRect) -> (frame: CGRect, side: Side) {
        let room = room(beside: target, on: screen)
        let fits = Side.allCases.first { side in
            switch side {
            case .below, .above: return room[side, default: 0] >= size.height
            case .right, .left: return room[side, default: 0] >= size.width
            }
        }
        let side = fits ?? Side.allCases.max { room[$0, default: 0] < room[$1, default: 0] } ?? .below
        let origin: CGPoint
        switch side {
        case .below: origin = CGPoint(x: target.midX - size.width / 2, y: target.maxY + gap)
        case .above: origin = CGPoint(x: target.midX - size.width / 2, y: target.minY - gap - size.height)
        case .right: origin = CGPoint(x: target.maxX + gap, y: target.midY - size.height / 2)
        case .left: origin = CGPoint(x: target.minX - gap - size.width, y: target.midY - size.height / 2)
        }
        let x = clamp(origin.x, screen.minX + margin, screen.maxX - margin - size.width)
        let y = clamp(origin.y, screen.minY + margin, screen.maxY - margin - size.height)
        return (CGRect(origin: CGPoint(x: x, y: y), size: size), side)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}

/// The callout's window: borderless, never key, blind to the mouse, on
/// every Space, and kept out of screenshots and screen sharing.
@MainActor
final class GuideCalloutPanel {
    /// Larger text, 1 by default. Comfort preferences set it.
    var textScale: CGFloat = 1
    /// System Reduce Motion: the fade and the pulse land instantly.
    /// Tests swap in a fixed answer.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The callout on screen now: its step, words and frame in top-left
    /// points. Nil while hidden.
    private(set) var shown: (step: Int, text: String, frame: CGRect)?

    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")

    private final class CalloutPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static func makePanel() -> NSPanel {
        let panel = CalloutPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = Self.makePanel()
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.cgColor
        card.layer?.cornerRadius = GuideCallout.cornerRadius
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        label.textColor = .white
        label.isSelectable = false
        card.addSubview(label)
        panel.contentView = card
        self.panel = panel
        return panel
    }

    /// Show the step's words beside its target. A step with no target on
    /// screen (a key press, a menu path) has nothing to sit beside, so the
    /// callout hides and the indicator tab carries the step.
    func show(_ step: GuideStep) {
        guard let target = step.target?.frame, target.width > 0, target.height > 0 else { hide(); return }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map {
            ScreenGeometry.topLeftFrame(cocoaFrame: $0.visibleFrame, primaryHeight: primary)
        }
        guard let screen = GuideCallout.screen(for: target, in: screens) else { hide(); return }
        let panel = ensurePanel()
        let text = GuideCallout.text(for: step)
        let padding = GuideCallout.padding(textScale: textScale)
        label.font = .systemFont(ofSize: GuideCallout.pointSize(textScale: textScale), weight: .semibold)
        label.stringValue = text
        let textWidth = GuideCallout.maxWidth(textScale: textScale, screenWidth: screen.width) - 2 * padding.width
        let fitted = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth,
                                                            height: .greatestFiniteMagnitude)) ?? .zero
        let textSize = CGSize(width: ceil(min(fitted.width, textWidth)), height: ceil(fitted.height))
        let size = CGSize(width: textSize.width + 2 * padding.width, height: textSize.height + 2 * padding.height)
        let frame = GuideCallout.placement(size: size, target: target, screen: screen).frame
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: textSize)
        panel.setFrame(TargetOverlay.appKitFrame(for: frame), display: true)
        let fresh = !panel.isVisible || shown?.step != step.number || shown?.text != text
        shown = (step.number, text, frame)
        guard fresh else { return }
        let motion = GuideCallout.motion(reduceMotion: reduceMotion())
        panel.contentView?.layer?.removeAllAnimations()
        guard motion.fade > 0 else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fade
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 1
        }
    }

    /// One soft pulse when Jarvis points at the same step again.
    func pulse() {
        guard shown != nil, let layer = panel?.contentView?.layer else { return }
        let motion = GuideCallout.motion(reduceMotion: reduceMotion())
        guard motion.pulse > 0 else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0.55, 1]
        animation.keyTimes = [0, 0.35, 1]
        animation.duration = motion.pulse
        animation.repeatCount = 1
        layer.add(animation, forKey: "pulse")
    }

    func hide() {
        panel?.contentView?.layer?.removeAllAnimations()
        panel?.orderOut(nil)
        shown = nil
    }
}
