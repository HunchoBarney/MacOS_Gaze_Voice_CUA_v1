import AppKit
import Foundation

/// The one coordinate converter. Three screen spaces live in this product:
///
/// - **Top-left points** — the driver, `list_windows` bounds, AX frames,
///   `CGEvent` locations, and the eye tracker's gaze output all speak
///   global top-left-origin screen *points*.
/// - **AppKit points** — `NSScreen.frame` and `NSWindow` panel origins are
///   Cocoa bottom-left; the flip uses the *primary* screen's height.
/// - **Screenshot pixels** — driver `scope:"desktop"` x/y frames are
///   device pixels; conversion is `point * backingScaleFactor` of the
///   display containing the point.
///
/// Every halo, radial chip, number overlay, gaze hit-test and pixel
/// action crosses these — one converter, unit-tested, or every overlay
/// feature ships an off-by-flip bug on the second monitor.
enum ScreenGeometry {
    /// The Cocoa→top-left flip, pure: a bottom-left-origin frame moved
    /// into top-left space within `primaryHeight`. Split out so the math
    /// is testable without a live NSScreen — NSScreen can't be built in
    /// tests and every overlay feature rides on this flip.
    static func topLeftFrame(cocoaFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cocoaFrame.minX,
               y: primaryHeight - cocoaFrame.maxY,
               width: cocoaFrame.width,
               height: cocoaFrame.height)
    }

    /// An NSScreen's Cocoa frame expressed in global top-left points —
    /// the space `list_windows` bounds and gaze samples already use.
    static func topLeftFrame(of screen: NSScreen, primaryHeight: CGFloat? = nil) -> CGRect {
        topLeftFrame(cocoaFrame: screen.frame,
                     primaryHeight: primaryHeight ?? NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Top-left point → AppKit bottom-left point. `NSScreen.screens.first`
    /// is the primary display by definition; pass `primaryHeight`
    /// explicitly and this never touches NSScreen.
    static func topLeftToAppKit(_ point: CGPoint,
                                primaryHeight: CGFloat? = nil) -> CGPoint {
        let h = primaryHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: h - point.y)
    }

    /// AppKit bottom-left point → top-left point. Self-inverse of
    /// `topLeftToAppKit`.
    static func appKitToTopLeft(_ point: CGPoint,
                                primaryHeight: CGFloat? = nil) -> CGPoint {
        topLeftToAppKit(point, primaryHeight: primaryHeight)
    }

    /// Live screens reduced to (top-left frame, backing scale) pairs —
    /// the descriptor shape the pure overloads share with tests, so the
    /// math runs on fixtures instead of NSScreen.
    private static func descriptors(of screens: [NSScreen]) -> [(frame: CGRect, scale: CGFloat)] {
        let primaryHeight = screens.first?.frame.height ?? 0
        return screens.map {
            (frame: topLeftFrame(of: $0, primaryHeight: primaryHeight),
             scale: $0.backingScaleFactor)
        }
    }

    /// Index of the descriptor whose top-left frame contains the point.
    /// CGRect.contains is min-inclusive / max-exclusive, so a point on a
    /// shared edge belongs to exactly one display — deterministic, no
    /// seam flicker. Nil when the point is off every known display
    /// (space transition, menubar gap between monitors).
    static func display(containing topLeftPoint: CGPoint,
                        in descriptors: [(frame: CGRect, scale: CGFloat)]) -> Int? {
        descriptors.firstIndex { $0.frame.contains(topLeftPoint) }
    }

    /// The screen whose top-left-space frame contains a top-left point —
    /// the same hit test, mapping the winning index back to its screen.
    static func display(containing topLeftPoint: CGPoint,
                        screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        display(containing: topLeftPoint, in: descriptors(of: screens))
            .map { screens[$0] }
    }

    /// Top-left point → driver desktop pixels, pure: the point scaled by
    /// the backing factor of the display that contains it. Off-screen
    /// points take `fallbackScale` — the least-wrong guess.
    static func topLeftToPixels(_ point: CGPoint,
                                in descriptors: [(frame: CGRect, scale: CGFloat)],
                                fallbackScale: CGFloat = 2) -> CGPoint {
        let scale = display(containing: point, in: descriptors)
            .map { descriptors[$0].scale } ?? fallbackScale
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }

    /// Top-left point → driver desktop pixels for live screens; the
    /// off-screen guess stays the main display's scale.
    static func topLeftToPixels(_ point: CGPoint,
                                screens: [NSScreen] = NSScreen.screens) -> CGPoint {
        topLeftToPixels(point, in: descriptors(of: screens),
                        fallbackScale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// Driver desktop pixels → top-left points, pure (inverse of
    /// `topLeftToPixels`). The containing lookup runs in PIXEL space —
    /// a pixel point lands inside its display's `frame * scale`, not its
    /// point frame — so each descriptor's frame is scaled before the hit
    /// test. Hit-testing raw pixels against point frames misses every
    /// pixel past the point-width edge of a scaled display.
    static func pixelsToTopLeft(_ point: CGPoint,
                                in descriptors: [(frame: CGRect, scale: CGFloat)],
                                fallbackScale: CGFloat = 2) -> CGPoint {
        let index = descriptors.firstIndex { d in
            guard d.scale > 0 else { return false }
            return CGRect(x: d.frame.minX * d.scale, y: d.frame.minY * d.scale,
                          width: d.frame.width * d.scale,
                          height: d.frame.height * d.scale).contains(point)
        }
        let scale = index.map { descriptors[$0].scale } ?? fallbackScale
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }

    /// Driver desktop pixels → top-left points for live screens; the
    /// off-screen guess stays the main display's scale.
    static func pixelsToTopLeft(_ point: CGPoint,
                                screens: [NSScreen] = NSScreen.screens) -> CGPoint {
        pixelsToTopLeft(point, in: descriptors(of: screens),
                        fallbackScale: NSScreen.main?.backingScaleFactor ?? 2)
    }
}
