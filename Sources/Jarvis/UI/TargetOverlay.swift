import AppKit
import QuartzCore
import SwiftUI

/// "Aim" — the user's second cursor. Overlay grammar for this file: the
/// Magnet (GazeMagnet.swift) is the one gaze highlight, an orb at the
/// gaze that stretches onto the control it settles on; the blue frosted
/// halo marks a control Jarvis points out (an answer, a guide step) and
/// the Magnet steps back while it shows; dark compact pills carry the
/// numbered targets and the micro-radial; a ring flash confirms a
/// verified action landed. While an agent acts on the same element the
/// glow and halo stand down (dim) rather than fighting the agent's flash.
///
/// Every incoming frame/point is a global TOP-LEFT screen point; panel
/// frames cross `ScreenGeometry.topLeftToAppKit` exactly once, flipped
/// at the rect's bottom-left corner. Panels are borderless,
/// nonactivating, floating at screen-saver level on every Space, and
/// blind to the mouse — pure observability.
@MainActor
final class TargetOverlay {
    static let shared = TargetOverlay()

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
    /// Number chips are refused past this many — a spoken index can't
    /// honestly resolve against more.
    static let maxNumberChips = 60
    static let maxRadialChips = 8
    /// Chips land ON the tracker error band; the floor keeps them off
    /// the target itself.
    nonisolated static let minRadialRadius: Double = 40
    /// Number-chip center nudge from the target's top-left corner —
    /// slightly outboard so the chip tags the target without covering it.
    static let numberNudge = CGPoint(x: -6, y: -6)
    /// Floored chip side so dwell hit rects never degenerate.
    static let minChipSide: CGFloat = 22
    static let flashCanvas: CGFloat = 80
    static let flashStart: CGFloat = 8
    static let flashEnd: CGFloat = 36
    static let flashSeconds: CFTimeInterval = 0.4
    /// The cheat sheet hangs this far below the screen's top edge.
    static let cheatSheetDrop: CGFloat = 24
    /// Gaze highlight: outset off the element frame.
    nonisolated static let ringOutset: CGFloat = 5
    /// Nothing larger locks the glow — a pane, list or document is not a
    /// control, and outlining one reads as "the whole screen".
    nonisolated static let lockMaxSize = CGSize(width: 320, height: 200)
    /// The glow locks onto a control only while the gaze error band σ is
    /// at most this many times the control's size; past it the tracker
    /// can't tell the control from its neighbours, so only the orb shows.
    nonisolated static let lockSigmaFactor: Double = 1.5
    /// The orb follows the gaze on a critically damped spring — it smooths
    /// the tracker's 15 Hz steps without overshoot on a surface that moves
    /// all the time.
    static let orbFollow = Animation.spring(duration: 0.35, bounce: 0)
    /// Orb ↔ glow: one quick spring with a touch of life, interruptible
    /// mid-flight. Reduce Motion crossfades instead.
    static let magnetMorph = Animation.spring(duration: 0.3, bounce: 0.12)
    static let magnetCrossfade = Animation.easeOut(duration: 0.15)
    /// Meta's sustained-dwell fade — the ring settles toward this alpha
    /// once the countdown passes halfway rather than sitting bright in
    /// the fovea.
    nonisolated static let ringDwellFloor: Double = 0.65

    /// System Reduce Motion — morphs and the confirm ring land without
    /// travelling; the gaze highlight keeps only its opacity fades and
    /// jumps between elements instead of gliding. Tests swap in a fixed
    /// answer.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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
        if c.kind == .dom {
            let r = c.frame.insetBy(dx: -ringOutset, dy: -ringOutset)
            return (r, min(r.width, r.height) / 2)
        }
        return ringTarget(frame: c.frame)
    }

    /// The ring's shape on a plain control frame (top-left points).
    nonisolated static func ringTarget(frame: CGRect) -> (rect: CGRect, corner: CGFloat) {
        let r = frame.insetBy(dx: -ringOutset, dy: -ringOutset)
        let w = r.width, h = r.height
        if max(w, h) <= 64, abs(w - h) <= max(6, min(w, h) / 4) {
            let d = max(w, h)
            return (CGRect(x: r.midX - d / 2, y: r.midY - d / 2,
                           width: d, height: d), d / 2)
        }
        if w > h, h <= 56 { return (r, h / 2) }
        return (r, min(8, h / 4))
    }

    /// Dwell countdown → ring alpha: full through the halfway point,
    /// then fades toward the floor per Meta's sustained-dwell guidance.
    /// A plain look-highlight (dwell off) has no countdown and stays put.
    nonisolated static func ringAlpha(progress: Double, dwell: Bool = true) -> Double {
        guard dwell, progress > 0.5 else { return 1 }
        return 1 - (1 - ringDwellFloor) * min(1, (progress - 0.5) * 2)
    }

    /// Canvas-relative rounded-rect path — top-left canvas offsets are
    /// path coordinates in a flipped view. The deictic flash draws its
    /// ring with it.
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

    // MARK: Panels

    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The shared chrome — borderless, nonactivating, above everything
    /// including full-screen windows, on every Space, blind to the mouse,
    /// and left out of screenshots, recordings and screen shares.
    static func makePanel() -> NSPanel {
        let panel = OverlayPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
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
    private var onPick: (@MainActor (Int) -> Void)?
    /// Whether a resolved pick retires the armed set — always true for
    /// radials (one answer), `!persistent` for number chips.
    private var dismissOnPick = true
    /// The stale-feed dim on armed chips — driven only by `gazeLost`,
    /// so a re-arm during the same outage keeps the dim.
    private var gazeDimmed = false
    private var cheatPanel: NSPanel?
    /// The Magnet — the one gaze highlight. Tests read its state.
    let magnet = GazeMagnetModel()
    private var magnetPanel: NSPanel?
    /// Bumped on every lock change and teardown — a stale press-glow
    /// release or panel retire can never undo a newer lock.
    private var magnetGeneration = 0
    private var lastGazeAt: TimeInterval = -.greatestFiniteMagnitude
    private var orbWatchdog: Task<Void, Never>?
    /// The rect the glow claims — the element frame plus outset, never
    /// the gaze point. nil while only the orb shows: a glow shrinking
    /// back into the orb no longer asserts a target.
    var ringRect: CGRect? { magnet.state.lock?.rect }
    /// The glow is on an element — mirrors `haloArmed`. Read surface for
    /// the coordinator and tests; nothing renders off it.
    var ringArmed: Bool { ringRect != nil }
    /// Dwell fill 0→1 — `hold` events stream it onto the sweep stroke.
    var ringProgress: Double { magnet.state.progress }
    /// The gaze orb is showing.
    var orbShown: Bool { magnet.state.orb != nil }
    /// The dwell countdown sweeps around the glow only while dwell can
    /// actually click; otherwise the glow is a plain look-highlight.
    var showsDwellProgress = false {
        didSet {
            guard showsDwellProgress != oldValue else { return }
            updateMagnet(nil) { $0.showsProgress = showsDwellProgress }
        }
    }
    /// The scorer's gaze error band in points. `GazeService` writes it on
    /// its first tick, before any scorer event reaches the overlay.
    var gazeSigmaPt: Double = GazeErrorBand.minimumSigmaPt
    /// Unit tests never order an overlay window onto the screen of the Mac
    /// running them: every surface here keeps its state and draws nothing.
    static let drawsOnScreen = NSClassFromString("XCTestCase") == nil

    // MARK: Halo

    /// Frosted halo on an element frame (top-left points). Repeated calls
    /// just move the one panel — cheap enough for 10Hz retargeting, and
    /// visible panels are never reordered.
    func showHalo(frame: CGRect) {
        // One highlight at a time: the gaze glow gathers back into the
        // orb and stays there while the halo is up.
        releaseLock()
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
        if Self.drawsOnScreen, haloPanel?.isVisible == false { haloPanel?.orderFrontRegardless() }
    }

    func hideHalo() {
        haloPanel?.orderOut(nil)
        haloRect = nil
    }

    /// A guide step's words beside its glow. It answers to the same
    /// Reduce Motion as the glow and goes when everything is dismissed.
    lazy var guideCallout: GuideCalloutPanel = {
        let callout = GuideCalloutPanel()
        callout.reduceMotion = { [weak self] in self?.reduceMotion() ?? true }
        return callout
    }()

    // MARK: Press glow

    static let pressGlowSeconds: Double = 1.2

    /// The gaze glow on a control Jarvis is pressing because the person
    /// named it ("click Send"): same shape and light, held long enough to
    /// see what was pressed, then faded. A gaze acquire in the meantime
    /// takes the ring over, and Reduce Motion is honoured the same way.
    func glowPress(frame: CGRect) {
        lock(key: "press:\(frame)", target: Self.ringTarget(frame: frame), progress: 0)
        magnetGeneration += 1
        let generation = magnetGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pressGlowSeconds * 1e9))
            guard let self, self.magnetGeneration == generation else { return }
            self.releaseLock()
        }
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

    /// Same stand-down as the halo — the glow dims rather than fighting
    /// an agent cursor acting on the same element.
    private func applyRingAlpha() {
        updateMagnet(nil) { $0.dimmed = self.dimmed($0.lock?.rect) }
    }

    private func dimmed(_ rect: CGRect?) -> Bool {
        rect.map { r in agentDemoteFrames.contains { $0.intersects(r) } } ?? false
    }

    /// The gaze feed went stale (or recovered) while chips are armed —
    /// dim the set so a dead tracker can't pass for a live dwell pick.
    /// Voice picks still resolve; only the "tracker is healthy" read dims.
    func gazeLost(_ lost: Bool) {
        if lost { hideOrb() }
        guard lost != gazeDimmed else { return }
        gazeDimmed = lost
        applyChipAlpha()
    }

    private func applyChipAlpha() {
        for panel in chipPanels {
            panel.alphaValue = gazeDimmed ? Self.chipsDimmedAlpha : 1
        }
    }

    // MARK: Chips (numbers + radial share one pool)

    /// Dark compact pill — a 1-based number with an optional caption, or
    /// a name alone when `index` is 0.
    private struct TargetChip: View {
        let index: Int
        var caption: String? = nil
        var body: some View {
            HStack(spacing: 5) {
                if index > 0 {
                    Text("\(index)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, caption?.isEmpty == false ? 9 : 0)
            .frame(minWidth: 24, minHeight: 24)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
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
    /// `dismissOnPick` false keeps a persistent set armed after a pick.
    private func armChips(_ specs: [(center: CGPoint, index: Int, caption: String?)],
                          dismissOnPick: Bool,
                          onPick: @escaping @MainActor (Int) -> Void) {
        clearChips()
        self.onPick = onPick
        self.dismissOnPick = dismissOnPick
        var rects: [(index: Int, rect: CGRect)] = []
        for (i, spec) in specs.enumerated() {
            let (panel, hosting) = chipPanel(at: i)
            hosting.rootView = TargetChip(index: spec.index, caption: spec.caption)
            let fit = hosting.fittingSize
            let size = CGSize(width: max(fit.width, Self.minChipSide),
                              height: max(fit.height, Self.minChipSide))
            let rect = CGRect(x: spec.center.x - size.width / 2,
                              y: spec.center.y - size.height / 2,
                              width: size.width, height: size.height)
            panel.setFrame(Self.appKitFrame(for: rect), display: true)
            if Self.drawsOnScreen { panel.orderFrontRegardless() }
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
        onPick = nil
        dismissOnPick = true
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
        armChips(specs, dismissOnPick: true, onPick: onPick)
    }

    /// Numbered chips (1…n) on each target's top-left corner — scoped
    /// calls pass only the gazed window's candidates, everywhere passes
    /// all. onPick gets the 0-based target index; past `maxNumberChips`
    /// the extras are refused, not drawn. `persistent` keeps the set
    /// armed after a pick (the "persistent number chips" setting) until
    /// an explicit dismiss — hideAll, a re-arm, or a radial taking over.
    func showNumbers(targets: [(frame: CGRect, label: String)],
                     persistent: Bool = false,
                     onPick: @escaping @MainActor (Int) -> Void) {
        let specs: [(center: CGPoint, index: Int, caption: String?)] =
            targets.prefix(Self.maxNumberChips).enumerated().map { (i, t) in
                (center: CGPoint(x: t.frame.minX + Self.numberNudge.x,
                                 y: t.frame.minY + Self.numberNudge.y),
                 index: i + 1, caption: nil)
            }
        armChips(specs, dismissOnPick: !persistent, onPick: onPick)
    }

    /// Name chips on each target's top-left corner — read-only labels the
    /// user answers with "click <name>", so nothing dwell-picks them.
    /// Returns how many went up.
    @discardableResult
    func showNames(targets: [(frame: CGRect, label: String)]) -> Int {
        clearChips()
        for (i, target) in targets.prefix(Self.maxNumberChips).enumerated() {
            let (panel, hosting) = chipPanel(at: i)
            hosting.rootView = TargetChip(index: 0, caption: target.label)
            let fit = hosting.fittingSize
            let size = CGSize(width: max(fit.width, Self.minChipSide),
                              height: max(fit.height, Self.minChipSide))
            let rect = CGRect(x: target.frame.minX + Self.numberNudge.x,
                              y: target.frame.minY + Self.numberNudge.y - size.height / 2,
                              width: size.width, height: size.height)
            panel.alphaValue = 1
            panel.setFrame(Self.appKitFrame(for: rect), display: true)
            if Self.drawsOnScreen { panel.orderFrontRegardless() }
        }
        return min(targets.count, Self.maxNumberChips)
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
        retireMagnet()
        hideHalo()
        guideCallout.hide()
        cheatPanel?.orderOut(nil)
        cheatPanel = nil
    }

    /// Live gaze feed (top-left points): moves the gaze orb and dwells
    /// the chip set toward a pick — 500ms inside one chip fires its
    /// index. A pick retires the set unless it armed as persistent, in
    /// which case the chips stay up for the next pick.
    func ingestGaze(_ point: CGPoint) {
        moveOrb(to: point)
        guard let hit = dwell.advance(point: point, now: now()) else { return }
        let pick = onPick
        if dismissOnPick { clearChips() }
        pick?(hit)
    }

    // MARK: Gaze highlight (Magnet)

    /// Gaze-intent event feed — the scorer's acquire/hold/release
    /// transitions lock the Magnet onto the element's own frame (the
    /// visionOS "feedback lives on the element" pattern) or gather it
    /// back into the orb. A tie releases the glow, and `ambiguous` bubbles
    /// up through `onAmbiguous`; the coordinator owns the radial itself.
    var onAmbiguous: (([IntentCandidate]) -> Void)?

    func intentEvent(_ event: IntentEvent) {
        switch event {
        case .none, .release:
            releaseLock()
        case .acquire(let c):
            lockOnGaze(c, progress: 0)
        case .hold(let c, let progress):
            lockOnGaze(c, progress: progress)
        case .ambiguous(let candidates):
            releaseLock()
            onAmbiguous?(candidates)
        }
    }

    /// Whether the glow may lock onto a candidate the gaze scorer chose:
    /// a leaf the person can act on, no bigger than a control, and big
    /// enough that the current error band can single it out.
    nonisolated static func canLock(_ c: IntentCandidate, sigmaPt: Double) -> Bool {
        guard c.kind != .window, !IntentCandidate.isContainer(role: c.role) else { return false }
        let r = (c.kind == .trafficLight ? c.motorRect : c.frame).standardized
        guard r.width <= lockMaxSize.width, r.height <= lockMaxSize.height else { return false }
        return sigmaPt <= lockSigmaFactor * Double(max(r.width, r.height))
    }

    private func lockOnGaze(_ c: IntentCandidate, progress: Double) {
        guard !haloArmed, Self.canLock(c, sigmaPt: gazeSigmaPt) else {
            releaseLock()
            return
        }
        lock(key: c.id, target: Self.ringTarget(for: c), progress: progress)
    }

    /// Stretch the Magnet onto a control. A new control grows its glow
    /// out of the orb; the same control streams its dwell progress, and
    /// glides if a refreshed feed moved it.
    private func lock(key: String, target: (rect: CGRect, corner: CGFloat), progress: Double) {
        let current = magnet.state.lock
        let changed = current?.key != key || current?.rect != target.rect
        if current?.key != key { magnetGeneration += 1 }
        updateMagnet(changed ? morphAnimation : nil) { state in
            state.lock = GazeMagnetState.Lock(key: key, rect: target.rect, corner: target.corner)
            state.progress = progress
            state.dimmed = self.dimmed(target.rect)
        }
    }

    /// Gather the glow back into the orb. One-shot: repeated `.none`
    /// ticks find nothing to release.
    private func releaseLock() {
        guard magnet.state.lock != nil else { return }
        magnetGeneration += 1
        updateMagnet(morphAnimation) { state in
            state.lock = nil
            state.progress = 0
            state.dimmed = false
        }
    }

    private var morphAnimation: Animation {
        reduceMotion() ? Self.magnetCrossfade : Self.magnetMorph
    }

    /// The orb follows every fresh gaze point and fades once samples stop
    /// for the freshness window, so it never sits on a dead feed.
    private func moveOrb(to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        lastGazeAt = now()
        updateMagnet(reduceMotion() ? nil : Self.orbFollow) { $0.orb = point }
        guard orbWatchdog == nil else { return }
        orbWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if self.now() - self.lastGazeAt > GazeSample.freshnessWindow {
                    self.orbWatchdog = nil
                    self.hideOrb()
                    return
                }
            }
        }
    }

    private func hideOrb() {
        guard magnet.state.orb != nil else { return }
        updateMagnet(morphAnimation) { $0.orb = nil }
    }

    /// Every Magnet change goes through here: the new state lands inside
    /// one animation transaction (nil places it outright), on the panel of
    /// the display it sits on.
    private func updateMagnet(_ animation: Animation?, _ change: (inout GazeMagnetState) -> Void) {
        var next = magnet.state
        change(&next)
        next.reduceMotion = reduceMotion()
        let anchor = next.lock.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) } ?? next.orb
        if let anchor, !next.canvas.contains(anchor),
           let screen = ScreenGeometry.display(containing: anchor) {
            next.canvas = ScreenGeometry.topLeftFrame(of: screen)
        }
        guard next != magnet.state else { return }
        withAnimation(animation) { magnet.state = next }
        presentMagnet()
    }

    /// One full-display panel carries the Magnet, so the orb can travel
    /// without the window moving under it. It leaves the screen once both
    /// the orb and the glow are gone and their exit has played.
    private func presentMagnet() {
        let state = magnet.state
        guard state.orb != nil || state.lock != nil else {
            let generation = magnetGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.magnetGeneration == generation,
                      self.magnet.state.orb == nil, self.magnet.state.lock == nil else { return }
                self.magnetPanel?.orderOut(nil)
            }
            return
        }
        guard Self.drawsOnScreen, !state.canvas.isEmpty else { return }
        if magnetPanel == nil {
            let panel = Self.makePanel()
            let host = NSHostingView(rootView: GazeMagnetHost(model: magnet))
            host.sizingOptions = []
            panel.contentView = host
            magnetPanel = panel
        }
        let frame = Self.appKitFrame(for: state.canvas)
        if magnetPanel?.frame != frame { magnetPanel?.setFrame(frame, display: false) }
        if magnetPanel?.isVisible == false { magnetPanel?.orderFrontRegardless() }
    }

    private func retireMagnet() {
        magnetGeneration += 1
        orbWatchdog?.cancel()
        orbWatchdog = nil
        var cleared = magnet.state
        cleared.orb = nil
        cleared.lock = nil
        cleared.progress = 0
        cleared.dimmed = false
        withAnimation(nil) { magnet.state = cleared }
        magnetPanel?.orderOut(nil)
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

        func fire(duration: CFTimeInterval, travel: Bool = true) {
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
            for anim in travel ? [grow, fade] : [fade] {
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
        let size = Self.flashCanvas
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2,
                          width: size, height: size)
        let panel = Self.makePanel()
        let ring = FlashRing(frame: NSRect(origin: .zero, size: rect.size))
        panel.contentView = ring
        panel.setFrame(Self.appKitFrame(for: rect), display: true)
        if Self.drawsOnScreen { panel.orderFrontRegardless() }
        ring.fire(duration: Self.flashSeconds, travel: !reduceMotion())
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
            VStack(alignment: .leading, spacing: 7) {
                Text("Things you can say").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                ForEach(lines.indices, id: \.self) {
                    Text(lines[$0]).font(.system(size: 15))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color(white: 0.1).opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
            .colorScheme(.dark)
            .accessibilityElement(children: .combine)
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
        showSheet(lines: lines)
    }

    /// The same panel, replacing what it shows instead of toggling: L7's
    /// "Type this?" and reply drafts.
    func showSheet(lines: [String]) {
        hideSheet()
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
        if Self.drawsOnScreen { panel.orderFrontRegardless() }
        cheatPanel = panel
    }

    func hideSheet() {
        cheatPanel?.orderOut(nil)
        cheatPanel = nil
    }
}
