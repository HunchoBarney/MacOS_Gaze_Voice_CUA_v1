import Aurora
import SwiftUI

/// B. Aura chips: light glass pills whose numbers carry Apple Intelligence's
/// warm-cool colours. The radial stands on a ring of Siri light as wide as
/// the tracker's error, the same honesty as the Aura highlight; a pick flares
/// the light around the chosen chip and the ring dissolves.
@MainActor
public enum ChipsAura: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Aura", axis: "Light shows the uncertainty: chips stand on a ring of glow the size of the tracker's error",
        pitch: "Wins with the Aurora voice surface and the Aura highlight: when Jarvis isn't sure which one you mean, you see exactly how unsure, in the same light.",
        cost: "Two shaders while the radial waits (the ring, then the flare on the pick), and a 120 pt ring of light over the toolbar is the most on screen of the three.",
        libraries: [Lib.aurora, Lib.swiftUISpring],
        custom: "The glass chip face with its gradient number badge, sizing the ring from the error band, and the flare on the chosen chip (AuroraEdge).",
        skills: [SkillNote("apple-design", "Siri's light as the error band: the ring is the tracker's 60 pt sigma, and the chips sit on it, never inside it, so the controls under your gaze stay readable."),
                 SkillNote("choreograph", "The ring fades up as the chips arrive on it (one beat); on the pick the flare lands on the chosen chip as the others leave and the ring dissolves after them."),
                 SkillNote("animate", "Critically damped travel (0.5 s, damping 1) for the gather, since light shouldn't bounce; the badge's colours are static, so nothing shimmers on a surface you read."),
                 SkillNote("emil-design-eng", "Glass pills with a hairline, not a dark slab: they sit in the window's own light. The colour lives in an 18 pt badge, nowhere else."),
                 SkillNote("break-ui", "TC-1: names stop at 160 pt; Reduce Transparency makes the glass opaque so a name over a busy window stays legible."),
                 SkillNote("animation-performance", "The ring and the flare are the only shaders and exist only while the radial is up; numbers and names draw no light at all.")],
        alwaysOn: true)

    public static func update(_ f: ChipsFixture, _ c: Ctx, _ m: MotionBank) {
        ChipsMotion.update(f, c, m, .init(move: .spring(response: 0.5, damping: 1), appear: .easeOut(0.26), ripple: 1))
        let start = c.t - c.local
        if f.phase == .radial, c.previous != "lost" { m.set("ringAt", start, .snap) }
        if f.phase == .pick { m.set("flareAt", start, .snap) }
        let flare = f.phase == .pick && c.local < 1.1
        m.set("flare", flare ? 1 : 0, flare ? c.fade(.easeOut(0.14)) : c.fade(.easeOut(0.4)))
    }

    public static func body(_ f: ChipsFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let gaze = ChipsScript.gaze
        let r = m.value("band", ChipsScript.radius)
        let dim = 1 - 0.6 * m["dim"]
        let times = AuroraGlow.Times(elapsed: c.reduceMotion ? 0 : c.t,
                                     burst: c.reduceMotion ? -1 : c.t - m.value("ringAt", c.t - 10))
        return ZStack(alignment: .topLeading) {
            if m["hub"] > 0.002 {
                AuroraEdge(size: CGSize(width: r * 2, height: r * 2), radius: r, border: 2, rim: 6, bloom: 0.6,
                           times: times, reduceTransparency: c.reduceTransparency)
                    .opacity(m["hub"] * (1 - 0.75 * m["dim"]))
                    .offset(x: gaze.x - r, y: gaze.y - r)
            }
            if m["flare"] > 0.002 { flare(c, m) }
            ForEach(ChipsScript.targets.indices, id: \.self) { i in
                if m["on\(i)"] > 0.002 {
                    let on = m["on\(i)"].clamped(0, 1)
                    let w = m["w\(i)"]
                    let chosen = f.phase == .pick && i == 0
                    ChipFace(skin: .glass, number: i + 1, name: ChipsScript.targets[i].name, width: w,
                             showNumber: m["num\(i)"], showName: m["name\(i)"],
                             picked: 0, check: chosen ? m["check"] : 0,
                             dark: c.dark, reduceTransparency: c.reduceTransparency, scale: m.value("scale", 1))
                        .scaleEffect(ChipsMotion.scale(on, c))
                        .opacity(on * (chosen ? 1 : dim))
                        .offset(x: m["x\(i)"] - w / 2, y: m["y\(i)"] - ChipsScript.height * m.value("scale", 1) / 2)
                }
            }
            if m["say"] > 0.002 {
                ChipsMotion.sayCaption(m, c, fill: c.dark ? Color(white: 0.1).opacity(0.9) : Color.white.opacity(0.95),
                                       ink: c.dark ? .white : .black.opacity(0.85))
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func flare(_ c: Ctx, _ m: MotionBank) -> some View {
        let w = m["w0"] + 8
        let h = ChipsScript.height * m.value("scale", 1) + 8
        return AuroraEdge(size: CGSize(width: w, height: h), radius: h / 2, border: 2.5, rim: 5, bloom: 1,
                          times: AuroraGlow.Times(elapsed: c.reduceMotion ? 0 : c.t,
                                                  burst: c.reduceMotion ? -1 : c.t - m.value("flareAt", c.t)),
                          reduceTransparency: c.reduceTransparency)
            .opacity(m["flare"] * m["on0"].clamped(0, 1))
            .offset(x: m["x0"] - w / 2, y: m["y0"] - h / 2)
    }
}
