import SwiftUI
import ThinkingOrbsKit
import VoiceRingKit

/// A. Island: the window carries a small black island that tells you what
/// Jarvis is doing on each step: off, waiting for you with the thinking orb,
/// on with a check, listening with the voice ring. It morphs between them
/// the way the island under the notch does, so first run teaches the island.
@MainActor
public enum FirstRunIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island", axis: "A live island in the window shows each step's state",
        pitch: "Wins with the Island voice surface: the first thing you meet is the black island you'll see under the notch every day, waiting with its orb while you flip a switch (FR-1), checking off when it flips, and listening with its ring when you try your first request.",
        cost: "A black object in a light window is a strong accent on a page that is otherwise native, and the orb loops for as long as you take in System Settings.",
        libraries: [Lib.thinkingOrbs, Lib.voiceRing, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The island's per-step contents and width morph, and the shared window: chrome, the words' cross-fade and the one radius scale.",
        skills: [SkillNote("find-animation-opportunities", "FR-1: 'Waiting for you to switch it on' now has a sign of life, the island's searching orb, and resolves into a check when the permission flips; the page then moves on by itself."),
                 SkillNote("choreograph", "On a step change the island morphs first (0.42 s spring at 0.78), the old words leave in 0.12 s and the new ones rise in over 0.26 s; buttons cross-fade in place and never move."),
                 SkillNote("apple-design", "FR-2: one radius scale for every Jarvis window (window 16, tiles 14, controls are capsules), continuous corners throughout; the title is tracked tighter as it grows."),
                 SkillNote("animate", "First run is a rare surface, so it gets the delight budget: the island's small overshoot and a 6 pt rise on the words. The check draws over 0.4 s after a 0.16 s beat."),
                 SkillNote("emil-design-eng", "The default button is the island's ink capsule (black in light, white in dark), one per page, with return; the secondary is a quiet grey capsule."),
                 SkillNote("gestures", "return is always the primary and esc Not now; nothing waits for an animation before it takes a click."),
                 SkillNote("break-ui", "Largest labels (2x): the window widens to 760 pt and measures the tallest step's words, so buttons and text never clip; the island grows with its label."),
                 SkillNote("prototype", "Three answers to FR-1 side by side: a live object (A), light on the thing that's waiting (B), and the system's own spinner (C).")],
        alwaysOn: true)

    static let style = SetupWindow.Style(key: "A", centered: false, statusRow: false, ink: true, heroHeight: { 34 * $0 + 8 })

    static func label(_ f: SetupFixture) -> String {
        switch (f.step, f.status) {
        case (.microphone, .refused): return "Jarvis can't hear you"
        case (.microphone, .waiting), (.accessibility, .waiting): return "Waiting for you"
        case (.microphone, _): return "Microphone is off"
        case (.accessibility, .granted): return "Accessibility is on"
        case (.accessibility, _): return "Accessibility is off"
        case (.tryIt, .done): return "Opened Calculator"
        case (.tryIt, _): return "Listening"
        }
    }

    static func islandWidth(_ f: SetupFixture) -> CGFloat {
        let k = f.labelScale
        return 10 * k + 22 * k + 8 * k + TextMetrics.width(label(f), size: 13 * k, weight: .semibold) + 16 * k
    }

    public static func update(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) {
        SetupWindow.update(f, c, m, style)
        m.set("fa.w", islandWidth(f), c.geo(.spring(response: 0.42, damping: 0.78)))
        let before = SetupScript.fixture(of: c.previous).map(SetupScript.heroKey)
        for sample in SetupScript.samples {
            let key = SetupScript.heroKey(sample)
            let on = key == SetupScript.heroKey(f) && (c.reduceMotion || c.previous == nil || before == key || c.local > 0.08)
            m.set("fa." + key, on ? 1 : 0, on ? c.fade(.easeOut(0.22)) : c.fade(.easeOut(0.1)))
        }
        m.set("fa.level", f.status == .listening ? f.level : 0, .spring(response: 0.12, damping: 1))
    }

    public static func body(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        SetupWindow.body(f, c, m, style, hero: island(f, c, m)) { _ in EmptyView() }
    }

    static func island(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let k = f.labelScale
        return ZStack(alignment: .leading) {
            ForEach(SetupScript.samples.indices, id: \.self) { i in
                let sample = scaled(SetupScript.samples[i], k)
                let p = m["fa." + SetupScript.heroKey(sample)].clamped(0, 1)
                if p > 0.005 {
                    HStack(spacing: 8 * k) {
                        glyph(sample, c, m).frame(width: 22 * k, height: 22 * k)
                        Text(label(sample)).font(.system(size: 13 * k, weight: .semibold)).foregroundStyle(.white).fixedSize()
                    }
                    .padding(.leading, 10 * k)
                    .modifier(SymbolIn(p: p, reduceMotion: c.reduceMotion))
                }
            }
        }
        .frame(width: m["fa.w"], height: 34 * k, alignment: .leading)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(c.dark ? 0.14 : 0), lineWidth: 0.5))
        .clipShape(Capsule())
        .environment(\.colorScheme, .dark)
    }

    static func scaled(_ f: SetupFixture, _ k: Double) -> SetupFixture {
        var s = f
        s.labelScale = k
        return s
    }

    @ViewBuilder
    static func glyph(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let k = f.labelScale
        switch (f.step, f.status) {
        case (_, .waiting):
            ThinkingOrb(state: .searching, size: .px20, theme: .dark, paused: c.reduceMotion, displaySize: 20 * k)
        case (.microphone, .refused):
            Circle().fill(ShellAccent.amber).frame(width: 8 * k, height: 8 * k)
        case (_, .granted), (_, .done):
            Check(progress: c.reduceMotion ? 1 : m["fr.check"], color: ShellAccent.green, lineWidth: 2.2 * k).frame(width: 15 * k, height: 15 * k)
        case (.tryIt, _):
            VoiceRing(.ring, state: .listening, source: .level({ m["fa.level"] }), style: .ring(paused: c.reduceMotion), size: 20 * k)
        case (.microphone, _):
            Image(systemName: "mic.fill").font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
        case (.accessibility, _):
            Image(systemName: "accessibility").font(.system(size: 13 * k, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
        }
    }
}
