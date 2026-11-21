import AppKit
import Aurora
import Orb
import SwiftUI
import ThinkingOrbsKit

/// The three families as they show up inside a window: the chrome is native
/// macOS 26 in all three, and only where Jarvis is live (listening, working,
/// needs you) does a family's own material or light appear.
enum WinFamily { case island, glow, quiet }

/// SF Pro text styles at the sizes macOS gives them
/// (NSFont.preferredFont(forTextStyle:)), times the comfort label scale.
/// macOS has no Dynamic Type, so the product needs the same multiply (SW-1).
@MainActor
enum WType {
    private static var cache: [String: CGFloat] = [:]

    static func size(_ style: NSFont.TextStyle) -> CGFloat {
        if let s = cache[style.rawValue] { return s }
        let s = NSFont.preferredFont(forTextStyle: style).pointSize
        cache[style.rawValue] = s
        return s
    }

    static func font(_ style: NSFont.TextStyle, _ k: Double, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size(style) * k, weight: weight)
    }
}

/// Window colours for one appearance, with Reduce Transparency's solid glass.
struct WinInk {
    var dark: Bool
    var solid: Bool

    init(_ c: Ctx) {
        dark = c.dark
        solid = c.reduceTransparency
    }

    var window: Color { dark ? Color(white: 0.115) : Color(white: 0.965) }
    var group: Color { dark ? Color(white: 0.16) : .white }
    var groupStroke: Color { (dark ? Color.white : Color.black).opacity(dark ? 0.07 : 0.07) }
    var glass: Color {
        dark ? Color(white: 0.2).opacity(solid ? 1 : 0.72) : Color(white: 0.985).opacity(solid ? 1 : 0.8)
    }
    var glassStroke: Color { (dark ? Color.white : Color.black).opacity(dark ? 0.1 : 0.06) }
    var primary: Color { dark ? Color.white.opacity(0.92) : Color.black.opacity(0.86) }
    var secondary: Color { dark ? Color.white.opacity(0.56) : Color.black.opacity(0.52) }
    var tertiary: Color { dark ? Color.white.opacity(0.32) : Color.black.opacity(0.28) }
    var separator: Color { (dark ? Color.white : Color.black).opacity(0.08) }
    var control: Color { dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06) }
    var selection: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.07) }
    var accent: Color { dark ? Color(red: 0.04, green: 0.52, blue: 1) : Color(red: 0, green: 0.48, blue: 1) }
    /// The one colour that means "needs you", shared with the overlays.
    var ask: Color { AgentRoster.ask }
    var askInk: Color { dark ? AgentRoster.ask : AgentRoster.ask.mix(with: .black, by: 0.22) }
}

// MARK: Standard controls

// ImageRenderer can't draw AppKit-backed controls (Toggle, Picker, Slider and
// TextField come out blank), so the lab draws each at macOS 26's geometry;
// the product uses the real controls.

struct WSwitch: View {
    var on: Double
    /// The knob rides its own spring, apart from the colour, so Reduce
    /// Motion can jump the knob and still fade the fill.
    var knob: Double? = nil
    var k: Double
    var ink: WinInk
    var body: some View {
        let knob = self.knob ?? on
        let w = 32 * k, h = 19 * k, d = h - 4 * k
        ZStack(alignment: .leading) {
            Capsule().fill(ink.control.mix(with: ink.accent, by: on))
            Circle().fill(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 1.5 * k, y: 0.5 * k)
                .frame(width: d, height: d)
                .offset(x: 2 * k + (w - d - 4 * k) * knob)
        }
        .frame(width: w, height: h)
    }
}

struct WSegmented: View {
    var items: [String]
    /// The selected index, animated (fractions slide the thumb between items).
    var index: Double
    var k: Double
    var ink: WinInk
    var body: some View {
        let pad = 12 * k
        let widths = items.map { TextMetrics.width($0, size: WType.size(.body) * k, weight: .regular) + pad * 2 }
        let lower = Int(index.rounded(.down)).clamped(0, items.count - 1)
        let upper = min(items.count - 1, lower + 1)
        let p = index - Double(lower)
        let x = { (i: Int) in widths.prefix(i).reduce(0, +) }
        let thumbX = x(lower) + (x(upper) - x(lower)) * p
        let thumbW = widths[lower] + (widths[upper] - widths[lower]) * p
        let h = 24 * k
        ZStack(alignment: .leading) {
            Capsule().fill(ink.control)
            Capsule().fill(ink.dark ? Color(white: 0.36) : .white)
                .shadow(color: .black.opacity(ink.dark ? 0.3 : 0.14), radius: 2 * k, y: 0.5 * k)
                .frame(width: thumbW - 4 * k, height: h - 4 * k)
                .offset(x: thumbX + 2 * k)
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    Text(item).font(WType.font(.body, k))
                        .foregroundStyle(ink.primary.opacity(abs(Double(i) - index) < 0.5 ? 1 : 0.7))
                        .frame(width: widths[i])
                }
            }
        }
        .frame(width: widths.reduce(0, +), height: h)
        .fixedSize()
    }
}

struct WButton: View {
    var title: String
    var k: Double
    var ink: WinInk
    var prominent = false
    var tint: Color? = nil
    var enabled = true
    var body: some View {
        Text(title).font(WType.font(.body, k, prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : ink.primary.opacity(enabled ? 1 : 0.35))
            .padding(.horizontal, 12 * k)
            .frame(height: 24 * k)
            .background(Capsule().fill(prominent ? (tint ?? ink.accent) : ink.control))
            .fixedSize()
    }
}

struct WPopup: View {
    var title: String
    var k: Double
    var ink: WinInk
    var body: some View {
        HStack(spacing: 6 * k) {
            Text(title).font(WType.font(.body, k)).foregroundStyle(ink.primary)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9 * k, weight: .semibold)).foregroundStyle(ink.secondary)
        }
        .padding(.leading, 11 * k).padding(.trailing, 8 * k)
        .frame(height: 24 * k)
        .background(Capsule().fill(ink.control))
        .fixedSize()
    }
}

struct WSlider: View {
    /// 0...1 along the track.
    var value: Double
    var ticks: Int
    var width: CGFloat
    var k: Double
    var ink: WinInk
    var body: some View {
        let knobW = 22 * k, knobH = 15 * k
        let travel = width - knobW
        VStack(spacing: 5 * k) {
            ZStack(alignment: .leading) {
                Capsule().fill(ink.control).frame(height: 4 * k)
                Capsule().fill(ink.accent).frame(width: knobW / 2 + travel * value, height: 4 * k)
                Capsule().fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2 * k, y: 0.5 * k)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                    .frame(width: knobW, height: knobH)
                    .offset(x: travel * value)
            }
            .frame(width: width, height: knobH)
            HStack(spacing: 0) {
                ForEach(0..<ticks, id: \.self) { i in
                    Capsule().fill(ink.tertiary).frame(width: 1.5 * k, height: 5 * k)
                    if i < ticks - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, knobW / 2 - 0.75 * k)
            .frame(width: width)
        }
    }
}

struct WRadio: View {
    var on: Bool
    var k: Double
    var ink: WinInk
    var body: some View {
        ZStack {
            Circle().fill(on ? ink.accent : ink.control)
            if on { Circle().fill(Color.white).frame(width: 6 * k, height: 6 * k) }
        }
        .frame(width: 15 * k, height: 15 * k)
    }
}

/// A one-line text field with its placeholder.
struct WField: View {
    var placeholder: String
    var k: Double
    var ink: WinInk
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 8 * k) {
            Text(placeholder).font(WType.font(.body, k)).foregroundStyle(ink.tertiary).lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 20 * k)).foregroundStyle(ink.tertiary)
            }
        }
        .padding(.leading, 13 * k).padding(.trailing, 5 * k)
        .frame(height: 32 * k)
        .background(Capsule().fill(ink.dark ? Color.white.opacity(0.06) : .white))
        .overlay(Capsule().strokeBorder(ink.groupStroke, lineWidth: 1))
    }
}

/// A System Settings sidebar tile: a white glyph on a coloured rounded square.
struct WTile: View {
    var symbol: String
    var color: Color
    var k: Double
    var body: some View {
        RoundedRectangle(cornerRadius: 5 * k, style: .continuous)
            .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.12), color], startPoint: .top, endPoint: .bottom))
            .frame(width: 20 * k, height: 20 * k)
            .overlay(Image(systemName: symbol).font(.system(size: 11 * k, weight: .semibold)).foregroundStyle(.white))
    }
}

// MARK: Forms

/// One row of a grouped form: title, optional detail under it, control trailing.
struct WRow<Trailing: View>: View {
    var title: String
    var detail: String? = nil
    var k: Double
    var ink: WinInk
    var detailColor: Color? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12 * k) {
            VStack(alignment: .leading, spacing: 2 * k) {
                Text(title).font(WType.font(.body, k)).foregroundStyle(ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(WType.font(.subheadline, k)).foregroundStyle(detailColor ?? ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8 * k)
            trailing
        }
        .padding(.horizontal, 12 * k)
        .padding(.vertical, 8 * k)
        .frame(minHeight: 36 * k)
    }
}

/// A grouped form box: rows on a rounded surface, separators inset.
struct WGroup<Content: View>: View {
    var k: Double
    var ink: WinInk
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12 * k, style: .continuous).fill(ink.group))
            .overlay(RoundedRectangle(cornerRadius: 12 * k, style: .continuous).strokeBorder(ink.groupStroke, lineWidth: 0.5))
    }
}

struct WSeparator: View {
    var k: Double
    var ink: WinInk
    var body: some View {
        Rectangle().fill(ink.separator.opacity(0.7)).frame(height: 1).padding(.leading, 12 * k)
    }
}

// MARK: Window

/// A macOS 26 window: one rounded slab, the sidebar a floating glass pane
/// inside it with the traffic lights, the toolbar title over the content,
/// and a soft scroll edge where content passes under the toolbar.
struct WWindow<Sidebar: View, Toolbar: View, Content: View>: View {
    var frame: CGRect
    var sidebarWidth: CGFloat
    var ink: WinInk
    var k: Double = 1
    @ViewBuilder var sidebar: Sidebar
    /// The toolbar's title, over the content.
    @ViewBuilder var toolbar: Toolbar
    @ViewBuilder var content: Content

    /// The toolbar's height grows with its title at larger label sizes.
    static func toolbar(_ k: Double) -> CGFloat { 52 + 18 * (k - 1) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let contentX = sidebarWidth + 16
        let contentW = frame.width - contentX
        ZStack(alignment: .topLeading) {
            shape.fill(ink.window)
            content
                .frame(width: contentW, height: frame.height, alignment: .topLeading)
                .clipped()
                .mask(VStack(spacing: 0) {
                    Color.clear.frame(height: Self.toolbar(k) - 16)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 22)
                    Rectangle()
                })
                .offset(x: contentX)
            toolbar
                .frame(height: Self.toolbar(k) - 6, alignment: .leading)
                .offset(x: contentX + 20)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ink.glass)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ink.glassStroke, lineWidth: 0.5))
                    .shadow(color: .black.opacity(ink.dark ? 0.3 : 0.08), radius: 8, y: 2)
                sidebar
                    .frame(width: sidebarWidth, height: frame.height - 16, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 12, height: 12)
                    }
                }
                .offset(x: 14, y: 14)
            }
            .frame(width: sidebarWidth, height: frame.height - 16)
            .offset(x: 8, y: 8)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder((ink.dark ? Color.white : Color.black).opacity(ink.dark ? 0.14 : 0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(ink.dark ? 0.5 : 0.2), radius: 34, y: 18)
        .offset(x: frame.minX, y: frame.minY)
    }
}

/// The sidebar's selection: one neutral rounded highlight that slides
/// between rows on a spring rather than jumping.
struct WSelection: View {
    var y: CGFloat
    var height: CGFloat
    var width: CGFloat
    var k: Double
    var ink: WinInk
    var body: some View {
        RoundedRectangle(cornerRadius: 8 * k, style: .continuous).fill(ink.selection)
            .frame(width: width, height: height)
            .offset(x: 8, y: y)
    }
}

// MARK: The families' live marks

/// An agent's or Jarvis's face in a family: A a black island disc with the
/// thinking orb, B a lit colour dot on glass, C the Orb marble. It moves only
/// when \`moving\` (working, and not under Reduce Motion).
struct WAvatar: View {
    var family: WinFamily
    var color: Color
    var size: CGFloat
    var moving: Bool
    var asking: Double = 0
    var t: Double
    var ink: WinInk

    var body: some View {
        switch family {
        case .island:
            ZStack {
                Circle().fill(Color.black)
                    .overlay(Circle().strokeBorder(Color.white.opacity(ink.dark ? 0.14 : 0), lineWidth: 0.5))
                ThinkingOrb(state: asking > 0.5 ? .listening : .working, size: .px20, theme: .dark, paused: !moving, displaySize: size * 0.62)
                    .orbFrozenTime(moving ? t : nil)
                    .frame(width: size * 0.62, height: size * 0.62)
                Circle().fill(color.mix(with: AgentRoster.ask, by: asking))
                    .overlay(Circle().strokeBorder(ink.window, lineWidth: max(1.5, size * 0.06)))
                    .frame(width: size * 0.36, height: size * 0.36)
                    .offset(x: size * 0.36, y: size * 0.36)
            }
            .frame(width: size, height: size)
        case .glow:
            ZStack {
                Circle().fill(ink.dark ? Color.white.opacity(0.08) : Color.white)
                    .overlay(Circle().strokeBorder(ink.groupStroke, lineWidth: 0.5))
                Circle().fill(color.mix(with: AgentRoster.ask, by: asking))
                    .frame(width: size * 0.38, height: size * 0.38)
                    .shadow(color: color.mix(with: AgentRoster.ask, by: asking).opacity(moving || asking > 0.01 ? 0.9 : 0), radius: size * 0.16)
            }
            .frame(width: size, height: size)
        case .quiet:
            OrbView(configuration: OrbConfiguration(backgroundColors: [color, color.mix(with: .white, by: 0.35), color.mix(with: .black, by: 0.2)],
                                                    glowColor: .white, coreGlowIntensity: 0.7,
                                                    showParticles: false, showShadow: false,
                                                    speed: moving ? 20 : 0))
                .frame(width: size, height: size)
        }
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(hi, Swift.max(lo, self)) }
}
