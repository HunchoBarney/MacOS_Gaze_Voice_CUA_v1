import AppKit
import SwiftUI
import XCTest
@testable import Jarvis

/// Offscreen estimate of the gaze highlight's render cost and the stills
/// for the PR (JARA-55): the old conforming ring (a verbatim copy of the
/// view main drew it with) against the Magnet, both driven by the same
/// scorer over a toolbar while a scripted gaze walks it. Each runs 30 s at
/// 60 Hz; every frame applies that frame's tracker update (15 Hz) and
/// rasterises the highlight on the main thread. It measures app-side work
/// only: WindowServer compositing and SwiftUI's in-flight spring
/// interpolation are not in it, so it is an estimate, not the on-screen
/// number. Opt-in: JARVIS_BENCH_MAGNET=1, results and PNGs written to
/// JARVIS_MAGNET_RENDER_DIR.
@MainActor
final class MagnetRenderBenchTests: XCTestCase {
    private static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["JARVIS_MAGNET_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let buttons: [IntentCandidate] = (0..<6).map { i in
        let frame = CGRect(x: 200 + CGFloat(i) * 88, y: 300, width: 80, height: 28)
        return IntentCandidate(id: "b\(i)", kind: .axElement, frame: frame, motorRect: frame,
                               role: "AXButton", label: ["Reply", "Forward", "Archive", "Move", "Flag", "Delete"][i])
    }
    private static let paragraph = CGRect(x: 200, y: 360, width: 520, height: 120)
    private static let stillCanvas = CGRect(x: 150, y: 250, width: 640, height: 260)
    private static let scale: CGFloat = 2

    func testRenderCostOldRingVersusMagnet() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_BENCH_MAGNET"] == "1",
                          "opt-in render bench")
        let seconds = Double(ProcessInfo.processInfo.environment["JARVIS_BENCH_SECONDS"] ?? "30") ?? 30
        let old = Self.run(seconds: seconds, renderer: LegacyRingDriver())
        let magnet = Self.run(seconds: seconds, renderer: MagnetDriver())
        let report = [old.line("old ring"), magnet.line("magnet")].joined(separator: "\n")
        print("MAGNET-BENCH\n" + report)
        if let dir = Self.outputDirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try report.write(to: dir.appendingPathComponent("bench.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(magnet.frames, 0)
    }

    func testWriteStills() throws {
        guard let dir = Self.outputDirectory else { throw XCTSkip("set JARVIS_MAGNET_RENDER_DIR") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let button = Self.buttons[2]
        let target = TargetOverlay.ringTarget(for: button)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let legacy = LegacyRingDriver()
            legacy.apply(orb: nil, lock: target)
            try Self.png(Self.compose(dark: dark, overlay: legacy.image(canvas: Self.stillCanvas)),
                         to: dir.appendingPathComponent("magnet-pr-before-ring-\(suffix).png"))
            var state = GazeMagnetState()
            state.canvas = Self.stillCanvas
            state.orb = CGPoint(x: 330, y: 392)
            try Self.png(Self.compose(dark: dark, overlay: MagnetDriver.image(state)),
                         to: dir.appendingPathComponent("magnet-pr-after-reading-\(suffix).png"))
            state.orb = CGPoint(x: button.frame.midX + 6, y: button.frame.midY - 4)
            try Self.png(Self.compose(dark: dark, overlay: MagnetDriver.image(state)),
                         to: dir.appendingPathComponent("magnet-pr-after-orb-wide-sigma-\(suffix).png"))
            state.lock = .init(key: button.id, rect: target.rect, corner: target.corner)
            try Self.png(Self.compose(dark: dark, overlay: MagnetDriver.image(state)),
                         to: dir.appendingPathComponent("magnet-pr-after-locked-\(suffix).png"))
        }
    }

    // MARK: - Harness

    struct Result {
        var frames = 0
        var cpuNs: UInt64 = 0
        var wallNs: UInt64 = 0
        var frameMs: [Double] = []

        func line(_ name: String) -> String {
            let sorted = frameMs.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
            let mean = frameMs.reduce(0, +) / Double(max(1, frameMs.count))
            return String(format: "%@: %d frames in %.1f s, CPU %.1f%% of one core, frame time mean %.3f ms, p95 %.3f ms, max %.3f ms",
                          name, frames, Double(wallNs) / 1e9, Double(cpuNs) / Double(max(1, wallNs)) * 100,
                          mean, p95, sorted.last ?? 0)
        }
    }

    /// The scripted look: each control in turn for half a second, with
    /// fixation jitter, sampled at 15 Hz and scored by the real scorer.
    static func run(seconds: Double, renderer: MagnetBenchDriver) -> Result {
        let core = IntentScorerCore(config: .init(sigmaPx: 40))
        var result = Result()
        var rng = SystemRandomNumberGenerator()
        let frames = Int(seconds * 60)
        let frameNs: UInt64 = 16_666_667
        var lock: (rect: CGRect, corner: CGFloat)?
        let startWall = DispatchTime.now().uptimeNanoseconds
        let startCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for frame in 0..<frames {
            let t = Double(frame) / 60
            let begin = DispatchTime.now().uptimeNanoseconds
            if frame % 4 == 0 {
                let target = buttons[Int(t / 0.5) % buttons.count].frame
                let point = CGPoint(x: target.midX + Double.random(in: -12...12, using: &rng),
                                    y: target.midY + Double.random(in: -8...8, using: &rng))
                let event = core.update(candidates: buttons, at: point, isSaccade: false,
                                        now: Date(timeIntervalSinceReferenceDate: t))
                switch event {
                case .acquire(let c), .hold(let c, _):
                    lock = TargetOverlay.canLock(c, sigmaPt: 40) ? TargetOverlay.ringTarget(for: c) : nil
                case .release, .none, .ambiguous:
                    lock = nil
                }
                renderer.apply(orb: point, lock: lock)
            }
            renderer.renderFrame()
            let end = DispatchTime.now().uptimeNanoseconds
            result.frameMs.append(Double(end - begin) / 1e6)
            result.frames += 1
            let deadline = startWall + UInt64(frame + 1) * frameNs
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { usleep(useconds_t((deadline - now) / 1000)) }
        }
        result.cpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - startCPU
        result.wallNs = DispatchTime.now().uptimeNanoseconds - startWall
        return result
    }

    static func bitmap(_ size: CGSize) -> CGContext {
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        return ctx
    }

    /// The old ring: a CAShapeLayer view whose panel covered the shape
    /// plus 14 pt, rasterised per frame.
    final class LegacyRingDriver: MagnetBenchDriver {
        let view = LegacyRingView(frame: .zero)
        var canvas: CGRect = .zero
        var shown: CGRect?

        func apply(orb: CGPoint?, lock: (rect: CGRect, corner: CGFloat)?) {
            guard let lock else {
                if shown != nil { view.fade(to: 0) }
                shown = nil
                return
            }
            guard lock.rect != shown else { view.setProgress(0); return }
            let from = shown.map { ($0, lock.corner) } ?? (lock.rect.insetBy(dx: 3, dy: 3), max(0, lock.corner - 3))
            canvas = from.0.union(lock.rect).insetBy(dx: -14, dy: -14)
            view.morph(from: from, to: lock, in: canvas)
            view.fade(to: 1)
            shown = lock.rect
        }

        func renderFrame() {
            guard shown != nil else { return }
            let ctx = MagnetRenderBenchTests.bitmap(canvas.size)
            view.container.render(in: ctx)
            _ = ctx.makeImage()
        }

        func image(canvas: CGRect) -> CGImage {
            let ctx = MagnetRenderBenchTests.bitmap(canvas.size)
            ctx.translateBy(x: 0, y: canvas.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: self.canvas.minX - canvas.minX, y: self.canvas.minY - canvas.minY)
            view.container.render(in: ctx)
            return ctx.makeImage()!
        }
    }

    /// The Magnet: the production view, rasterised per frame over the
    /// region its orb and glow cover.
    final class MagnetDriver: MagnetBenchDriver {
        var state = GazeMagnetState()
        let renderer = ImageRenderer(content: GazeMagnetView(state: GazeMagnetState()))

        init() { renderer.scale = MagnetRenderBenchTests.scale }

        func apply(orb: CGPoint?, lock: (rect: CGRect, corner: CGFloat)?) {
            state.orb = orb
            state.lock = lock.map { .init(key: "\($0.rect)", rect: $0.rect, corner: $0.corner) }
            let side = GazeMagnetView.orbSide
            var region = orb.map { CGRect(x: $0.x - side / 2, y: $0.y - side / 2, width: side, height: side) } ?? .null
            if let lock { region = region.union(lock.rect) }
            state.canvas = region.isNull ? .zero : region.insetBy(dx: -14, dy: -14).integral
        }

        func renderFrame() {
            guard !state.canvas.isEmpty else { return }
            renderer.content = GazeMagnetView(state: state)
            _ = renderer.cgImage
        }

        static func image(_ state: GazeMagnetState) -> CGImage {
            let renderer = ImageRenderer(content: GazeMagnetView(state: state))
            renderer.scale = MagnetRenderBenchTests.scale
            return renderer.cgImage!
        }
    }

    // MARK: - Stills

    private struct Backdrop: View {
        var dark: Bool

        var body: some View {
            let canvas = MagnetRenderBenchTests.stillCanvas
            ZStack(alignment: .topLeading) {
                Rectangle().fill(dark ? Color(white: 0.13) : Color(white: 0.97))
                ForEach(MagnetRenderBenchTests.buttons, id: \.id) { b in
                    Text(b.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(dark ? Color.white.opacity(0.9) : Color.black.opacity(0.85))
                        .frame(width: b.frame.width, height: b.frame.height)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(dark ? Color(white: 0.24) : Color(white: 0.88)))
                        .position(x: b.frame.midX - canvas.minX, y: b.frame.midY - canvas.minY)
                }
                Text("Thanks for the notes on the launch plan. I moved the review to Thursday so the design pass can land first, and I left comments on the two open questions about pricing and the onboarding copy.")
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.8))
                    .frame(width: MagnetRenderBenchTests.paragraph.width, alignment: .leading)
                    .position(x: MagnetRenderBenchTests.paragraph.midX - canvas.minX,
                              y: MagnetRenderBenchTests.paragraph.midY - canvas.minY)
            }
            .frame(width: canvas.width, height: canvas.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    static func compose(dark: Bool, overlay: CGImage) -> CGImage {
        let renderer = ImageRenderer(content: Backdrop(dark: dark))
        renderer.scale = scale
        let back = renderer.cgImage!
        let ctx = CGContext(data: nil, width: back.width, height: back.height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let full = CGRect(x: 0, y: 0, width: back.width, height: back.height)
        ctx.draw(back, in: full)
        ctx.draw(overlay, in: full)
        return ctx.makeImage()!
    }

    static func png(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor
protocol MagnetBenchDriver: AnyObject {
    func apply(orb: CGPoint?, lock: (rect: CGRect, corner: CGFloat)?)
    func renderFrame()
}

/// The ring view main drew the gaze highlight with before JARA-55, kept
/// verbatim (minus dwell, which the bench leaves off) as the baseline.
final class LegacyRingView: NSView {
    let container = CALayer()
    let base = CAShapeLayer()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let accent = NSColor.controlAccentColor
        base.fillColor = accent.withAlphaComponent(0.14).cgColor
        base.strokeColor = accent.withAlphaComponent(0.55).cgColor
        base.lineWidth = 1.5
        base.shadowColor = accent.cgColor
        base.shadowOpacity = 0.45
        base.shadowRadius = 6
        base.shadowOffset = .zero
        container.opacity = 0
        container.addSublayer(base)
        layer?.addSublayer(container)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func morph(from: (CGRect, CGFloat), to: (rect: CGRect, corner: CGFloat), in canvas: CGRect) {
        let fromPath = TargetOverlay.ringPath(from, in: canvas)
        let toPath = TargetOverlay.ringPath(to, in: canvas)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(origin: .zero, size: canvas.size)
        base.frame = container.bounds
        base.path = toPath
        base.removeAnimation(forKey: "morph")
        let anim = CABasicAnimation(keyPath: "path")
        anim.fromValue = fromPath
        anim.toValue = toPath
        anim.duration = 0.1
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1.0)
        base.add(anim, forKey: "morph")
        base.shadowPath = toPath
        CATransaction.commit()
    }

    func setProgress(_ progress: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = 1
        CATransaction.commit()
    }

    func fade(to alpha: Float) {
        let current = container.presentation()?.opacity ?? container.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = alpha
        CATransaction.commit()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = NSNumber(value: current)
        anim.toValue = NSNumber(value: alpha)
        anim.duration = 0.12
        container.add(anim, forKey: "fade")
    }
}
