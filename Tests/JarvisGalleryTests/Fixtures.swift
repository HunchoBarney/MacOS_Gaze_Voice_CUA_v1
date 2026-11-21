import AppKit
import CoreImage
import SwiftUI
@testable import Jarvis

/// The fixture Mac: the primary display's real geometry (so overlay
/// placement code runs unchanged), a generated wallpaper, a menu bar with
/// the notch, and one fixture Mail window. No real screen content.
@MainActor
struct Desktop {
    let size: CGSize
    let menuBarHeight: CGFloat
    let notch: CGRect?
    /// The rendering display has no notch, so the fixture draws a
    /// MacBook-style one; the product's own geometry is unchanged.
    var drawnNotch = false

    static func primary() -> Desktop {
        guard let screen = NSScreen.screens.first else {
            return Desktop(size: CGSize(width: 1512, height: 982), menuBarHeight: 37,
                           notch: CGRect(x: 663, y: 0, width: 185, height: 37), drawnNotch: true)
        }
        let frame = screen.frame
        let menuBar = max(24, frame.maxY - screen.visibleFrame.maxY)
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = CGRect(x: left.maxX - frame.minX, y: 0, width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            return Desktop(size: frame.size, menuBarHeight: menuBar, notch: notch, drawnNotch: false)
        }
        let notch = CGRect(x: ((frame.width - 185) / 2).rounded(), y: 0, width: 185, height: menuBar)
        return Desktop(size: frame.size, menuBarHeight: menuBar, notch: notch, drawnNotch: true)
    }

    /// The primary display's visible frame in AppKit coordinates, the
    /// input AppWindows.frame(contentSize:visibleFrame:) expects.
    var visibleFrame: NSRect {
        NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: size.width, height: size.height - menuBarHeight)
    }
}

/// The fixture app window behind the overlays: a Mail compose window
/// built from real AppKit controls, so targets have honest frames.
@MainActor
final class MailFixture {
    static let size = CGSize(width: 820, height: 560)
    let origin: CGPoint
    let root = MailFixtureView(frame: NSRect(origin: .zero, size: MailFixture.size))

    init(desktop: Desktop) {
        origin = CGPoint(x: ((desktop.size.width - Self.size.width) / 2).rounded(),
                         y: max(desktop.menuBarHeight + 60, ((desktop.size.height - Self.size.height) / 2).rounded() - 20))
    }

    var frame: CGRect { CGRect(origin: origin, size: Self.size) }

    /// A control's frame in global top-left points.
    func target(_ name: String) -> CGRect {
        guard let view = root.controls[name] else { return .zero }
        let local = view.convert(view.bounds, to: root)
        return local.offsetBy(dx: origin.x, dy: origin.y)
    }

    func image(scheme: Scheme, scale: CGFloat) -> CGImage? {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.appearance = scheme.appearance
        root.appearance = scheme.appearance
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.display()
        let image = WindowRenderer.cached(root, scale: scale)
        window.contentView = nil
        return image
    }
}

final class MailFixtureView: NSView {
    private(set) var controls: [String: NSView] = [:]
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let toolbar: [(String, String, CGFloat)] = [("send", "paperplane", 0), ("attach", "paperclip", 1),
                                                     ("format", "textformat", 2), ("photo", "photo", 3)]
        for (name, symbol, index) in toolbar {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name)!,
                                  target: nil, action: nil)
            button.bezelStyle = .texturedRounded
            button.isBordered = true
            button.frame = NSRect(x: 150 + index * 48, y: 12, width: 40, height: 28)
            addSubview(button)
            controls[name] = button
        }
        let fields: [(String, String, CGFloat)] = [("To:", "Alex Rivera", 64), ("Cc:", "", 100),
                                                   ("Subject:", "Q3 planning deck", 136)]
        for (label, value, y) in fields {
            let title = NSTextField(labelWithString: label)
            title.textColor = .secondaryLabelColor
            title.font = .systemFont(ofSize: 13)
            title.frame = NSRect(x: 24, y: y + 6, width: 70, height: 18)
            addSubview(title)
            let field = NSTextField(labelWithString: value)
            field.font = .systemFont(ofSize: 13, weight: label == "To:" ? .medium : .regular)
            field.textColor = label == "To:" ? .controlAccentColor : .labelColor
            field.frame = NSRect(x: 96, y: y + 6, width: 600, height: 18)
            addSubview(field)
            controls[label] = field
        }
        let body = NSTextField(wrappingLabelWithString: """
        Hi Alex,

        The Q3 planning deck is ready. I moved the hiring plan to slide 4 and added the revenue bridge you asked for on slide 9.

        Two open questions before Thursday:
        • Do we show the regional split, or keep it in the appendix?
        • Should the roadmap slide stop at Q4 or run into next year?

        Thanks,
        Sam
        """)
        body.font = .systemFont(ofSize: 14)
        body.textColor = .labelColor
        body.frame = NSRect(x: 24, y: 192, width: 760, height: 260)
        addSubview(body)
        controls["body"] = body
        let accessory = NSButton(title: "Send Later…", target: nil, action: nil)
        accessory.bezelStyle = .push
        accessory.frame = NSRect(x: 24, y: 500, width: 120, height: 32)
        addSubview(accessory)
        controls["later"] = accessory
        let send = NSButton(title: "Send", target: nil, action: nil)
        send.bezelStyle = .push
        send.keyEquivalent = "\r"
        send.frame = NSRect(x: 696, y: 500, width: 100, height: 32)
        addSubview(send)
        controls["sendBottom"] = send
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 52, width: bounds.width, height: 1).fill()
        for y: CGFloat in [96, 132, 168] { NSRect(x: 24, y: y, width: bounds.width - 48, height: 1).fill() }
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 20 + CGFloat(index) * 20, y: 20, width: 12, height: 12)).fill()
        }
        let title = NSAttributedString(string: "Q3 planning deck", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        title.draw(at: NSPoint(x: bounds.width - 24 - title.size().width, y: 18))
    }
}

/// Composites the fixture desktop and every panel the virtual screen
/// holds, at the primary display's size and 2x.
@MainActor
final class Compositor {
    let desktop = Desktop.primary()
    let mail: MailFixture
    let scale: CGFloat = 2
    private var backgrounds: [String: CGImage] = [:]
    private let ci = CIContext()
    /// Jarvis's own status item in the fixture menu bar (main.swift:556-574).
    var statusItem: (symbol: String, badge: Int) = ("waveform", 0)

    init() { mail = MailFixture(desktop: desktop) }

    /// Where the Jarvis status item sits, top-left points (set when drawn).
    private(set) var statusItemFrame = CGRect(x: 1100, y: 0, width: 30, height: 37)

    var pixelSize: (Int, Int) { (Int(desktop.size.width * scale), Int(desktop.size.height * scale)) }

    /// Top-left rect → Core Graphics (y up) rect in points.
    private func up(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: desktop.size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    func background(_ scheme: Scheme, withMail: Bool) -> CGImage {
        let key = "\(scheme.rawValue)-\(withMail)-\(statusItem.symbol)-\(statusItem.badge)"
        if let cached = backgrounds[key] { return cached }
        let (w, h) = pixelSize
        let ctx = WindowRenderer.context(w, h)!
        ctx.scaleBy(x: scale, y: scale)
        drawWallpaper(ctx, scheme)
        if withMail, let window = mail.image(scheme: scheme, scale: scale) {
            let rect = up(mail.frame)
            let shape = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50,
                          color: NSColor.black.withAlphaComponent(scheme == .dark ? 0.55 : 0.28).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.draw(window, in: rect)
            ctx.restoreGState()
            ctx.addPath(shape)
            ctx.setStrokeColor(NSColor(white: scheme == .dark ? 1 : 0, alpha: scheme == .dark ? 0.16 : 0.12).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        drawMenuBar(ctx, scheme)
        let image = ctx.makeImage()!
        backgrounds[key] = image
        return image
    }

    private func drawWallpaper(_ ctx: CGContext, _ scheme: Scheme) {
        let size = desktop.size
        let base: [NSColor] = scheme == .dark
            ? [NSColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1), NSColor(red: 0.10, green: 0.06, blue: 0.20, alpha: 1)]
            : [NSColor(red: 0.80, green: 0.88, blue: 0.98, alpha: 1), NSColor(red: 0.98, green: 0.88, blue: 0.84, alpha: 1)]
        let gradient = CGGradient(colorsSpace: WindowRenderer.space, colors: base.map(\.cgColor) as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = scheme == .dark
            ? [(0.18, 0.25, 0.55, NSColor(red: 0.10, green: 0.45, blue: 0.75, alpha: 0.55)),
               (0.85, 0.80, 0.50, NSColor(red: 0.45, green: 0.20, blue: 0.70, alpha: 0.45)),
               (0.55, 0.05, 0.45, NSColor(red: 0.05, green: 0.55, blue: 0.55, alpha: 0.30))]
            : [(0.15, 0.20, 0.55, NSColor(red: 0.55, green: 0.75, blue: 1.00, alpha: 0.70)),
               (0.88, 0.78, 0.50, NSColor(red: 1.00, green: 0.72, blue: 0.62, alpha: 0.65)),
               (0.55, 0.05, 0.45, NSColor(red: 0.70, green: 0.88, blue: 0.85, alpha: 0.55))]
        for (x, y, r, color) in blobs {
            let center = CGPoint(x: size.width * x, y: size.height * y)
            let radial = CGGradient(colorsSpace: WindowRenderer.space,
                                    colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(radial, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: max(size.width, size.height) * r, options: [])
        }
    }

    private func drawMenuBar(_ ctx: CGContext, _ scheme: Scheme) {
        let size = desktop.size, height = desktop.menuBarHeight
        ctx.setFillColor(NSColor(white: scheme == .dark ? 0 : 1, alpha: scheme == .dark ? 0.22 : 0.30).cgColor)
        ctx.fill(CGRect(x: 0, y: size.height - height, width: size.width, height: height))
        if let notch = desktop.notch {
            let rect = up(notch)
            let path = CGMutablePath()
            path.addRoundedRect(in: rect.insetBy(dx: 0, dy: -12), cornerWidth: 12, cornerHeight: 12)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        let ink = scheme == .dark ? NSColor.white : NSColor.black
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let baseline = size.height - height / 2 - 8
        var x: CGFloat = 20
        if let apple = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
            tinted(apple, ink).draw(in: NSRect(x: x, y: baseline + 1, width: 14, height: 17))
            x += 34
        }
        for (index, title) in ["Mail", "File", "Edit", "View", "Mailbox", "Message", "Format", "Window", "Help"].enumerated() {
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: index == 0 ? .bold : .regular), .foregroundColor: ink])
            text.draw(at: NSPoint(x: x, y: baseline))
            x += text.size().width + 20
        }
        var right = size.width - 18
        let clock = NSAttributedString(string: "Sat Nov 21  9:41 AM", attributes: [
            .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: ink])
        right -= clock.size().width
        clock.draw(at: NSPoint(x: right, y: baseline))
        for symbol in ["switch.2", "wifi", "battery.75percent"] {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { continue }
            let w = image.size.width * 1.05
            right -= w + 18
            tinted(image, ink).draw(in: NSRect(x: right, y: baseline + 1, width: w, height: image.size.height * 1.05))
        }
        if statusItem.badge > 0 {
            let badge = NSAttributedString(string: " ·\(statusItem.badge)", attributes: [
                .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: ink])
            right -= badge.size().width + 14
            badge.draw(at: NSPoint(x: right, y: baseline))
        }
        if let image = NSImage(systemSymbolName: statusItem.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let w = image.size.width * 1.05
            right -= w + (statusItem.badge > 0 ? 2 : 18)
            statusItemFrame = CGRect(x: right - 8, y: 0, width: w + 16, height: height)
            tinted(image, ink).draw(in: NSRect(x: right, y: baseline + 1, width: w, height: image.size.height * 1.05))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    /// The desktop plus every panel on the virtual screen, optionally
    /// cropped to a top-left rect (points).
    func compose(_ scheme: Scheme, withMail: Bool = true, clock: AnimationClock? = nil, time: Double? = nil,
                 crop: CGRect? = nil) -> CGImage {
        let (w, h) = pixelSize
        let ctx = WindowRenderer.context(w, h)!
        ctx.draw(background(scheme, withMail: withMail), in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        for window in VirtualScreen.stack {
            let frame = VirtualScreen.topLeft(window.frame)
            guard frame.width >= 1, frame.height >= 1 else { continue }
            let alpha = window.alphaValue
            if let effect = window.contentView as? NSVisualEffectView {
                drawMaterial(effect, frame: frame, alpha: alpha, in: ctx)
                continue
            }
            guard let image = WindowRenderer.image(of: window, scale: scale, clock: clock, time: time) else { continue }
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.draw(image, in: up(frame))
            ctx.restoreGState()
        }
        let full = ctx.makeImage()!
        guard let crop else { return full }
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return full.cropping(to: pixels) ?? full
    }

    /// NSVisualEffectView blurs what is behind the window, which only the
    /// window server can do; the harness approximates it from the fixture
    /// desktop: a 20 pt blur, the dark HUD tint, then the view's own
    /// corner radius and border.
    private func drawMaterial(_ view: NSVisualEffectView, frame: CGRect, alpha: CGFloat, in ctx: CGContext) {
        guard let snapshot = ctx.makeImage() else { return }
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        let source = CIImage(cgImage: snapshot)
        let flippedY = CGFloat(snapshot.height) - pixels.maxY
        let region = CGRect(x: pixels.minX, y: flippedY, width: pixels.width, height: pixels.height)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: 20 * scale / 2).cropped(to: region)
        guard let blur = ci.createCGImage(blurred, from: region) else { return }
        let radius = view.layer?.cornerRadius ?? 0
        let rect = up(frame)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(blur, in: rect)
        ctx.setFillColor(NSColor(white: 0.12, alpha: 0.55).cgColor)
        ctx.fill(rect)
        ctx.resetClip()
        if let layer = view.layer, layer.borderWidth > 0, let color = layer.borderColor {
            let inset = layer.borderWidth / 2
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: max(0, radius - inset),
                               cornerHeight: max(0, radius - inset), transform: nil))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.borderWidth)
            ctx.strokePath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// Fixture Jarvis state: an isolated Config (private defaults suite,
/// in-memory keys, no environment), a controller whose microphone,
/// speech, speaker and permission reads are all fakes.
@MainActor
enum Fixtures {
    struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    final class SilentSpeaker: SpeechSynthesizing, @unchecked Sendable {
        func speak(_ text: String) {}
        func stop() {}
    }

    final class StubCapture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var onReadiness: ((SpeechReadiness) -> Void)?
        func prepare(inputUID: String?) async throws -> String { "Fixture microphone" }
        func suspend() async {}
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String { "Fixture microphone" }
        func finish() {}
        func cancel() {}
    }

    static func config() -> Config {
        let defaults = UserDefaults(suiteName: "jarvis-gallery-\(UUID().uuidString)")!
        let config = Config(defaults: defaults, keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                            environment: [:],
                            codexAuth: CodexAuth(binary: nil,
                                                 codexHome: FileManager.default.temporaryDirectory
                                                    .appendingPathComponent("jarvis-gallery-codex")))
        config.handsFreeEnabled = false
        // A fixture device id, so no real microphone name can reach a render.
        config.microphoneUID = "gallery.fixture.microphone"
        return config
    }

    static func controller(_ config: Config, missing: [Permission] = []) -> VoiceController {
        let coordinator = VoiceTaskCoordinator(config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })))
        let controller = VoiceController(config: config, speech: StubCapture(), authorize: { false },
                                         frontmost: { "Mail" }, focusedWindow: { nil }, cuaRuntime: coordinator,
                                         speaker: SilentSpeaker(), permissionStatusReader: { missing },
                                         otherAppUsesMicrophone: { false })
        controller.missingPermissions = missing
        return controller
    }
}
