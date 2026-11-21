import Orb
import SwiftUI

/// C. Popover: a plain macOS popover with its arrow on the control, a crisp
/// outline on the control and the gaze lens's marble docked at its corner.
/// A step with consequences turns the outline and a warning glyph orange.
@MainActor
public enum GuideQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Popover", axis: "Quietest: an arrowed popover and a crisp outline, no glow",
        pitch: "Wins if guidance should feel like macOS itself, a popover you already know how to read, with nothing moving while you read it.",
        cost: "Least presence of the three: on a busy window the outline and an opaque card are easier to overlook than light.",
        libraries: [Lib.orb, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The popover card with its arrow, the outline, and the arrow's travel along the card's edge.",
        skills: [SkillNote("apple-design", "Familiarity: the arrowed popover is AppKit's own grammar; the arrow always points at the control's centre, even when the card is pushed off-centre by the window edge."),
                 SkillNote("remove-animations", "Nothing loops: the marble is still and the outline is static, so a step can wait for minutes at zero cost (not always-on)."),
                 SkillNote("animate", "Entry 0.34 s spring at 0.82 from scale 0.95 at the arrow; travel 0.4 s critically damped, since a card you're reading shouldn't overshoot."),
                 SkillNote("emil-design-eng", "GC-1: the 55% opacity pulse becomes one 3% swell of the outline on arrival; the words never dim."),
                 SkillNote("break-ui", "The warning tone is shape and words as well as colour (a triangle and 'Can't be undone'), so it survives colour blindness and Increase Contrast.")],
        alwaysOn: false)

    static let tint = Color(red: 0.42, green: 0.52, blue: 1)
    static let warn = Color(red: 1, green: 0.58, blue: 0.1)

    public static func update(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank) {
        GuideMotion.update(f, c, m, travel: .spring(response: 0.4, damping: 1))
    }

    public static func body(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        ZStack(alignment: .topLeading) {
            if m["ton"] > 0.01 { target(c, m) }
            if m["on"] > 0.002 { card(f, c, m) }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func target(_ c: Ctx, _ m: MotionBank) -> some View {
        let r = GuideMotion.target(m, outset: 3)
        let color = tint.mix(with: warn, by: m["warn"].clamped(0, 1))
        let shape = RoundedRectangle(cornerRadius: m["tr"] + 3, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(c.dark ? 0.14 : 0.09))
                .overlay(shape.strokeBorder(color, lineWidth: 1.5))
                .frame(width: r.width, height: r.height)
                .scaleEffect(1 + 0.03 * m["pop"])
            OrbView(configuration: OrbConfiguration(backgroundColors: [Color(red: 0.55, green: 0.35, blue: 1), tint, .cyan],
                                                    glowColor: .white, coreGlowIntensity: 0.9,
                                                    showParticles: false, showShadow: false, speed: 0))
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .offset(x: r.width - 7, y: -5)
        }
        .opacity(m["ton"].clamped(0, 1))
        .offset(x: r.minX, y: r.minY)
    }

    static func card(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let r = GuideMotion.frame(m)
        let pad = GuideMotion.padding(m["scale"])
        let rise = m["rise"]
        let radius = 10 * max(1, m["scale"])
        let ink = c.dark ? Color.white : Color.black.opacity(0.88)
        let surface = c.dark ? Color(white: 0.17) : Color.white
        let edge = (c.dark ? Color.white : Color.black).opacity(0.14)
        let arrowX = (m["tx"] + m["tw"] / 2 - r.minX).clamped(radius + 8, r.width - radius - 8)
        let warnInk = c.dark ? warn : Color(red: 0.78, green: 0.36, blue: 0.0)
        let shape = Popover(radius: radius, arrowX: arrowX)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(1...3, id: \.self) { step in
                    if m["t\(step)"] > 0.002 {
                        GuideMotion.words(step, f, m, ink: ink, secondary: ink.opacity(0.55), warnInk: warnInk)
                            .frame(width: max(0, r.width - 2 * pad.width), alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, pad.width)
            .padding(.vertical, pad.height)
            .offset(y: Popover.arrow)
        }
        .frame(width: r.width, height: r.height + Popover.arrow, alignment: .topLeading)
        .background(shape.fill(surface))
        .overlay(shape.stroke(edge, lineWidth: 0.5))
        .shadow(color: .black.opacity(c.dark ? 0.45 : 0.18), radius: 12, y: 4)
        .scaleEffect(c.reduceMotion ? 1 : 0.95 + 0.05 * rise, anchor: UnitPoint(x: arrowX / max(1, r.width), y: 0))
        .offset(x: r.minX, y: r.minY - Popover.arrow - (c.reduceMotion ? 0 : (1 - rise) * 4))
        .opacity(m["on"])
    }
}

/// A rounded card with an arrow on its top edge, AppKit popover style.
struct Popover: Shape {
    static let arrow: CGFloat = 8
    var radius: CGFloat
    var arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + Self.arrow, width: rect.width, height: rect.height - Self.arrow)
        var p = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        var tip = Path()
        tip.move(to: CGPoint(x: rect.minX + arrowX - 9, y: body.minY + 0.5))
        tip.addQuadCurve(to: CGPoint(x: rect.minX + arrowX, y: rect.minY), control: CGPoint(x: rect.minX + arrowX - 3, y: body.minY))
        tip.addQuadCurve(to: CGPoint(x: rect.minX + arrowX + 9, y: body.minY + 0.5), control: CGPoint(x: rect.minX + arrowX + 3, y: body.minY))
        tip.closeSubpath()
        p.addPath(tip)
        return p
    }
}
