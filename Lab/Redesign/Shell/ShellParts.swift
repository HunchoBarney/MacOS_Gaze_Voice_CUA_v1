import AppKit
import Orb
import SwiftUI

/// Where Jarvis's status item sits in the fixture menu bar: the next item to
/// the left of the system's own (battery, Wi-Fi, Spotlight, Control Centre,
/// clock), measured from the same row MacDesktop draws.
@MainActor
enum StatusBar {
    static let systemItems: CGFloat = {
        let row = HStack(spacing: 16) {
            Image(systemName: "battery.75percent")
            Image(systemName: "wifi")
            Image(systemName: "magnifyingglass")
            Image(systemName: "switch.2")
            Text("Fri Nov 21  9:41 AM")
        }
        .font(.system(size: 13.5, weight: .medium))
        .fixedSize()
        return NSHostingView(rootView: row).fittingSize.width
    }()

    /// The trailing edge of Jarvis's item.
    static var trailing: CGFloat { Desk.size.width - 20 - systemItems - 8 }

    /// Bigger labels grow the glyph until it fills the 22 pt a status item
    /// may use; the menu bar's own height is the system's, not ours.
    static func scale(_ k: Double) -> CGFloat { min(k, 1.375) }

    static func ink(_ c: Ctx) -> Color { c.dark ? .white : Color.black.opacity(0.85) }

    /// The rounded highlight macOS 26 draws behind an item while its menu is open.
    static func openHighlight(_ c: Ctx, width: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill((c.dark ? Color.white : Color.black).opacity(0.16 * opacity))
            .frame(width: width + 6, height: 26)
            .frame(width: width, height: Desk.menuBar)
    }
}

/// Shared parts of every status item direction: placement and the tooltip.
@MainActor
enum ItemStage {
    static func place<G: View>(_ glyph: G, width: CGFloat, _ f: ItemFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let x = StatusBar.trailing - width
        let tip = m["i.tip"].clamped(0, 1)
        return ZStack(alignment: .topLeading) {
            glyph.frame(width: width, height: Desk.menuBar).offset(x: x)
            if tip > 0.005 {
                let text = ItemScript.describe(f)
                let w = ShellTooltip.width(text, f.labelScale)
                ShellTooltip(text: text, k: f.labelScale, dark: c.dark)
                    .offset(x: min(x + width / 2 - 10, Desk.size.width - 8 - w), y: Desk.menuBar + 6)
                    .opacity(tip)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    /// Native tooltips wait for the pointer to rest; under Reduce Motion they just appear.
    static func tip(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) {
        let on = f.tooltip && (c.reduceMotion || c.previous == nil || c.local > 0.5)
        m.set("i.tip", on ? 1 : 0, on ? c.fade(.easeOut(0.12)) : c.fade(.easeOut(0.1)))
    }

    /// Per-phase glyph content: the old glyph leaves fast, the new one
    /// arrives once it has; a phase the item was already in stays put.
    static func phases(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank, delay: Double = 0.06) {
        let previous = ItemScript.phase(of: c.previous)
        for p in ItemFixture.Phase.allCases {
            let on = f.phase == p && (c.reduceMotion || c.previous == nil || previous == p || c.local > delay)
            m.set("i." + p.rawValue, on ? 1 : 0, on ? c.fade(.easeOut(0.2)) : c.fade(.easeOut(0.1)))
        }
    }
}

/// One glyph arriving: opacity, a little blur and scale, the shape of SF
/// Symbols' replace effect; under Reduce Motion opacity only.
struct SymbolIn: ViewModifier {
    var p: Double
    var reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .opacity(p.clamped(0, 1))
            .scaleEffect(reduceMotion ? 1 : 0.7 + 0.3 * p)
            .blur(radius: reduceMotion ? 0 : (1 - p.clamped(0, 1)) * 2)
    }
}

/// A native tooltip: 11 pt system text on the tooltip material.
struct ShellTooltip: View {
    var text: String
    var k: Double
    var dark: Bool

    static func width(_ text: String, _ k: Double) -> CGFloat {
        TextMetrics.width(text, size: 11 * k, weight: .regular) + 16 * k
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6 * k, style: .continuous)
        Text(text)
            .font(.system(size: 11 * k))
            .foregroundStyle(dark ? Color.white.opacity(0.9) : Color.black.opacity(0.85))
            .padding(.horizontal, 8 * k)
            .padding(.vertical, 4 * k)
            .fixedSize()
            .background(shape.fill(dark ? Color(white: 0.2) : Color(white: 0.97)))
            .overlay(shape.strokeBorder((dark ? Color.white : Color.black).opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.4 : 0.15), radius: 6, y: 2)
    }
}

/// macOS 26 glass for menus and popovers. ImageRenderer can't sample what is
/// behind a view, so the fixture desktop is drawn again under the panel and
/// blurred; the product uses NSMenu's own material (or glassEffect).
/// Reduce Transparency makes it solid.
struct ShellGlass: View {
    var frame: CGRect
    var radius: CGFloat
    var scheme: ColorScheme
    var showsMail: Bool
    var reduceTransparency: Bool
    /// A solid tint instead of the system material (the black island).
    var tint: Color? = nil

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let tint {
                shape.fill(tint)
            } else if reduceTransparency {
                shape.fill(dark ? Color(white: 0.17) : Color(white: 0.96))
            } else {
                MacDesktop(scheme: scheme, showsMail: showsMail)
                    .offset(x: -frame.minX, y: -frame.minY)
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .clipped()
                    .blur(radius: 26)
                    .clipShape(shape)
                shape.fill(dark ? Color(white: 0.11).opacity(0.62) : Color.white.opacity(0.66))
            }
        }
        .overlay(
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(dark || tint != nil ? 0.22 : 0.9),
                                                       Color.white.opacity(dark || tint != nil ? 0.05 : 0.35)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        )
        .overlay(shape.inset(by: -0.5).stroke(Color.black.opacity(dark ? 0.55 : 0.1), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(dark ? 0.45 : 0.2), radius: 20, y: 10)
        .frame(width: frame.width, height: frame.height)
    }
}

/// The Orb library's marble at a small size. Orb's layers carry fixed
/// paddings and blurs tuned for a large orb, so it is drawn at 120 pt and
/// scaled down rather than laid out small.
struct Marble: View {
    var configuration: OrbConfiguration
    var size: CGFloat
    var body: some View {
        OrbView(configuration: configuration)
            .frame(width: 120, height: 120)
            .scaleEffect(size / 120)
            .frame(width: size, height: size)
    }
}

/// The colours macOS draws selections, default buttons and states in.
enum ShellAccent {
    static func blue(_ dark: Bool) -> Color { dark ? Color(red: 0.04, green: 0.52, blue: 1) : Color(red: 0, green: 0.48, blue: 1) }
    static let amber = Color(red: 1, green: 0.62, blue: 0.24)
    static let green = Color(red: 0.2, green: 0.78, blue: 0.35)
}
