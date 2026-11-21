import AppKit
import CoreImage
import ObjectiveC
import QuartzCore
@testable import Jarvis

/// A window server in the test process. Jarvis's overlays order their
/// panels front through AppKit; the harness swaps those calls for a
/// registry, so nothing ever reaches the real screen, and composites the
/// registered panels onto a fixture desktop at their real frames.
@MainActor
enum VirtualScreen {
    private static var shown: [(window: NSWindow, order: Int)] = []
    private static var counter = 0
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.gallery_orderFrontRegardless)),
            (#selector(NSWindow.orderFront(_:)), #selector(NSWindow.gallery_orderFront(_:))),
            (#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.gallery_makeKeyAndOrderFront(_:))),
            (#selector(NSWindow.orderOut(_:)), #selector(NSWindow.gallery_orderOut(_:))),
        ]
        for (original, replacement) in pairs {
            guard let a = class_getInstanceMethod(NSWindow.self, original),
                  let b = class_getInstanceMethod(NSWindow.self, replacement) else { continue }
            method_exchangeImplementations(a, b)
        }
    }

    static func show(_ window: NSWindow) {
        shown.removeAll { $0.window === window }
        counter += 1
        shown.append((window, counter))
    }

    static func hide(_ window: NSWindow) { shown.removeAll { $0.window === window } }
    static func clear() { shown.removeAll() }

    /// Back to front: window level first, then the order they came forward.
    static var stack: [NSWindow] {
        shown.sorted { ($0.window.level.rawValue, $0.order) < ($1.window.level.rawValue, $1.order) }.map(\.window)
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 982 }

    /// AppKit window frame → global top-left points.
    static func topLeft(_ frame: NSRect) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

extension NSWindow {
    @objc func gallery_orderFrontRegardless() { VirtualScreen.show(self) }
    @objc func gallery_orderFront(_ sender: Any?) { VirtualScreen.show(self) }
    @objc func gallery_makeKeyAndOrderFront(_ sender: Any?) { VirtualScreen.show(self) }
    @objc func gallery_orderOut(_ sender: Any?) { VirtualScreen.hide(self) }
}

/// Core Animation offscreen: layers that never reach a render server keep
/// their animations, so the harness evaluates them itself at a chosen
/// time (from, to, timing curve, key times) and renders the model tree.
/// Begin times are stamped on a virtual clock when an action adds them.
@MainActor
final class AnimationClock {
    private struct Stamp { var signature: String; var begin: Double }
    private var stamps: [String: Stamp] = [:]

    private static func key(_ layer: CALayer, _ name: String) -> String {
        "\(ObjectIdentifier(layer).hashValue)|\(name)"
    }

    private static func signature(_ animation: CAAnimation) -> String {
        var parts = ["\(animation.duration)"]
        if let basic = animation as? CABasicAnimation {
            parts.append(basic.fromValue.map { "\(ObjectIdentifier($0 as AnyObject).hashValue)" } ?? "-")
            parts.append(basic.toValue.map { "\(ObjectIdentifier($0 as AnyObject).hashValue)" } ?? "-")
        }
        if let keyframe = animation as? CAKeyframeAnimation {
            parts.append(keyframe.values.map { "\(ObjectIdentifier($0 as AnyObject).hashValue)" } ?? "-")
        }
        return parts.joined(separator: "/")
    }

    private static func walk(_ layer: CALayer, _ body: (CALayer) -> Void) {
        body(layer)
        layer.sublayers?.forEach { walk($0, body) }
    }

    /// Animations that appeared or were replaced since the last stamp
    /// begin at virtual time \(time).
    func stamp(_ roots: [CALayer], at time: Double) {
        for root in roots {
            Self.walk(root) { layer in
                for name in layer.animationKeys() ?? [] {
                    guard let animation = layer.animation(forKey: name) else { continue }
                    let key = Self.key(layer, name), signature = Self.signature(animation)
                    if stamps[key]?.signature != signature { stamps[key] = Stamp(signature: signature, begin: time) }
                }
            }
        }
    }

    /// Puts every animated property at its value for virtual time
    /// \(time); call the returned closure to restore the model.
    func apply(_ roots: [CALayer], at time: Double) -> () -> Void {
        var restores: [() -> Void] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for root in roots {
            Self.walk(root) { layer in
                for name in layer.animationKeys() ?? [] {
                    guard let animation = layer.animation(forKey: name),
                          let begin = stamps[Self.key(layer, name)]?.begin else { continue }
                    let local = time - begin
                    if let restore = Self.evaluate(animation, on: layer, local: local) { restores.append(restore) }
                }
            }
        }
        CATransaction.commit()
        return {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            restores.reversed().forEach { $0() }
            CATransaction.commit()
        }
    }

    private static func evaluate(_ animation: CAAnimation, on layer: CALayer, local: Double) -> (() -> Void)? {
        let duration = animation.duration > 0 ? animation.duration : 0.25
        let linear = min(1, max(0, local / duration))
        if let keyframe = animation as? CAKeyframeAnimation, let keyPath = keyframe.keyPath,
           let values = keyframe.values, values.count > 1 {
            let times = keyframe.keyTimes?.map(\.doubleValue)
                ?? values.indices.map { Double($0) / Double(values.count - 1) }
            guard local >= 0, local <= duration else { return nil }
            var index = 0
            while index < times.count - 2, linear > times[index + 1] { index += 1 }
            let span = max(times[index + 1] - times[index], 1e-6)
            let t = min(1, max(0, (linear - times[index]) / span))
            return set(keyPath, from: values[index], to: values[index + 1], t: t, on: layer)
        }
        guard let basic = animation as? CABasicAnimation, let keyPath = basic.keyPath else { return nil }
        let t = ease(basic.timingFunction, linear)
        let from = basic.fromValue ?? layer.value(forKeyPath: keyPath)
        let to = basic.toValue ?? layer.value(forKeyPath: keyPath)
        if local < 0 { return set(keyPath, from: from, to: from, t: 0, on: layer) }
        return set(keyPath, from: from, to: to, t: t, on: layer)
    }

    private static func set(_ keyPath: String, from: Any?, to: Any?, t: Double, on layer: CALayer) -> (() -> Void)? {
        switch keyPath {
        case "path":
            guard let shape = layer as? CAShapeLayer, let fromValue = from, let toValue = to,
                  CFGetTypeID(fromValue as CFTypeRef) == CGPath.typeID,
                  CFGetTypeID(toValue as CFTypeRef) == CGPath.typeID else { return nil }
            let a = fromValue as! CGPath, b = toValue as! CGPath
            let old = shape.path
            shape.path = lerpPath(a, b, t)
            return { shape.path = old }
        case "transform.scale":
            guard let a = (from as? NSNumber)?.doubleValue, let b = (to as? NSNumber)?.doubleValue else { return nil }
            let old = layer.transform
            let s = CGFloat(a + (b - a) * t)
            layer.transform = CATransform3DMakeScale(s, s, 1)
            return { layer.transform = old }
        default:
            guard let a = (from as? NSNumber)?.doubleValue, let b = (to as? NSNumber)?.doubleValue else { return nil }
            let old = layer.value(forKeyPath: keyPath)
            layer.setValue(NSNumber(value: a + (b - a) * t), forKeyPath: keyPath)
            return { layer.setValue(old, forKeyPath: keyPath) }
        }
    }

    /// The cubic-bezier a CAMediaTimingFunction describes, solved for x.
    static func ease(_ function: CAMediaTimingFunction?, _ x: Double) -> Double {
        guard let function else { return x }
        var p1 = [Float](repeating: 0, count: 2), p2 = [Float](repeating: 0, count: 2)
        function.getControlPoint(at: 1, values: &p1)
        function.getControlPoint(at: 2, values: &p2)
        let (x1, y1, x2, y2) = (Double(p1[0]), Double(p1[1]), Double(p2[0]), Double(p2[1]))
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if bezier(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return bezier(t, y1, y2)
    }

    private struct Element { var type: CGPathElementType; var points: [CGPoint] }

    private static func elements(_ path: CGPath) -> [Element] {
        var out: [Element] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            out.append(Element(type: element.type, points: (0..<count).map { element.points[$0] }))
        }
        return out
    }

    /// Point-wise blend of two paths with the same structure (every ring
    /// shape is a rounded rect), else a snap at the midpoint.
    static func lerpPath(_ a: CGPath, _ b: CGPath, _ t: Double) -> CGPath {
        let ea = elements(a), eb = elements(b)
        guard ea.count == eb.count, zip(ea, eb).allSatisfy({ $0.type == $1.type }) else { return t < 0.5 ? a : b }
        let path = CGMutablePath()
        let k = CGFloat(t)
        for (x, y) in zip(ea, eb) {
            let p = zip(x.points, y.points).map { CGPoint(x: $0.x + ($1.x - $0.x) * k, y: $0.y + ($1.y - $0.y) * k) }
            switch x.type {
            case .moveToPoint: path.move(to: p[0])
            case .addLineToPoint: path.addLine(to: p[0])
            case .addQuadCurveToPoint: path.addQuadCurve(to: p[1], control: p[0])
            case .addCurveToPoint: path.addCurve(to: p[2], control1: p[0], control2: p[1])
            case .closeSubpath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

/// Pixels of one window's content view.
@MainActor
enum WindowRenderer {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        var index = 0
        while index < length {
            if bytes[index] != 0 || bytes[index + 1] != 0 || bytes[index + 2] != 0 || bytes[index + 3] != 0 { return false }
            index += 4 * 7
        }
        return true
    }

    /// AppKit drawing (controls, SwiftUI hosting) through cacheDisplay.
    static func cached(_ view: NSView, scale: CGFloat) -> CGImage? {
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static var flipLayerRender: Bool?

    /// Whether CALayer.render(in:) of an AppKit view's layer comes out
    /// upside down in a bitmap context; checked once with a probe.
    static func layerNeedsFlip() -> Bool {
        if let known = flipLayerRender { return known }
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        probe.wantsLayer = true
        let marker = CALayer()
        marker.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        marker.backgroundColor = NSColor.red.cgColor
        probe.layer?.addSublayer(marker)
        var flip = false
        if let ctx = context(20, 20), let layer = probe.layer {
            layer.render(in: ctx)
            if let data = ctx.data {
                let row = data.assumingMemoryBound(to: UInt8.self)
                // Memory row 0 is the image's top; AppKit's (0,0) is bottom-left.
                flip = row[2] > 128
            }
        }
        flipLayerRender = flip
        return flip
    }

    /// Core Animation drawing (shape layers, borders, shadows) through
    /// render(in:), with animations evaluated at \(time) when given.
    static func layered(_ view: NSView, scale: CGFloat, clock: AnimationClock?, time: Double?) -> CGImage? {
        guard let layer = view.layer else { return cached(view, scale: scale) }
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
              let ctx = context(Int(size.width * scale), Int(size.height * scale)) else { return nil }
        view.display()
        let restore = (clock != nil && time != nil) ? clock!.apply([layer], at: time!) : nil
        if layerNeedsFlip() {
            ctx.translateBy(x: 0, y: size.height * scale)
            ctx.scaleBy(x: scale, y: -scale)
        } else {
            ctx.scaleBy(x: scale, y: scale)
        }
        layer.render(in: ctx)
        restore?()
        return ctx.makeImage()
    }

    /// How a panel's content is drawn: SwiftUI and plain AppKit views
    /// through AppKit, custom layer trees through Core Animation.
    static func image(of window: NSWindow, scale: CGFloat, clock: AnimationClock? = nil, time: Double? = nil) -> CGImage? {
        guard let view = window.contentView else { return nil }
        if view.frame.size != window.frame.size { view.setFrameSize(window.frame.size) }
        view.layoutSubtreeIfNeeded()
        let typeName = String(describing: type(of: view))
        if typeName.contains("Hosting") {
            if let image = cached(view, scale: scale), !isBlank(image) { return image }
            return layered(view, scale: scale, clock: clock, time: time)
        }
        return layered(view, scale: scale, clock: clock, time: time)
    }
}
