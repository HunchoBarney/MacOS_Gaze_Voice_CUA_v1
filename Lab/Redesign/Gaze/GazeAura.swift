import Aurora
import SwiftUI

/// B. Aura: Apple Intelligence light, the same glow as the voice surface.
/// While the tracker is unsure it is a soft ring as wide as its error; when
/// you settle on a control the ring tightens around it and flares once.
@MainActor
public enum GazeAura: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Aura", axis: "Honest: the light's size is the tracker's confidence",
        pitch: "Wins if you want to see how sure Jarvis is: a wide halo means guessing, a tight edge means it knows.",
        cost: "The Metal glow costs more GPU than a stroke, and a wide halo is more light on screen while the tracker is shaky.",
        libraries: [Lib.aurora, Lib.swiftUISpring],
        custom: "Sizing the ring from the tracker's sigma, and the lock-on flare timing.",
        skills: [SkillNote("apple-design", "The Siri edge light, scaled down to a control: one visual language for 'Jarvis is attending to this'."),
                 SkillNote("emil-design-eng", "The centre stays hollow, so the label under the light is never covered."),
                 SkillNote("animate", "Size follows confidence on a slow 0.5 s spring; position on a critically damped glide."),
                 SkillNote("find-animation-opportunities", "The one flare on lock-on is feedback that something changed; nothing else moves on its own."),
                 SkillNote("animation-performance", "One shader view; it is removed entirely when tracking is off.")],
        alwaysOn: true)

    public static func update(_ f: GazeFixture, _ c: Ctx, _ m: MotionBank) {
        GazeMotion.follow(f, c, m)
        m.set("disc", max(34, f.sigma * 1.1), c.geo(.spring(response: 0.5, damping: 1)))
        GazeMotion.rect(f, c, m, orb: m["disc"], spec: .spring(response: 0.36, damping: 0.9))
        m.set("on", f.phase == .off ? 0 : 1, c.fade(.easeOut(f.phase == .off ? 0.35 : 0.25)))
        let locked = f.target != nil
        if locked, m["lock"] < 0.02 { m.set("lockAt", c.t, .snap) }
        m.set("lock", locked ? 1 : 0, c.fade(.spring(response: 0.32, damping: 1)))
        m.set("dim", f.phase == .lost ? 1 : 0, c.fade(.easeOut(0.5)))
    }

    public static func body(_ f: GazeFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let lock = m["lock"].clamped(0, 1)
        let outset = 3.0
        let r = GazeMotion.frame(m, outset: outset)
        let on = m["on"] * (1 - m["dim"] * 0.7)
        return ZStack(alignment: .topLeading) {
            if m["on"] > 0.002 {
                AuroraEdge(size: r.size, radius: m["hr"] + outset, border: 2 + lock * 0.5, rim: 4 + (1 - lock) * 4,
                           bloom: 0.5 + 0.5 * lock,
                           times: AuroraGlow.Times(
                               elapsed: c.reduceMotion ? 0 : c.t,
                               burst: c.reduceMotion || lock < 0.02 ? -1 : c.t - m.value("lockAt", c.t)),
                           reduceTransparency: c.reduceTransparency)
                    .opacity(on * (0.6 + 0.4 * lock))
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}
