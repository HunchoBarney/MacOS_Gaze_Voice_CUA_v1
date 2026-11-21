import Aurora
import SwiftUI

/// B. Aurora: the item is the system's own waveform glyph. Its bars light
/// with your voice and sweep while Jarvis works, and Siri's light runs the
/// item's edge only while Jarvis is live; a question waiting turns the
/// light warm and adds a count badge.
@MainActor
public enum ItemAurora: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Aurora", axis: "A template waveform that Siri's light rims only while Jarvis is live",
        pitch: "Wins with the Aurora voice surface: Jarvis looks like the system at rest, and when it listens the same Apple Intelligence light you see at the display's edge rims its item, so the bar tells you where Jarvis is without a word.",
        cost: "Shader light in the menu bar while Jarvis is live, the most GPU of the three; the glow has to stay inside the item's 22 pt, so it reads as a rim, not a halo.",
        libraries: [Lib.aurora, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "Mapping each state to the waveform's variable value (voice level, working sweep, dimmed when paused), the rim's level and palette, and the count badge.",
        skills: [SkillNote("apple-design", "SF Symbols' variable value is the platform's own level meter: bars fill with your voice, sweep left to right while Jarvis works (variableColor.iterative's rhythm) and dim to their secondary layer when paused."),
                 SkillNote("emil-design-eng", "MB-1: the count is a badge on the glyph's corner, inside a fixed 36 pt item; light only where Jarvis is live, never as decoration."),
                 SkillNote("animate", "The rim fades in over 0.3 s with one shader burst at the change, and out over 0.45 s; voice level drives it through a critically damped 0.14 s spring so it never jitters."),
                 SkillNote("choreograph", "Light leads (the burst on the frame the state changes), the glyph follows 60 ms later; the warm palette cross-fades rather than swapping."),
                 SkillNote("find-animation-opportunities", "The waveform's sweep is the working state's sign of life; standby, paused and no microphone are still."),
                 SkillNote("remove-animations", "No bloom outside the item and no idle shimmer: the light is off whenever Jarvis is at rest."),
                 SkillNote("break-ui", "Largest labels (2x): glyph, rim and badge grow to the 22 pt limit together; the tooltip carries the words. Reduce Transparency drops the bloom."),
                 SkillNote("animate-expo", "Principles only: the level is a spring that retargets every frame; opacity uses timing curves.")],
        alwaysOn: true)

    static func width(_ k: Double) -> CGFloat { 36 * StatusBar.scale(k) }

    public static func update(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) {
        m.set("i.glow", f.live ? 1 : 0, f.live ? c.fade(.easeOut(0.3)) : c.fade(.easeOut(0.45)))
        m.set("i.warm", f.phase == .asks ? 1 : 0, c.fade(.easeOut(0.3)))
        m.set("i.level", f.phase == .listening ? f.level : 0, .spring(response: 0.14, damping: 1))
        if f.live, c.previous != nil, ItemScript.phase(of: c.previous) != f.phase { m.set("i.burstAt", c.t - c.local, .snap) }
        ItemStage.phases(f, c, m)
        ItemStage.tip(f, c, m)
    }

    public static func body(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        ItemStage.place(glyph(f, c, m), width: width(f.labelScale), f, c, m)
    }

    static func glyph(_ f: ItemFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let s = StatusBar.scale(f.labelScale)
        let w = width(f.labelScale)
        let glow = m["i.glow"].clamped(0, 1), warm = m["i.warm"].clamped(0, 1), level = m["i.level"]
        let times = AuroraGlow.Times(elapsed: c.reduceMotion ? 0 : c.t,
                                     burst: c.reduceMotion ? -1 : c.t - m.value("i.burstAt", -10))
        return ZStack {
            if glow * (1 - warm) > 0.005 {
                rim(w, s, level, times, .appleIntelligence, c).opacity(glow * (1 - warm))
            }
            if glow * warm > 0.005 {
                rim(w, s, 0, times, .sunset, c).opacity(glow * warm)
            }
            ForEach(ItemFixture.Phase.allCases, id: \.rawValue) { p in
                let o = m["i." + p.rawValue]
                if o > 0.005 {
                    content(p, f, c, m, s).modifier(SymbolIn(p: o, reduceMotion: c.reduceMotion))
                }
            }
        }
        .frame(width: w, height: Desk.menuBar)
        .clipped()
    }

    static func rim(_ w: CGFloat, _ s: CGFloat, _ level: Double, _ times: AuroraGlow.Times, _ palette: AuroraGlow.Palette, _ c: Ctx) -> some View {
        AuroraEdge(size: CGSize(width: w - 4 * s, height: 22 * s), radius: 11 * s, border: 1.3 + level * 1.6,
                   rim: 3.5 + level * 4, bloom: 0, times: times, reduceTransparency: c.reduceTransparency, palette: palette)
    }

    @ViewBuilder
    static func content(_ p: ItemFixture.Phase, _ f: ItemFixture, _ c: Ctx, _ m: MotionBank, _ s: CGFloat) -> some View {
        let ink = StatusBar.ink(c)
        let font = Font.system(size: 14 * s, weight: .semibold)
        switch p {
        case .standby:
            Image(systemName: "waveform").font(font).foregroundStyle(ink)
        case .listening:
            Image(systemName: "waveform", variableValue: (0.2 + m["i.level"] * 1.6).clamped(0, 1)).font(font).foregroundStyle(ink)
        case .working:
            Image(systemName: "waveform", variableValue: c.reduceMotion ? 1 : (c.t / 1.1).truncatingRemainder(dividingBy: 1) * 1.15)
                .font(font).foregroundStyle(ink)
        case .asks:
            Image(systemName: "waveform").font(font).foregroundStyle(ink)
                .overlay(alignment: .topTrailing) {
                    Text(f.asks > 9 ? "9+" : "\(f.asks)")
                        .font(.system(size: 8 * s, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 11 * s, minHeight: 11 * s)
                        .background(Circle().fill(Color(red: 1, green: 0.45, blue: 0.15)))
                        .offset(x: 6 * s, y: -5 * s)
                }
        case .paused:
            Image(systemName: "waveform", variableValue: 0).font(font).foregroundStyle(ink)
        case .noMic:
            Image(systemName: "mic.slash").font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(ink)
        }
    }
}
