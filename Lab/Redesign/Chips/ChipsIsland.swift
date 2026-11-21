import BorderBeamKit
import SwiftUI
import ThinkingOrbsKit

/// A. Island chips: black capsules in the Dynamic Island's material, with the
/// island's thinking orb as the radial's hub. A pick turns the chosen chip
/// white, like the island's primary button, and runs the beam around it once.
@MainActor
public enum ChipsIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island", axis: "Pieces of the island: black chips, the orb at the hub, the beam on the pick",
        pitch: "Wins with the Island voice surface and the Beam highlight: every chip looks like a drop of the notch, and the orb you see in the island is the orb you look through.",
        cost: "Black chips are the heaviest marks on a light window, and the beam on the pick is one more moving light on top of the flash that follows.",
        libraries: [Lib.thinkingOrbs, Lib.borderBeam, Lib.swiftUISpring],
        custom: "The chip face (number cell and name that cross-fade), the layout rule that drops a colliding name under its control, and the gather from targets to the error band.",
        skills: [SkillNote("apple-design", "Chips keep their identity across states: a number opens into its name and the same chip flies to the radial, so you never re-read the screen. Springs carry velocity when you change your mind mid-gather."),
                 SkillNote("choreograph", "Chips ripple out from the gaze (distance / 5000 s, capped at 0.12 s), the cause of the request; the three radial chips gather while the other three leave at once; on a pick the others go first and the chosen chip holds."),
                 SkillNote("animate", "The gather is a 0.42 s spring at 0.8 damping (it travels up to 530 pt, so a little overshoot reads as arriving); entrances 0.34 s at 0.74 from scale 0.9, never zero; exits a 0.14 s ease-out."),
                 SkillNote("emil-design-eng", "The pick inverts the chip to white, the island's primary-button language, instead of a new colour."),
                 SkillNote("break-ui", "TC-1: names stop at 160 pt with a tail ellipsis, and a name that would cover its neighbour (Attach and Format are 38 pt apart) hangs under its control."),
                 SkillNote("gestures", "Chips are 24 pt tall dwell and click targets that never overlap, so a dwell pick can't land on the wrong one.")],
        alwaysOn: true)

    public static func update(_ f: ChipsFixture, _ c: Ctx, _ m: MotionBank) {
        ChipsMotion.update(f, c, m, .init(move: .spring(response: 0.42, damping: 0.8), appear: .spring(response: 0.34, damping: 0.74), ripple: 1))
        let beam = f.phase == .pick && c.local > 0.04 && c.local < 0.9
        m.set("beam", beam ? 1 : 0, c.fade(.spring(response: 0.3, damping: 1)))
        m.set("press", f.phase == .pick && c.local < 0.1 ? 1 : 0, c.geo(.spring(response: 0.24, damping: 0.6)))
    }

    public static func body(_ f: ChipsFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let gaze = ChipsScript.gaze
        let dim = 1 - 0.6 * m["dim"]
        return ZStack(alignment: .topLeading) {
            if m["hub"] > 0.002 {
                ZStack {
                    Circle().fill(Color.black.opacity(c.dark ? 0.5 : 0.28)).frame(width: 28, height: 28).blur(radius: 5)
                    ThinkingOrb(state: .searching, size: .px20, theme: .dark, paused: c.reduceMotion || f.phase == .lost, displaySize: 18)
                        .frame(width: 18, height: 18)
                }
                .opacity(m["hub"] * dim)
                .offset(x: gaze.x - 14, y: gaze.y - 14)
            }
            ForEach(ChipsScript.targets.indices, id: \.self) { i in
                if m["on\(i)"] > 0.002 { chip(i, f, c, m, dim: dim) }
            }
            if m["say"] > 0.002 {
                ChipsMotion.sayCaption(m, c, fill: .black.opacity(0.86), ink: .white)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    static func chip(_ i: Int, _ f: ChipsFixture, _ c: Ctx, _ m: MotionBank, dim: Double) -> some View {
        let on = m["on\(i)"].clamped(0, 1)
        let w = m["w\(i)"]
        let chosen = f.phase == .pick && i == 0
        let face = ChipFace(skin: .island, number: i + 1, name: ChipsScript.targets[i].name, width: w,
                            showNumber: m["num\(i)"], showName: m["name\(i)"],
                            picked: chosen ? m["pick"] : 0, check: chosen ? m["check"] : 0,
                            dark: c.dark, reduceTransparency: c.reduceTransparency, scale: m.value("scale", 1))
        Group {
            if chosen, m["beam"] > 0.01 {
                BorderBeam(size: .sm, colorVariant: .colorful, theme: .dark, staticColors: c.reduceMotion,
                           borderRadius: ChipsScript.height * m.value("scale", 1) / 2, strength: m["beam"].clamped(0, 1)) { face }
                    .environment(\.beamFrozenTime, c.reduceMotion ? 0 : c.t * 1.6)
            } else {
                face
            }
        }
        .scaleEffect(ChipsMotion.scale(on, c) * (1 - 0.06 * (chosen ? m["press"] : 0)))
        .opacity(on * (chosen ? 1 : dim))
        .offset(x: m["x\(i)"] - w / 2, y: m["y\(i)"] - ChipsScript.height * m.value("scale", 1) / 2)
    }
}
