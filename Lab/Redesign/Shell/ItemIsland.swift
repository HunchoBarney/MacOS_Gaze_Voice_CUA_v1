import SwiftUI
import ThinkingOrbsKit

/// A. Island: the item is a tiny island. At rest it is an outlined capsule,
/// a template glyph like its neighbours; when Jarvis is live it fills black
/// with a small bounce and carries the island's own orb, or the count of
/// questions waiting, inside the same width.
@MainActor
public enum ItemIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island", axis: "The item is a tiny island that fills when Jarvis is live",
        pitch: "Wins with the Island voice surface: the same black capsule and orb you see under the notch, shrunk to the menu bar, so the item reads as Jarvis at a glance and fills only while it is listening, working or waiting for you.",
        cost: "A solid black capsule is louder than a template glyph; it is the one non-template item in the bar while Jarvis is live. The orb is 13 pt, so its lattice reads as texture rather than detail.",
        libraries: [Lib.thinkingOrbs, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The capsule outline and fill, the count slot and the per-state glyph cross-fade; the orb is ThinkingOrbsKit at displaySize 13.",
        skills: [SkillNote("apple-design", "MB-1: the count of questions waiting sits inside a fixed 36 pt item next to an amber dot, so the icons to the left never shift; at rest the capsule is a template outline that matches the system's weight."),
                 SkillNote("animate", "Becoming live is a 0.36 s spring at 0.62 damping from 80% scale (the island's bounce, about 4% overshoot); going back to rest is critically damped, because calm shouldn't wobble."),
                 SkillNote("choreograph", "Fill leads, then the glyph: the old glyph leaves in 0.1 s and the new one arrives 60 ms later with SF Symbols' replace shape (70% scale, 2 pt blur)."),
                 SkillNote("find-animation-opportunities", "The only loop is the orb, and only while Jarvis listens or works: it is the sign of life the audit asked for, and the item is still at rest."),
                 SkillNote("remove-animations", "Paused, no microphone and standby are static template glyphs: the menu bar is a surface you see all day."),
                 SkillNote("emil-design-eng", "Nothing appears from zero: the fill grows from 80%, the glyphs from 70%."),
                 SkillNote("break-ui", "Largest labels (2x): the capsule grows to the 22 pt a status item may use, and the tooltip naming the state doubles; a count past 9 shows 9+ in the same slot."),
                 SkillNote("animate-expo", "Principles only: spring for the shape (interruptible, keeps velocity), timing for opacity, everything retargets from the current value.")],
        alwaysOn: true)

    static func box(_ k: Double) -> CGSize {
        let s = StatusBar.scale(k)
        return CGSize(width: 28 * s, height: 16 * s)
    }

    static func width(_ k: Double) -> CGFloat { box(k).width + 8 * StatusBar.scale(k) }

    public static func update(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) {
        m.set("i.fill", f.live ? 1 : 0, c.geo(f.live ? .spring(response: 0.36, damping: 0.62) : .spring(response: 0.3, damping: 1)))
        m.set("i.fillO", f.live ? 1 : 0, c.fade(.easeOut(f.live ? 0.14 : 0.2)))
        ItemStage.phases(f, c, m)
        ItemStage.tip(f, c, m)
    }

    public static func body(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        ItemStage.place(glyph(f, c, m), width: width(f.labelScale), f, c, m)
    }

    static func glyph(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let s = StatusBar.scale(f.labelScale)
        let b = box(f.labelScale)
        let ink = StatusBar.ink(c)
        let fill = m["i.fill"], fo = m["i.fillO"].clamped(0, 1)
        return ZStack {
            if fo < 0.995 {
                Capsule().strokeBorder(ink, lineWidth: 1.4 * s)
                    .frame(width: b.width, height: b.height)
                    .opacity(1 - fo)
            }
            if fo > 0.005 {
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(c.dark ? 0.3 : 0), lineWidth: 0.5))
                    .frame(width: b.width, height: b.height)
                    .scaleEffect(0.8 + 0.2 * fill)
                    .opacity(fo)
            }
            ForEach(ItemFixture.Phase.allCases, id: \.rawValue) { p in
                let o = m["i." + p.rawValue]
                if o > 0.005 {
                    content(p, f, c, s, ink: ink).modifier(SymbolIn(p: o, reduceMotion: c.reduceMotion))
                }
            }
        }
        .frame(width: width(f.labelScale), height: Desk.menuBar)
    }

    @ViewBuilder
    static func content(_ p: ItemFixture.Phase, _ f: ItemFixture, _ c: Ctx, _ s: CGFloat, ink: Color) -> some View {
        switch p {
        case .standby:
            Circle().fill(ink).frame(width: 5 * s, height: 5 * s)
        case .paused:
            HStack(spacing: 2.5 * s) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1 * s).fill(ink).frame(width: 2.2 * s, height: 7 * s)
                }
            }
        case .noMic:
            Image(systemName: "mic.slash.fill").font(.system(size: 8.5 * s, weight: .semibold)).foregroundStyle(ink)
        case .listening:
            ThinkingOrb(state: .listening, size: .px20, theme: .dark, paused: c.reduceMotion, displaySize: 13 * s)
                .frame(width: 13 * s, height: 13 * s)
        case .working:
            ThinkingOrb(state: .working, size: .px20, theme: .dark, paused: c.reduceMotion, displaySize: 13 * s)
                .frame(width: 13 * s, height: 13 * s)
        case .asks:
            HStack(spacing: 3 * s) {
                Circle().fill(ShellAccent.amber).frame(width: 6 * s, height: 6 * s)
                Text(f.asks > 9 ? "9+" : "\(f.asks)")
                    .font(.system(size: 10.5 * s, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
    }
}
