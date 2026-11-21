import Orb
import SwiftUI

/// C. Quiet: a crisp ring, the outline of Jarvis's marble. The marble fills
/// it while Jarvis is live (warm when it needs you), a fine arc runs the ring
/// like the system spinner while it works, and the count is knocked out of
/// a template badge. No glow.
@MainActor
public enum ItemQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Marble", axis: "Quietest: a template ring the marble fills when Jarvis is live",
        pitch: "Wins if the menu bar should stay the system's: one crisp ring at the weight of Wi-Fi and the battery, and the Orb marble inside it is the only colour, there only while Jarvis listens, works or waits for you.",
        cost: "Smallest signal of the three: a 10 pt marble is easy to miss at a glance, so listening and working differ only by the spinner arc.",
        libraries: [Lib.orb, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The ring, the spinner arc and the knocked-out count badge; the marble is the Orb library held still (speed 0, no particles).",
        skills: [SkillNote("apple-design", "Template first: ring, dot, pause bars and the slash are drawn at the system items' 1.5 pt stroke, so in both appearances Jarvis matches its neighbours; colour arrives only with the marble."),
                 SkillNote("emil-design-eng", "MB-1: the count is cut out of a template badge on the ring's shoulder (destination-out), the way the system badges its own glyphs, so width never changes."),
                 SkillNote("animate", "The marble lands on a critically damped 0.32 s spring from 60% scale; no overshoot in a surface this small and this constant."),
                 SkillNote("remove-animations", "The marble is still (Orb at speed 0). The only motion is the working arc, at the system spinner's pace, and only while working."),
                 SkillNote("find-animation-opportunities", "Working needed a sign of life the other states don't have; a ring you already read as 'in progress' is the cheapest one."),
                 SkillNote("choreograph", "The marble and its warmth change together; glyph details (dot, bars, slash) cross-fade 60 ms after."),
                 SkillNote("break-ui", "Largest labels (2x): ring, marble and badge grow to 22 pt together; the slash and badge are shape, not colour, so they survive Increase Contrast and colour blindness."),
                 SkillNote("animate-expo", "Principles only: spring for scale, timing for opacity; under Reduce Motion the arc stops and the marble appears without growing.")],
        alwaysOn: true)

    static func width(_ k: Double) -> CGFloat { 28 * StatusBar.scale(k) }

    static let cool = OrbConfiguration(backgroundColors: [Color(red: 0.55, green: 0.35, blue: 1), Color(red: 0.42, green: 0.52, blue: 1), .cyan],
                                       glowColor: .white, coreGlowIntensity: 0.9, showParticles: false, showShadow: false, speed: 0)
    static let warmOrb = OrbConfiguration(backgroundColors: [Color(red: 1, green: 0.45, blue: 0.15), ShellAccent.amber, Color(red: 1, green: 0.82, blue: 0.3)],
                                          glowColor: .white, coreGlowIntensity: 0.9, showParticles: false, showShadow: false, speed: 0)

    public static func update(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) {
        m.set("i.marble", f.live ? 1 : 0, c.geo(.spring(response: 0.32, damping: 1)))
        m.set("i.marbleO", f.live ? 1 : 0, c.fade(.easeOut(f.live ? 0.16 : 0.2)))
        m.set("i.warm", f.phase == .asks ? 1 : 0, c.fade(.easeOut(0.25)))
        ItemStage.phases(f, c, m)
        ItemStage.tip(f, c, m)
    }

    public static func body(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        ItemStage.place(glyph(f, c, m), width: width(f.labelScale), f, c, m)
    }

    static func glyph(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let s = StatusBar.scale(f.labelScale)
        let ink = StatusBar.ink(c)
        let ring = 16 * s, line = 1.5 * s
        let mo = m["i.marbleO"].clamped(0, 1), scale = 0.6 + 0.4 * m["i.marble"], warm = m["i.warm"].clamped(0, 1)
        let badge = m["i." + ItemFixture.Phase.asks.rawValue].clamped(0, 1)
        return ZStack {
            Circle().strokeBorder(ink, lineWidth: line).frame(width: ring, height: ring)
                .opacity(1 - 0.5 * m["i." + ItemFixture.Phase.noMic.rawValue])
            if mo * (1 - warm) > 0.005 {
                Marble(configuration: cool, size: 10 * s).scaleEffect(scale).opacity(mo * (1 - warm))
            }
            if mo * warm > 0.005 {
                Marble(configuration: warmOrb, size: 10 * s).scaleEffect(scale).opacity(mo * warm)
            }
            ForEach([ItemFixture.Phase.standby, .paused, .noMic], id: \.rawValue) { p in
                let o = m["i." + p.rawValue]
                if o > 0.005 { detail(p, s, ink, line).modifier(SymbolIn(p: o, reduceMotion: c.reduceMotion)) }
            }
            let working = m["i." + ItemFixture.Phase.working.rawValue].clamped(0, 1)
            if working > 0.005 {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(ink, style: StrokeStyle(lineWidth: line + 0.4 * s, lineCap: .round))
                    .frame(width: ring - line, height: ring - line)
                    .rotationEffect(.degrees(c.reduceMotion ? -90 : c.t * 330))
                    .opacity(working)
            }
            if badge > 0.005 {
                ZStack {
                    Circle().fill(ink).frame(width: 10 * s, height: 10 * s)
                    Text(f.asks > 9 ? "+" : "\(f.asks)")
                        .font(.system(size: 7.5 * s, weight: .heavy, design: .rounded)).monospacedDigit()
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .offset(x: 7 * s, y: -6 * s)
                .opacity(badge)
                .scaleEffect(c.reduceMotion ? 1 : 0.7 + 0.3 * badge, anchor: .topTrailing)
            }
        }
        .frame(width: width(f.labelScale), height: Desk.menuBar)
    }

    @ViewBuilder
    static func detail(_ p: ItemFixture.Phase, _ s: CGFloat, _ ink: Color, _ line: CGFloat) -> some View {
        switch p {
        case .standby:
            Circle().fill(ink).frame(width: 4 * s, height: 4 * s)
        case .paused:
            HStack(spacing: 2 * s) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 0.75 * s).fill(ink).frame(width: 1.8 * s, height: 6 * s)
                }
            }
        case .noMic:
            Capsule().fill(ink).frame(width: line, height: 19 * s).rotationEffect(.degrees(-45))
        default:
            EmptyView()
        }
    }
}
