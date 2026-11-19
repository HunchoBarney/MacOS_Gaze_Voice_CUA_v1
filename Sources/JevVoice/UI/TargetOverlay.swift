import AppKit
import QuartzCore
import SwiftUI

/// "Aim" — the user's second cursor. Overlay grammar for this file: the
/// blue frosted halo marks the user's current target and anchors to
/// element frames (never the raw gaze point, so it can't lag the
/// tracker's dead-reckoned pearl dot); dark compact pills carry the
/// options for a bounded choice; a ring flash confirms a
/// verified action landed. While an agent acts on the same element the
/// halo stands down (dims) rather than fighting the agent's flash.
///
/// Every incoming frame/point is a global TOP-LEFT screen point; panel
/// frames cross `ScreenGeometry.topLeftToAppKit` exactly once, flipped
/// at the rect's bottom-left corner. Panels are borderless,
/// nonactivating, floating at screen-saver level on every Space, and
/// blind to the mouse — pure observability.
@MainActor
final class TargetOverlay {
    static let shared = TargetOverlay()

    private let presentsPanels: Bool

    init(presentsPanels: Bool = true) {
        self.presentsPanels = presentsPanels
    }

    /// Chips are currently up and a voice index should resolve against them.
    private(set) var pendingCount: Int = 0

    // MARK: Tunables

    /// The halo sits this far outside the element frame.
    static let haloOutset: CGFloat = 8
    static let haloCorner: CGFloat = 12
    static let haloAlpha: CGFloat = 0.9
    /// Stand-down alpha while an agent acts on the same element.
    static let haloDimmedAlpha: CGFloat = 0.3
    /// Stand-down alpha on armed chips while the gaze feed is stale —
    /// the set stays painted but reads "not tracking", never a live
    /// dwell target.
    static let chipsDimmedAlpha: CGFloat = 0.4
    static let maxRadialChips = 8
    /// Chips land ON the tracker error band; the floor keeps them off
    /// the target itself.
    nonisolated static let minRadialRadius: Double = 40
    /// Floored chip side so dwell hit rects never degenerate.
    static let minChipSide: CGFloat = 22
    static let flashCanvas: CGFloat = 80
    static let flashStart: CGFloat = 8
    static let flashEnd: CGFloat = 36
    static let flashSeconds: CFTimeInterval = 0.4
    /// The cheat sheet hangs this far below the screen's top edge.
    static let cheatSheetDrop: CGFloat = 24
    /// Conforming ring: outset off the element frame, the dot a fresh
    /// acquire blooms from, morph + retarget durations, stroke width,
    /// and the padding the panel adds around a morph's bounding union.
    nonisolated static let ringOutset: CGFloat = 5
    nonisolated static let ringDotSize: CGFloat = 8
    static let ringMorphSeconds: CFTimeInterval = 0.16
    static let ringRetargetSeconds: CFTimeInterval = 0.10
    static let ringLineWidth: CGFloat = 2
    static let ringPanelPad: CGFloat = 10
    /// Meta's sustained-dwell fade — the ring settles toward this alpha
    /// once the countdown passes halfway rather than sitting bright in
    /// the fovea.
    nonisolated static let ringDwellFloor: Double = 0.65

    /// Monotonic seconds for the dwell clock — tests swap in a fake.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    // MARK: Pure math (unit-tested without panels)

    /// First chip whose top-left-space rect contains the point — the
    /// same order the panels draw in, so overlap resolves deterministically.
    nonisolated static func chipIndex(under point: CGPoint,
                                      chips: [(index: Int, rect: CGRect)]) -> Int? {
        chips.first(where: { $0.rect.contains(point) })?.index
    }

    /// Chip centers for the micro-radial, fanned upward around `point`
    /// on a circle at `radius` (clamped up to `minRadialRadius` so chips
    /// never cover the target itself). Top-left space: -π/2 is "up".
    nonisolated static func radialChipCenters(count: Int, near point: CGPoint,
                                              radius: Double) -> [CGPoint] {
        guard count > 0 else { return [] }
        let r = max(radius, minRadialRadius)
        guard count > 1 else { return [CGPoint(x: point.x, y: point.y - r)] }
        let spread = min(70 * Double(count - 1), 210) * .pi / 180
        let start = -Double.pi / 2 - spread / 2
        return (0..<count).map { i in
            let theta = start + spread * Double(i) / Double(count - 1)
            return CGPoint(x: point.x + r * cos(theta),
                           y: point.y + r * sin(theta))
        }
    }

    /// Top-left-space rect → AppKit panel frame. The flip lands on the
    /// rect's bottom-left corner (minX, maxY); sizes pass through.
    static func appKitFrame(for rect: CGRect) -> NSRect {
        NSRect(origin: ScreenGeometry.topLeftToAppKit(
            CGPoint(x: rect.minX, y: rect.maxY)), size: rect.size)
    }

    /// The element shape the ring conforms to — feedback lives on the
    /// element, not the gaze point. Traffic lights circle `motorRect`
    /// (the button, not the window); DOM candidates read as capsules;
    /// small near-squares get a circle; wide-and-shorts a capsule;
    /// everything else a rounded-rect hugging the frame.
    nonisolated static func ringTarget(for c: IntentCandidate)
        -> (rect: CGRect, corner: CGFloat) {
        if c.kind == .trafficLight {
            let m = c.motorRect.insetBy(dx: -ringOutset, dy: -ringOutset)
            let d = max(m.width, m.height)
            return (CGRect(x: m.midX - d / 2, y: m.midY - d / 2,
                           width: d, height: d), d / 2)
        }
        let r = c.frame.insetBy(dx: -ringOutset, dy: -ringOutset)
        if c.kind == .dom { return (r, min(r.width, r.height) / 2) }
        let w = r.width, h = r.height
        if max(w, h) <= 64, abs(w - h) <= max(6, min(w, h) / 4) {
            let d = max(w, h)
            return (CGRect(x: r.midX - d / 2, y: r.midY - d / 2,
                           width: d, height: d), d / 2)
        }
        if w > h, h <= 56 { return (r, h / 2) }
        return (r, min(8, h / 4))
    }

    /// The little circle a fresh acquire blooms out of — centered on
    /// the last gaze point (or the element center as fallback).
    nonisolated static func ringDotGeo(at point: CGPoint)
        -> (rect: CGRect, corner: CGFloat) {
        (CGRect(x: point.x - ringDotSize / 2, y: point.y - ringDotSize / 2,
                width: ringDotSize, height: ringDotSize), ringDotSize / 2)
    }

    /// Ease-out cubic — springish 160ms feel while staying a pure t-map,
    /// which is what makes mid-morph reversal computable.
    nonisolated static func ringEase(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return 1 - pow(1 - t, 3)
    }

    /// Geometry interpolation — every ring shape is a rounded-rect
    /// (circles/capsules are corner-radius extremes), so (rect, corner)
    /// pairs always lerp cleanly and CA path morphs stay interpolable.
    nonisolated static func lerpRing(from a: (rect: CGRect, corner: CGFloat),
                                     to b: (rect: CGRect, corner: CGFloat),
                                     t: Double) -> (rect: CGRect, corner: CGFloat) {
        let t = CGFloat(t)
        return (CGRect(x: a.rect.minX + (b.rect.minX - a.rect.minX) * t,
                       y: a.rect.minY + (b.rect.minY - a.rect.minY) * t,
                       width: a.rect.width + (b.rect.width - a.rect.width) * t,
                       height: a.rect.height + (b.rect.height - a.rect.height) * t),
                a.corner + (b.corner - a.corner) * t)
    }

    /// Dwell countdown → ring alpha: full through the halfway point,
    /// then fades toward the floor per Meta's sustained-dwell guidance.
    nonisolated static func ringAlpha(progress: Double) -> Double {
        guard progress > 0.5 else { return 1 }
        return 1 - (1 - ringDwellFloor) * min(1, (progress - 0.5) * 2)
    }

    /// Canvas-relative rounded-rect path — the ring view is flipped, so
    /// top-left canvas offsets are path coordinates. Emitting the same
    /// rounded-rect structure for every shape is what keeps CA path
    /// interpolation valid across dot→circle→capsule→rect morphs.
    nonisolated static func ringPath(_ g: (rect: CGRect, corner: CGFloat),
                                     in canvas: CGRect) -> CGPath {
        CGPath(roundedRect: g.rect.offsetBy(dx: -canvas.minX, dy: -canvas.minY),
               cornerWidth: g.corner, cornerHeight: g.corner, transform: nil)
    }

    /// The chip-dwell clock — a pure value type so the pick path is
    /// testable without panels. `chips` are top-left-space hit rects;
    /// `advance` fires an index once the point has stayed inside one
    /// chip's rect for `threshold` seconds. Firing consumes the hold:
    /// the gaze must leave and re-enter before that chip can fire again.
    /// Separate from the tracker's own dwell-lock setting by design.
    struct DwellTracker {
        var threshold: TimeInterval = 0.5
        var chips: [(index: Int, rect: CGRect)] = [] {
            didSet { hovered = nil; enteredAt = nil }
        }
        private var hovered: Int?
        private var enteredAt: TimeInterval?

        mutating func advance(point: CGPoint, now: TimeInterval) -> Int? {
            let hit = TargetOverlay.chipIndex(under: point, chips: chips)
            guard let hit else { hovered = nil; enteredAt = nil; return nil }
            if hit != hovered {
                hovered = hit
                enteredAt = now
                return nil
            }
            // Epsilon keeps the ≥threshold contract honest at decimal
            // boundaries — 1.4 - 0.9 lands a hair under 0.5 in Double.
            guard let enteredAt, now - enteredAt >= threshold - 1e-9 else { return nil }
            self.enteredAt = nil
            return hit
        }
    }

    /// Interruptible morph bookkeeping for the conforming ring — the
    /// rendered layers chase this model with CA path animations.
    /// `retarget` captures wherever the morph currently is, so
    /// acquire→release→acquire never jumps; a pure value type keeps the
    /// reversal math testable without panels.
    struct RingMorph {
        var from: (rect: CGRect, corner: CGFloat) = (.zero, 0)
        var to: (rect: CGRect, corner: CGFloat) = (.zero, 0)
        var startedAt: TimeInterval = 0
        var duration: TimeInterval = 0
        var active = false

        /// Where the morph is right now — eased interpolation from→to.
        func current(at now: TimeInterval) -> (rect: CGRect, corner: CGFloat) {
            guard active, duration > 0 else { return to }
            return TargetOverlay.lerpRing(from: from, to: to,
                t: TargetOverlay.ringEase((now - startedAt) / duration))
        }

        /// Aim the morph at `target`, starting from wherever it is now.
        mutating func retarget(to target: (rect: CGRect, corner: CGFloat),
                               at now: TimeInterval, duration: TimeInterval) {
            from = current(at: now)
            to = target
            startedAt = now
            self.duration = duration
            active = true
        }
    }

    // MARK: Panels

    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The shared chrome — borderless, nonactivating, above everything
    /// including full-screen windows, on every Space, blind to the mouse.
    private static func makePanel() -> NSPanel {
        let panel = OverlayPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    private var haloPanel: NSPanel?
    /// Last shown halo rect (top-left space) — the demote check reads it.
    private var haloRect: CGRect?
    /// A halo is painted — the gaze pump reads this so a stale one can
    /// be ordered out instead of reading as a frozen claim.
    var haloArmed: Bool { haloRect != nil }
    /// Frames where agents are acting — the halo stands down on any hit.
    private var agentDemoteFrames: [CGRect] = []
    /// Reused chip panels, ordered by chip index.
    private var chipPanels: [NSPanel] = []
    private var dwell = DwellTracker()
    private(set) var previewedChip: Int?
    /// The stale-feed dim on armed chips — driven only by `gazeLost`,
    /// so a re-arm during the same outage keeps the dim.
    private var gazeDimmed = false
    private var cheatPanel: NSPanel?
    private var ringPanel: NSPanel?
    private var ringView: IntentRingView?
    /// The rect the ring claims — the element frame plus outset, never
    /// the gaze point. nil while idle or once a release starts: a
    /// fading ring no longer asserts a target.
    private(set) var ringRect: CGRect?
    /// A ring is painted on an element — mirrors `haloArmed`. Read
    /// surface for the coordinator/tests asserting ring lifecycle —
    /// nothing renders off it.
    var ringArmed: Bool { ringRect != nil }
    /// Dwell fill 0→1 — `hold` events stream it onto the fill stroke.
    /// Read surface for tests; the rendered value lives on the view.
    private(set) var ringProgress: Double = 0
    /// Interruptibility bookkeeping — see RingMorph.
    private(set) var ringMorph = RingMorph()
    /// A morph or fade is in flight — release keeps this true until the
    /// fade retires the panel, so a re-acquire continues the morph
    /// instead of restarting it.
    private var ringLive = false
    /// Bumped on every acquire/hide — a stale retire task can never
    /// order out a live ring's panel.
    private var ringGeneration = 0
    /// Last gaze point seen by `ingestGaze` — the morph's bloom origin.
    private var lastGazePoint: CGPoint?

    // MARK: Halo

    /// Frosted halo on an element frame (top-left points). Repeated calls
    /// just move the one panel — cheap enough for 10Hz retargeting, and
    /// visible panels are never reordered.
    func showHalo(frame: CGRect) {
        let rect = frame.insetBy(dx: -Self.haloOutset, dy: -Self.haloOutset)
        if haloPanel == nil {
            let panel = Self.makePanel()
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.haloCorner
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 1.5
            effect.layer?.borderColor = NSColor.systemBlue.cgColor
            panel.contentView = effect
            haloPanel = panel
        }
        haloRect = rect
        haloPanel?.setFrame(Self.appKitFrame(for: rect), display: true)
        applyHaloAlpha()
        if presentsPanels, haloPanel?.isVisible == false { haloPanel?.orderFrontRegardless() }
    }

    func hideHalo() {
        haloPanel?.orderOut(nil)
        haloRect = nil
    }

    /// All currently-acting agent chip rects — a distant pair must not
    /// dim the halo the way one union rect spanning both would.
    func agentChips(_ frames: [CGRect]) {
        agentDemoteFrames = frames
        applyHaloAlpha()
    }

    private func applyHaloAlpha() {
        let dimmed = haloRect.map { h in agentDemoteFrames.contains { $0.intersects(h) } } ?? false
        haloPanel?.alphaValue = dimmed ? Self.haloDimmedAlpha : Self.haloAlpha
        applyRingAlpha()
    }

    /// Same stand-down as the halo — the ring dims rather than fighting
    /// an agent cursor acting on the same element.
    private func applyRingAlpha() {
        let dimmed = ringRect.map { r in agentDemoteFrames.contains { $0.intersects(r) } } ?? false
        ringPanel?.alphaValue = dimmed ? Self.haloDimmedAlpha : 1
    }

    /// The gaze feed went stale (or recovered) while chips are armed —
    /// dim the set so a dead tracker can't pass for a live dwell pick.
    /// Voice picks still resolve; only the "tracker is healthy" read dims.
    func gazeLost(_ lost: Bool) {
        guard lost != gazeDimmed else { return }
        gazeDimmed = lost
        applyChipAlpha()
    }

    private func applyChipAlpha() {
        for panel in chipPanels {
            panel.alphaValue = gazeDimmed ? Self.chipsDimmedAlpha : 1
        }
    }

    // MARK: Choice chips

    /// Dark compact pill — a 1-based number with an optional caption.
    private struct TargetChip: View {
        let index: Int
        var caption: String? = nil
        var previewed = false
        var select: () -> Void = {}
        var body: some View {
            HStack(spacing: 5) {
                Text("\(index)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, caption?.isEmpty == false ? 9 : 0)
            .frame(minWidth: 24, minHeight: 24)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(previewed ? Color.accentColor : .white.opacity(0.3), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { select() }
            .colorScheme(.dark)
        }
    }

    private func chipPanel(at index: Int) -> (NSPanel, NSHostingView<TargetChip>) {
        while chipPanels.count <= index {
            let hosting = NSHostingView(rootView: TargetChip(index: 0))
            let panel = Self.makePanel()
            panel.contentView = hosting
            chipPanels.append(panel)
        }
        let panel = chipPanels[index]
        return (panel, panel.contentView as! NSHostingView<TargetChip>)
    }

    /// Arms (or re-arms — a second call replaces, never stacks) the chip
    /// set: panels positioned, hit rects loaded into the dwell clock.
    private func armChips(_ specs: [(center: CGPoint, index: Int, caption: String?)],
                          onPick: @escaping @MainActor (Int) -> Void) {
        clearChips()
        var rects: [(index: Int, rect: CGRect)] = []
        for (i, spec) in specs.enumerated() {
            let (panel, hosting) = chipPanel(at: i)
            hosting.rootView = TargetChip(index: spec.index, caption: spec.caption, select: { onPick(i) })
            let fit = hosting.fittingSize
            let size = CGSize(width: max(fit.width, Self.minChipSide),
                              height: max(fit.height, Self.minChipSide))
            let rect = CGRect(x: spec.center.x - size.width / 2,
                              y: spec.center.y - size.height / 2,
                              width: size.width, height: size.height)
            panel.setFrame(Self.appKitFrame(for: rect), display: true)
            if presentsPanels { panel.orderFrontRegardless() }
            rects.append((i, rect))
        }
        // A set armed mid-outage inherits the stale-feed dim.
        applyChipAlpha()
        dwell.chips = rects
        pendingCount = rects.count
    }

    private func clearChips() {
        for panel in chipPanels { panel.orderOut(nil) }
        dwell.chips = []
        previewedChip = nil
        pendingCount = 0
    }

    /// Micro-radial: dark pills fanned near `point` (top-left points) at
    /// `radius` — the caller's measured tracker error band. Chips sit on
    /// the band, never inside it. onPick gets a 0-based index. A radial
    /// always retires on pick — its ask resolves exactly once.
    func showRadial(labels: [String], near point: CGPoint, radius: Double,
                    onPick: @escaping @MainActor (Int) -> Void) {
        let centers = Self.radialChipCenters(count: min(labels.count, Self.maxRadialChips),
                                             near: point, radius: radius)
        let specs: [(center: CGPoint, index: Int, caption: String?)] =
            centers.enumerated().map { (i, center) in
                (center: center, index: i + 1, caption: labels[i])
            }
        armChips(specs, onPick: onPick)
    }

    /// Retract ONLY the chip pick set — a resolved pick (or a gaze
    /// radial that lost its contest) drops the chips and the pick path
    /// without touching the conforming ring, halo, or cheat sheet:
    /// those belong to other owners and retire on their own lifecycle.
    /// `hideAll` is the full-teardown form.
    func hideChips() { clearChips() }

    /// Dismiss everything — chips, pending state, halo, cheat sheet.
    /// Flashes finish on their own: a landed action's ring confirms it.
    /// Full teardown only; pick resolution uses `hideChips` so the
    /// scorer's ring survives.
    func hideAll() {
        clearChips()
        retireRing()
        hideHalo()
        cheatPanel?.orderOut(nil)
        cheatPanel = nil
    }

    /// Looking may preview a parked choice; only an explicit answer selects it.
    func ingestGaze(_ point: CGPoint) {
        lastGazePoint = point
        guard pendingCount > 0 else { return }
        if let index = previewedChip, !dwell.chips[index].rect.contains(point) {
            chipPanel(at: index).1.rootView.previewed = false
            previewedChip = nil
        }
        if let index = dwell.advance(point: point, now: now()) {
            chipPanel(at: index).1.rootView.previewed = true
            previewedChip = index
        }
    }

    // MARK: Conforming ring

    /// Gaze-intent event feed — the scorer's acquire/hold/release
    /// transitions drive the conforming ring on a resolved control.
    func intentEvent(_ event: IntentEvent, dwellFeedback: Bool = false) {
        switch event {
        case .none, .ambiguous:
            releaseRing()
        case .acquire(let c):
            if dwellFeedback || Self.highlightsControl(c) { acquireRing(on: c) }
            else { releaseRing() }
        case .hold(let c, let progress):
            if dwellFeedback { holdRing(on: c, progress: progress) }
            else if progress < 0.55 && Self.highlightsControl(c) { holdRing(on: c, progress: 0) }
            else { releaseRing() }
        case .release(let c):
            releaseRing(fallbackAnchor: CGPoint(x: c.frame.midX, y: c.frame.midY))
        }
    }

    private static func highlightsControl(_ candidate: IntentCandidate) -> Bool {
        switch candidate.kind {
        case .axElement, .trafficLight, .menuBar, .dom: true
        case .window, .ocr, .agentCursor, .chip: false
        }
    }

    /// The conforming ring itself: a faint full-shape base plus a
    /// brighter stroke that sweeps 0→1 with dwell progress, inside a
    /// container layer whose opacity carries the dwell-fade and the
    /// release fade-out. `isFlipped` puts the backing layer in top-left
    /// coordinates so paths are canvas-relative without a second flip.
    final class IntentRingView: NSView {
        let container = CALayer()
        let base = CAShapeLayer()
        let fill = CAShapeLayer()

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            base.strokeColor = NSColor.systemBlue.withAlphaComponent(0.45).cgColor
            base.fillColor = NSColor.clear.cgColor
            base.lineWidth = TargetOverlay.ringLineWidth
            fill.strokeColor = NSColor.systemBlue.cgColor
            fill.fillColor = NSColor.clear.cgColor
            fill.lineWidth = TargetOverlay.ringLineWidth + 1
            fill.lineCap = .round
            fill.strokeEnd = 0
            container.addSublayer(base)
            container.addSublayer(fill)
            layer?.addSublayer(container)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        /// Model paths land on `to`; one keyed animation covers the
        /// transit. Re-morphing replaces the same key, and because
        /// `from` is the morph model's *current* geometry a reverse
        /// starts exactly where the ring visually is — no jump. All
        /// paths share the rounded-rect structure, so CA path
        /// interpolation always applies.
        func morph(from: (rect: CGRect, corner: CGFloat),
                   to: (rect: CGRect, corner: CGFloat),
                   in canvas: CGRect, duration: CFTimeInterval) {
            let fromPath = TargetOverlay.ringPath(from, in: canvas)
            let toPath = TargetOverlay.ringPath(to, in: canvas)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = CGRect(origin: .zero, size: canvas.size)
            for l in [base, fill] {
                l.frame = container.bounds
                l.path = toPath
                let anim = CABasicAnimation(keyPath: "path")
                anim.fromValue = fromPath
                anim.toValue = toPath
                anim.duration = duration
                anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1.0)
                l.add(anim, forKey: "morph")
            }
            CATransaction.commit()
        }

        /// Dwell countdown — the fill stroke sweeps 0→1 while the whole
        /// ring fades toward the floor once progress passes halfway.
        func setProgress(_ progress: Double) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.strokeEnd = CGFloat(min(1, max(0, progress)))
            container.opacity = Float(TargetOverlay.ringAlpha(progress: progress))
            CATransaction.commit()
        }

        /// Fade the whole ring — release fades to 0, a re-acquire from
        /// mid-fade animates back up from wherever the presentation is.
        func fade(to alpha: Float, duration: CFTimeInterval) {
            let current = container.presentation()?.opacity ?? container.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.opacity = alpha
            CATransaction.commit()
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = NSNumber(value: current)
            anim.toValue = NSNumber(value: alpha)
            anim.duration = duration
            container.add(anim, forKey: "fade")
        }
    }

    /// Dot → element morph on acquire; element → element retarget when
    /// the ring is already live (handover to a different candidate).
    private func acquireRing(on c: IntentCandidate) {
        ringGeneration += 1
        ensureRing()
        let target = Self.ringTarget(for: c)
        let t = now()
        if ringLive || ringReleasing {
            // Retarget from wherever the morph is now — a re-acquire mid
            // -release continues the shape, never teleports.
            ringMorph.retarget(to: target, at: t, duration: Self.ringMorphSeconds)
        } else {
            let anchor = lastGazePoint
                ?? CGPoint(x: target.rect.midX, y: target.rect.midY)
            ringMorph = RingMorph(from: Self.ringDotGeo(at: anchor), to: target,
                                  startedAt: t, duration: Self.ringMorphSeconds,
                                  active: true)
        }
        ringLive = true
        ringReleasing = false
        // Invalidate any pending retire from the release we're cancelling —
        // otherwise it fires mid-acquire and orders the panel out.
        ringGeneration += 1
        ringRect = target.rect
        ringProgress = 0
        presentRing(duration: Self.ringMorphSeconds)
        ringView?.setProgress(0)
        ringView?.fade(to: 1, duration: Self.ringMorphSeconds)
        applyRingAlpha()
        if presentsPanels, ringPanel?.isVisible == false { ringPanel?.orderFrontRegardless() }
    }

    /// Streams the dwell countdown onto the fill stroke and re-targets
    /// the morph when a refreshed feed moved the element.
    private func holdRing(on c: IntentCandidate, progress: Double) {
        if !ringLive || ringReleasing { acquireRing(on: c) }
        let target = Self.ringTarget(for: c)
        let previousRect = ringRect
        if target != ringMorph.to {
            ringMorph.retarget(to: target, at: now(),
                               duration: Self.ringRetargetSeconds)
            presentRing(duration: Self.ringRetargetSeconds)
        }
        ringRect = target.rect
        if ringProgress != progress {
            ringProgress = progress
            ringView?.setProgress(progress)
        }
        if target.rect != previousRect { applyRingAlpha() }
    }

    /// Reverse morph + fade; the panel retires itself, generation-
    /// guarded so a re-acquire mid-fade can never lose its panel.
    /// `ringReleasing` makes the release a one-shot transition — repeated
    /// `.none`/`.release` ticks must not restart the morph and fade.
    private var ringReleasing = false
    private func releaseRing(fallbackAnchor: CGPoint? = nil) {
        guard ringLive, !ringReleasing else { return }
        ringReleasing = true
        let anchor = lastGazePoint ?? fallbackAnchor
            ?? ringRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
        ringMorph.retarget(to: Self.ringDotGeo(at: anchor), at: now(),
                           duration: Self.ringMorphSeconds)
        ringRect = nil
        presentRing(duration: Self.ringMorphSeconds)
        ringView?.fade(to: 0, duration: Self.ringMorphSeconds)
        let generation = ringGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.ringMorphSeconds * 1e9) + 80_000_000)
            guard let self, self.ringGeneration == generation else { return }
            self.ringPanel?.orderOut(nil)
            self.ringLive = false
            self.ringReleasing = false
            self.ringMorph.active = false
        }
    }

    private func ensureRing() {
        guard ringPanel == nil else { return }
        let panel = Self.makePanel()
        let view = IntentRingView(frame: .zero)
        panel.contentView = view
        ringPanel = panel
        ringView = view
    }

    /// The panel covers the union of the morph's endpoints — the dot a
    /// morph blooms from can sit off the element — padded past the
    /// stroke. Paths draw canvas-relative, so panel moves never distort
    /// the geometry.
    private func presentRing(duration: CFTimeInterval) {
        let canvas = ringMorph.from.rect.union(ringMorph.to.rect)
            .insetBy(dx: -Self.ringPanelPad, dy: -Self.ringPanelPad)
        ringPanel?.setFrame(Self.appKitFrame(for: canvas), display: true)
        ringView?.morph(from: ringMorph.from, to: ringMorph.to,
                        in: canvas, duration: duration)
    }

    private func retireRing() {
        ringGeneration += 1
        ringPanel?.orderOut(nil)
        ringLive = false
        ringReleasing = false
        ringMorph.active = false
        ringRect = nil
        ringProgress = 0
    }

    // MARK: Flash

    /// Stroked circle that expands+fades via two CABasicAnimations —
    /// model state lands on the end values so removal is seamless.
    private final class FlashRing: NSView {
        private let ring = CAShapeLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            ring.frame = bounds
            ring.strokeColor = NSColor.systemBlue.cgColor
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 2
            layer?.addSublayer(ring)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        func fire(duration: CFTimeInterval) {
            func ellipse(_ d: CGFloat) -> CGPath {
                CGPath(ellipseIn: CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2,
                                         width: d, height: d), transform: nil)
            }
            ring.path = ellipse(TargetOverlay.flashEnd)
            ring.opacity = 0
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = ellipse(TargetOverlay.flashStart)
            grow.toValue = ellipse(TargetOverlay.flashEnd)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0 as NSNumber
            fade.toValue = 0.0 as NSNumber
            for anim in [grow, fade] {
                anim.duration = duration
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ring.add(anim, forKey: anim.keyPath)
            }
        }
    }

    /// Verified-action confirmation — a ring expanding ~8→36px and
    /// fading 1→0 over ~400ms at `point` (top-left points). Non-blocking;
    /// the panel retires itself.
    func flash(at point: CGPoint) {
        guard presentsPanels else { return }
        let size = Self.flashCanvas
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2,
                          width: size, height: size)
        let panel = Self.makePanel()
        let ring = FlashRing(frame: NSRect(origin: .zero, size: rect.size))
        panel.contentView = ring
        panel.setFrame(Self.appKitFrame(for: rect), display: true)
        panel.orderFrontRegardless()
        ring.fire(duration: Self.flashSeconds)
        Task { [weak panel] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flashSeconds * 1e9) + 80_000_000)
            panel?.orderOut(nil)
            panel?.contentView = nil
        }
    }

    // MARK: Cheat sheet

    /// Compact "category: phrases" listing for the cheat-sheet panel.
    private struct CheatSheet: View {
        let lines: [String]
        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(lines.indices, id: \.self) { line(lines[$0]) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .colorScheme(.dark)
        }
        /// "Category: phrase" renders the category bold, the rest plain.
        private func line(_ s: String) -> Text {
            var attributed = AttributedString(s)
            attributed.font = .system(size: 11)
            if let colon = s.firstIndex(of: ":") {
                let end = attributed.index(attributed.startIndex,
                    offsetByCharacters: s.distance(from: s.startIndex, to: colon))
                attributed[attributed.startIndex..<end].font = .system(size: 11, weight: .semibold)
            }
            return Text(attributed)
        }
    }

    /// "what can I say" panel — hangs top-center of the screen under the
    /// pointer. A second call toggles it off; hideAll dismisses it too.
    func showCheatSheet(lines: [String]) {
        if let panel = cheatPanel {
            panel.orderOut(nil)
            cheatPanel = nil
            return
        }
        let hosting = NSHostingView(rootView: CheatSheet(lines: lines))
        let panel = Self.makePanel()
        panel.contentView = hosting
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let sf = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: sf.midX - size.width / 2,
                              y: sf.maxY - size.height - Self.cheatSheetDrop,
                              width: size.width, height: size.height), display: true)
        if presentsPanels { panel.orderFrontRegardless() }
        cheatPanel = panel
    }
}
