import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: one converter owns the three screen spaces — global
/// top-left points (driver, windows, gaze), Cocoa bottom-left points
/// (NSScreen frames, panel origins) and screenshot pixels (desktop
/// scope). These fixtures pin the flips and per-display scaling every
/// overlay and gaze hit-test rides on — an off-by-flip here only shows
/// up on the second monitor.
final class ScreenGeometryTests: XCTestCase {

    /// Two-display layout from a real arrangement: primary 1728×1117 @2x
    /// at the Cocoa origin; secondary 1920×1080 @1x to the LEFT — Cocoa x
    /// negative, Cocoa y lifting its bottom edge so the tops align.
    private let primaryHeight: CGFloat = 1117
    private let primaryCocoa = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let leftCocoa = CGRect(x: -1920, y: 37, width: 1920, height: 1080)

    /// The same layout as (top-left frame, scale) descriptors — what the
    /// pure overloads consume. Top-aligned: both frames start at y=0,
    /// the secondary at negative x.
    private var twoDisplays: [(frame: CGRect, scale: CGFloat)] {
        [(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), scale: 2),
         (frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1)]
    }

    /// The Cocoa flip maps both displays into top-left space with tops
    /// at y=0 — the secondary at negative x, sizes unchanged.
    func testTopLeftFrameConversion() {
        XCTAssertEqual(ScreenGeometry.topLeftFrame(cocoaFrame: primaryCocoa,
                                                 primaryHeight: primaryHeight),
                       CGRect(x: 0, y: 0, width: 1728, height: 1117))
        XCTAssertEqual(ScreenGeometry.topLeftFrame(cocoaFrame: leftCocoa,
                                                 primaryHeight: primaryHeight),
                       CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    }

    /// A secondary BELOW the primary (negative Cocoa y) lands at
    /// y = primaryHeight in top-left space; ABOVE lands negative — the
    /// flip preserves arrangement order instead of mirroring it.
    func testTopLeftFrameVerticalArrangements() {
        let below = ScreenGeometry.topLeftFrame(
            cocoaFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            primaryHeight: primaryHeight)
        XCTAssertEqual(below, CGRect(x: 0, y: 1117, width: 1920, height: 1080))
        let above = ScreenGeometry.topLeftFrame(
            cocoaFrame: CGRect(x: 0, y: 1117, width: 1920, height: 1080),
            primaryHeight: primaryHeight)
        XCTAssertEqual(above, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    /// Top-left → AppKit flips y against the primary height, x untouched.
    /// Both directions round-trip — `appKitToTopLeft` is self-inverse.
    func testTopLeftToAppKitRoundTrip() {
        let secondary = ScreenGeometry.topLeftToAppKit(CGPoint(x: -100, y: 50),
                                                       primaryHeight: primaryHeight)
        XCTAssertEqual(secondary, CGPoint(x: -100, y: primaryHeight - 50))
        XCTAssertEqual(ScreenGeometry.appKitToTopLeft(secondary, primaryHeight: primaryHeight),
                       CGPoint(x: -100, y: 50))
        let primary = ScreenGeometry.topLeftToAppKit(CGPoint(x: 500, y: 0),
                                                     primaryHeight: primaryHeight)
        XCTAssertEqual(primary, CGPoint(x: 500, y: primaryHeight))
        XCTAssertEqual(ScreenGeometry.appKitToTopLeft(primary, primaryHeight: primaryHeight),
                       CGPoint(x: 500, y: 0))
    }

    /// Same point-space coordinates, different pixels: scale-2 doubles,
    /// scale-1 passes through — the containing display picks the factor.
    func testTopLeftToPixelsPerDisplayScale() {
        XCTAssertEqual(ScreenGeometry.topLeftToPixels(CGPoint(x: 100, y: 50),
                                                      in: twoDisplays),
                       CGPoint(x: 200, y: 100))
        XCTAssertEqual(ScreenGeometry.topLeftToPixels(CGPoint(x: -100, y: 50),
                                                      in: twoDisplays),
                       CGPoint(x: -100, y: 50))
    }

    /// `pixelsToTopLeft` must invert `topLeftToPixels` on BOTH scales —
    /// including points whose pixels land past the point-width edge of a
    /// @2x display, so the containing lookup has to run in pixel space.
    func testPixelsToTopLeftInverts() {
        for point in [CGPoint(x: 100, y: 50), CGPoint(x: 1500, y: 900),
                      CGPoint(x: -100, y: 50), CGPoint(x: -1900, y: 1000)] {
            let px = ScreenGeometry.topLeftToPixels(point, in: twoDisplays)
            let back = ScreenGeometry.pixelsToTopLeft(px, in: twoDisplays)
            XCTAssertEqual(back.x, point.x, accuracy: 0.0001, "x for \(point)")
            XCTAssertEqual(back.y, point.y, accuracy: 0.0001, "y for \(point)")
        }
    }

    /// A point on the shared edge belongs to exactly one display —
    /// CGRect.contains is min-inclusive/max-exclusive, so x=0 is the
    /// primary's and x=-0.5 is the secondary's; nothing double-claims.
    func testDisplayContainingSharedEdgeClaimsExactlyOne() {
        let d = twoDisplays
        XCTAssertEqual(ScreenGeometry.display(containing: CGPoint(x: 0, y: 50), in: d), 0)
        XCTAssertEqual(ScreenGeometry.display(containing: CGPoint(x: -0.5, y: 50), in: d), 1)
        for point in [CGPoint(x: 0, y: 50), CGPoint(x: -0.5, y: 50)] {
            XCTAssertEqual(d.filter { $0.frame.contains(point) }.count, 1,
                           "\(point) must be claimed by exactly one display")
        }
    }

    /// Points off every display report nil — the caller's fallback owns
    /// the guess (space transitions, menubar gaps between monitors).
    func testDisplayContainingOffScreenIsNil() {
        XCTAssertNil(ScreenGeometry.display(containing: CGPoint(x: -5000, y: 50),
                                            in: twoDisplays))
        // Below the secondary's bottom edge — y=1080 is max-exclusive.
        XCTAssertNil(ScreenGeometry.display(containing: CGPoint(x: -100, y: 5000),
                                            in: twoDisplays))
    }
}
