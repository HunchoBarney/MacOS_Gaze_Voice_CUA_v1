import BorderBeamKit
import SwiftUI
import ThinkingOrbsKit

/// A. Beam: a small thinking orb rides your gaze; when it settles on a
/// control it pours into it and becomes a beam of light running the
/// control's border, the same orb Jarvis wears in the island.
@MainActor
public enum GazeBeam: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Beam", axis: "One object: the orb becomes the highlight",
        pitch: "Wins if the gaze and the voice island should read as one family: the orb in the notch is the orb on the screen.",
        cost: "A moving light around a control is the busiest of the three; it has to stay dim enough to read the label under it.",
        libraries: [Lib.thinkingOrbs, Lib.borderBeam, Lib.swiftUISpring],
        custom: "The rect morph from orb to control (four springs) and the 10 Hz to 60 fps glide.",
        skills: [SkillNote("apple-design", "Pointer magnetism from iPadOS: the mark snaps to the whole control and morphs to its shape, never a circle on a rectangle."),
                 SkillNote("animate", "Critically damped glide for tracking (no bounce on a surface that moves all the time); a 0.86 damped spring only for the morph onto a control."),
                 SkillNote("gestures", "Track versus settle: the orb tracks the eye 1:1 through a spring; the highlight settles and carries velocity into the next control."),
                 SkillNote("choreograph", "The orb shrinks into the control as the beam fades up on the same spring, so it reads as one object pouring in."),
                 SkillNote("remove-animations", "No idle pulse and no trail: gaze is the highest-frequency surface Jarvis has.")],
        alwaysOn: true)

    public static func update(_ f: GazeFixture, _ c: Ctx, _ m: MotionBank) {
        GazeMotion.follow(f, c, m)
        GazeMotion.rect(f, c, m, orb: 16, spec: .spring(response: 0.34, damping: 0.86))
        m.set("on", f.phase == .off ? 0 : 1, c.fade(.easeOut(f.phase == .off ? 0.3 : 0.2)))
        m.set("lock", f.target == nil ? 0 : 1, c.fade(.spring(response: 0.3, damping: 1)))
        m.set("dim", f.phase == .lost ? 1 : 0, c.fade(.easeOut(0.5)))
    }

    public static func body(_ f: GazeFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let lock = m["lock"].clamped(0, 1)
        let r = GazeMotion.frame(m, outset: 3)
        let on = m["on"] * (1 - m["dim"] * 0.65)
        return ZStack(alignment: .topLeading) {
            if lock > 0.01 {
                BorderBeam(size: .sm, colorVariant: .colorful, theme: c.dark ? .dark : .light,
                           staticColors: c.reduceMotion, borderRadius: m["hr"] + 3, strength: lock) {
                    RoundedRectangle(cornerRadius: m["hr"] + 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.07 * lock))
                        .overlay(RoundedRectangle(cornerRadius: m["hr"] + 3, style: .continuous)
                            .strokeBorder((c.dark ? Color.white : Color.black).opacity(0.22 * lock), lineWidth: 1))
                        .frame(width: r.width, height: r.height)
                }
                .environment(\.beamFrozenTime, c.reduceMotion ? 0 : c.t)
                .offset(x: r.minX, y: r.minY)
                .opacity(on)
            }
            if on * (1 - lock) > 0.002 {
            ZStack {
                Circle().fill(Color.black.opacity(c.dark ? 0.45 : 0.22)).frame(width: 26, height: 26).blur(radius: 5)
                ThinkingOrb(state: f.phase == .seeking ? .searching : .listening, size: .px20,
                            theme: .dark, paused: c.reduceMotion, displaySize: 18)
                    .frame(width: 18, height: 18)
            }
            .scaleEffect(1 - lock * 0.7)
            .opacity(on * (1 - lock))
            .offset(x: m["gx"] - 13, y: m["gy"] - 13)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}
