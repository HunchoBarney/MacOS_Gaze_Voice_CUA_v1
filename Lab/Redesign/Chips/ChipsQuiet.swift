import Orb
import SwiftUI

/// C. Quiet chips: crisp opaque pills with a hairline and a tinted number,
/// and the Lens marble, still, at the radial's centre. A pick tints the
/// chosen chip's outline and swaps its number for a green check. No light.
@MainActor
public enum ChipsQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Quiet", axis: "System-crisp: hairline pills, a still marble, a check",
        pitch: "Wins if chips should read like macOS's own labels: precise, legible on any window and gone the moment you choose.",
        cost: "Light pills disappear into a white window more easily than black ones; the hairline and shadow do the separating.",
        libraries: [Lib.orb, Lib.swiftUISpring],
        custom: "The chip face and the outline tint on the pick; the marble is metasidd Orb held still.",
        skills: [SkillNote("remove-animations", "No ripple and no bounce: chips appear together and fade; the marble's swirl is stopped, because a choice you are reading shouldn't move."),
                 SkillNote("emil-design-eng", "One accent (the number tint), one stroke weight, opaque fills; the check is the only new colour, and only on the pick."),
                 SkillNote("apple-design", "Pills follow macOS label metrics: 12.5 pt medium names, 24 pt height, continuous capsule, a 1 pt hairline instead of a glow."),
                 SkillNote("animate", "The gather is a critically damped 0.36 s spring; the check draws in 0.3 s with Emil's ease-out after the outline tints."),
                 SkillNote("break-ui", "TC-1: names stop at 160 pt with a tail ellipsis; a colliding name hangs under its control instead of covering Format."),
                 SkillNote("choreograph", "On the pick the others leave at once (0.14 s) while the outline tints, then the check draws: cause, then effect.")],
        alwaysOn: false)

    public static func update(_ f: ChipsFixture, _ c: Ctx, _ m: MotionBank) {
        ChipsMotion.update(f, c, m, .init(move: .spring(response: 0.36, damping: 1), appear: .easeOut(0.2), ripple: 0))
    }

    public static func body(_ f: ChipsFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let gaze = ChipsScript.gaze
        let dim = 1 - 0.6 * m["dim"]
        return ZStack(alignment: .topLeading) {
            if m["hub"] > 0.002 {
                OrbView(configuration: OrbConfiguration(backgroundColors: [Color(red: 0.55, green: 0.35, blue: 1), ChipFace.quietTint, .cyan],
                                                        glowColor: .white, coreGlowIntensity: 0.9,
                                                        showParticles: false, showShadow: false, speed: 0))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .opacity(m["hub"] * dim)
                    .offset(x: gaze.x - 7, y: gaze.y - 7)
            }
            ForEach(ChipsScript.targets.indices, id: \.self) { i in
                if m["on\(i)"] > 0.002 {
                    let on = m["on\(i)"].clamped(0, 1)
                    let w = m["w\(i)"]
                    let chosen = f.phase == .pick && i == 0
                    ChipFace(skin: .quiet, number: i + 1, name: ChipsScript.targets[i].name, width: w,
                             showNumber: m["num\(i)"], showName: m["name\(i)"],
                             picked: chosen ? m["pick"] : 0, check: chosen ? m["check"] : 0,
                             dark: c.dark, reduceTransparency: c.reduceTransparency, scale: m.value("scale", 1))
                        .opacity(on * (chosen ? 1 : dim))
                        .offset(x: m["x\(i)"] - w / 2, y: m["y\(i)"] - ChipsScript.height * m.value("scale", 1) / 2)
                }
            }
            if m["say"] > 0.002 {
                ChipsMotion.sayCaption(m, c, fill: c.dark ? Color(white: 0.15) : .white, ink: c.dark ? .white : .black.opacity(0.85))
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}
