import Aurora
import SwiftUI

/// B. Siri: the step's control glows with the Apple Intelligence edge light
/// and the callout is a glass card with a thin rim of the same light. A step
/// with consequences shifts both to the warm palette.
@MainActor
public enum GuideAurora: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Siri", axis: "Light on the control and a rim of it on the card",
        pitch: "Wins with the Aurora voice surface: Jarvis guiding you looks like Apple Intelligence pointing, and the warm shift reads as caution without a red alarm.",
        cost: "Two shader views for as long as a step waits (the control and the card's rim), and glass needs Reduce Transparency's solid card.",
        libraries: [Lib.aurora, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The glass card, its travel and word cross-fade (shared with A and C), and mapping step arrivals to the shader's burst.",
        skills: [SkillNote("apple-design", "The card materialises (4 pt blur to sharp with the fade) rather than just fading, and goes solid under Reduce Transparency; type is 17 pt semibold minimum with a 12 pt counter."),
                 SkillNote("animate", "One shader burst per step arrival, timed to the card landing; no loop of its own, the light's slow drift is the library's."),
                 SkillNote("choreograph", "Card and light move together on one spring; the warm palette arrives with the consequential step's words, so the colour and the reason land on the same frame."),
                 SkillNote("emil-design-eng", "GC-1: entry comes from the control (4 pt rise, scale 0.95), exit is 120 ms back into it, and nothing dims to pulse."),
                 SkillNote("animation-performance", "Both shader views are removed the moment the callout is dismissed; an idle guide draws nothing.")],
        alwaysOn: true)

    public static func update(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank) {
        GuideMotion.update(f, c, m)
        if f.visible, c.previous != nil, GuideMotion.stepOf(c.previous) != f.step || m["ton"] < 0.02 {
            m.set("burstAt", c.t - c.local + (c.reduceMotion ? 0 : 0.25), .snap)
        }
    }

    public static func body(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        ZStack(alignment: .topLeading) {
            if m["ton"] > 0.01 { target(c, m) }
            if m["on"] > 0.002 { card(f, c, m) }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func times(_ c: Ctx, _ m: MotionBank) -> AuroraGlow.Times {
        AuroraGlow.Times(elapsed: c.reduceMotion ? 0 : c.t,
                         burst: c.reduceMotion ? -1 : c.t - m.value("burstAt", c.t - 10))
    }

    static func target(_ c: Ctx, _ m: MotionBank) -> some View {
        let r = GuideMotion.target(m, outset: 3)
        return AuroraEdge(size: r.size, radius: m["tr"] + 3, border: 2.5, rim: 5, bloom: 0.8,
                          times: times(c, m), reduceTransparency: c.reduceTransparency,
                          palette: m["warn"] > 0.5 ? .sunset : .appleIntelligence)
            .opacity(m["ton"].clamped(0, 1))
            .offset(x: r.minX, y: r.minY)
    }

    static func card(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let r = GuideMotion.frame(m)
        let pad = GuideMotion.padding(m["scale"])
        let rise = m["rise"]
        let radius = 14 * max(1, m["scale"])
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let ink = c.dark ? Color.white : Color.black.opacity(0.88)
        let warmInk = c.dark ? Color(red: 1, green: 0.7, blue: 0.35) : Color(red: 0.78, green: 0.36, blue: 0.0)
        let glass = c.dark ? Color(white: 0.08).opacity(c.reduceTransparency ? 0.98 : 0.9)
                           : Color.white.opacity(c.reduceTransparency ? 0.99 : 0.93)
        return ZStack(alignment: .topLeading) {
            shape.fill(glass)
            AuroraEdge(size: r.size, radius: radius, border: 1.5, rim: 3, bloom: 0,
                       times: times(c, m), reduceTransparency: c.reduceTransparency,
                       palette: m["warn"] > 0.5 ? .sunset : .appleIntelligence)
                .opacity(0.9)
            ZStack(alignment: .topLeading) {
                ForEach(1...3, id: \.self) { step in
                    if m["t\(step)"] > 0.002 {
                        GuideMotion.words(step, f, m, ink: ink, secondary: ink.opacity(0.55), warnInk: warmInk)
                            .frame(width: max(0, r.width - 2 * pad.width), alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, pad.width)
            .padding(.vertical, pad.height)
        }
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .clipShape(shape)
        .shadow(color: .black.opacity(c.dark ? 0.4 : 0.16), radius: 18, y: 6)
        .blur(radius: c.reduceMotion || c.reduceTransparency ? 0 : (1 - m["on"]) * 4)
        .scaleEffect(c.reduceMotion ? 1 : 0.95 + 0.05 * rise, anchor: .top)
        .offset(x: r.minX, y: r.minY - (c.reduceMotion ? 0 : (1 - rise) * 4))
        .opacity(m["on"])
    }
}
