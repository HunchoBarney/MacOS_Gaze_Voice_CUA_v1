import BorderBeamKit
import SwiftUI

/// A. Island: the callout is a black island that grows out of the control it
/// points at, which runs a beam. On the next step the same island travels to
/// the next control; a step with consequences turns the beam warm.
@MainActor
public enum GuideIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island", axis: "One black island that travels from step to step",
        pitch: "Wins with the Island voice surface and Beam highlights: the guide is the same black object and the same light, so a guided task reads as Jarvis's own hand.",
        cost: "A beam keeps moving the whole time a step waits for you, which is more motion than C on a screen you're reading.",
        libraries: [Lib.borderBeam, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The card and its travel (four springs), the word cross-fade and the counter line.",
        skills: [SkillNote("apple-design", "Spatial consistency: the callout grows out of its control (scale 0.94 from the top edge, 4 pt rise) and returns into it when dismissed (GC-1); the next step is the same object travelling, never a new one."),
                 SkillNote("choreograph", "On a step change the card leads and the words follow: old words leave in 100 ms, new words land 80 ms in, and the beam re-lights on the new control as the card arrives."),
                 SkillNote("animate", "Travel is a 0.42 s spring at 0.86 damping; entry 0.34 s at 0.82; exit is a 120 ms ease-out, faster than entry because you're done with it."),
                 SkillNote("emil-design-eng", "GC-1's dimming pulse is gone: arrival is one 3% swell of the control's light, so the words never flicker."),
                 SkillNote("break-ui", "Largest labels (2x): 34 pt words with padding, corner radius and the 600 pt width cap scaled with them, so the card wraps to two lines and stays inside the window instead of clipping."),
                 SkillNote("gestures", "Every value is a spring retarget, so a step that changes mid-travel bends toward the new control instead of finishing the old move.")],
        alwaysOn: true)

    public static func update(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank) {
        GuideMotion.update(f, c, m)
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
        let radius = m["tr"] + 3
        return BorderBeam(size: .sm, colorVariant: m["warn"] > 0.5 ? .sunset : .colorful, theme: c.dark ? .dark : .light,
                          staticColors: c.reduceMotion, borderRadius: radius, strength: m["ton"].clamped(0, 1)) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill((c.dark ? Color.white : Color.black).opacity(0.05 + 0.05 * m["pop"]))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder((c.dark ? Color.white : Color.black).opacity(0.22), lineWidth: 1))
                .frame(width: r.width, height: r.height)
        }
        .environment(\.beamFrozenTime, c.reduceMotion ? 0 : c.t)
        .scaleEffect(1 + 0.03 * m["pop"])
        .offset(x: r.minX, y: r.minY)
    }

    static func card(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let r = GuideMotion.frame(m)
        let pad = GuideMotion.padding(m["scale"])
        let rise = m["rise"]
        let shape = RoundedRectangle(cornerRadius: 14 * max(1, m["scale"]) , style: .continuous)
        let amber = Color(red: 1, green: 0.72, blue: 0.25)
        return ZStack(alignment: .topLeading) {
            ForEach(1...3, id: \.self) { step in
                if m["t\(step)"] > 0.002 {
                    GuideMotion.words(step, f, m, ink: .white, secondary: Color.white.opacity(0.55), warnInk: amber)
                        .frame(width: max(0, r.width - 2 * pad.width), alignment: .leading)
                }
            }
            .padding(.horizontal, pad.width)
            .padding(.vertical, pad.height)
        }
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .background(shape.fill(Color.black))
        .overlay(shape.strokeBorder(Color.white.opacity(c.dark ? 0.14 : 0), lineWidth: 0.5))
        .clipShape(shape)
        .shadow(color: .black.opacity(c.dark ? 0.45 : 0.25), radius: 16, y: 6)
        .scaleEffect(c.reduceMotion ? 1 : 0.94 + 0.06 * rise, anchor: .top)
        .offset(x: r.minX, y: r.minY - (c.reduceMotion ? 0 : (1 - rise) * 4))
        .opacity(m["on"])
    }
}
