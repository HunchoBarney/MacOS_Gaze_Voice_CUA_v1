import SwiftUI
import ThinkingOrbsKit
import VoiceRingKit

/// A. Island: the notch grows into a black island and every state lives
/// inside it, morphing with one interruptible spring (the Dynamic Island,
/// taken literally). The ears beside the camera hold the thinking orb and
/// the voice ring; words and cards drop below the camera line.
@MainActor
public enum VoiceIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island", axis: "One container that holds everything and morphs",
        pitch: "Wins if Jarvis should feel like part of the Mac's hardware, like the iPhone's Dynamic Island.",
        cost: "The biggest surface of the three: a card under the notch covers part of the menu bar area while asking.",
        libraries: [Lib.thinkingOrbs, Lib.voiceRing, Lib.dynamicNotchKit, Lib.swiftUISpring],
        custom: "The island silhouette (DynamicNotchKit's notch geometry, redrawn so it can morph), word focus-in and the shimmer label.",
        skills: [SkillNote("apple-design", "Island grows from the notch's own outline; springs carry velocity when you interrupt (say 'stop' mid-morph)."),
                 SkillNote("choreograph", "Shape leads, content follows ~90 ms later; old content leaves before new arrives when both width and height change."),
                 SkillNote("animate", "Expand spring response 0.48 / damping 0.74 (alive), collapse 0.36 / 0.9 (no bounce on the way home)."),
                 SkillNote("emil-design-eng", "Black island with white type and key hints instead of stock buttons; nothing scales from zero."),
                 SkillNote("remove-animations", "No level bars: the voice ring absorbs the 20 Hz level so nothing jitters.")],
        alwaysOn: true)

    static let ear: CGFloat = 62
    static var compact: CGFloat { Desk.notch.width + ear * 2 }

    struct Shape { var w: CGFloat; var h: CGFloat; var r: CGFloat; var shoulder: CGFloat }

    static func shape(_ f: VoiceFixture) -> Shape {
        let row = Desk.menuBar
        switch f.phase {
        case .idle: return Shape(w: Desk.notch.width, h: row, r: Desk.notchRadius, shoulder: 6)
        case .listening, .done: return Shape(w: compact, h: row, r: 16, shoulder: 8)
        case .hearing:
            let text = TextMetrics.width(f.transcript, size: 17, weight: .medium)
            return Shape(w: min(640, max(compact, text + 96)), h: row + 46, r: 26, shoulder: 10)
        case .working:
            let text = TextMetrics.width(f.label, size: 15, weight: .medium)
            return Shape(w: max(compact, text + 120), h: row + 40, r: 24, shoulder: 10)
        case .asking: return Shape(w: 452, h: row + 128, r: 38, shoulder: 12)
        case .problem: return Shape(w: 452, h: row + 96, r: 34, shoulder: 12)
        }
    }

    public static func update(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank) {
        let s = shape(f)
        let growing = s.w * s.h >= m.value("w", s.w) * m.value("h", s.h)
        let spring: MotionSpec = growing ? .spring(response: 0.48, damping: 0.74) : .spring(response: 0.36, damping: 0.9)
        m.set("w", s.w, c.geo(spring))
        m.set("h", s.h, c.geo(spring))
        m.set("r", s.r, c.geo(spring))
        m.set("sh", s.shoulder, c.geo(spring))
        for phase in [VoiceFixture.Phase.listening, .hearing, .working, .asking, .done, .problem] {
            let on = f.phase == phase && c.local > (c.reduceMotion ? 0 : 0.09)
            m.set("c." + phase.rawValue, on ? 1 : 0, on ? c.fade(.easeOut(0.24)) : c.fade(.easeOut(0.12)))
        }
        let ears = [.listening, .hearing, .working, .done].contains(f.phase) && c.local > (c.reduceMotion ? 0 : 0.06)
        m.set("ears", ears ? 1 : 0, ears ? c.fade(.easeOut(0.22)) : c.fade(.easeOut(0.12)))
        m.set("level", f.level, .spring(response: 0.12, damping: 1))
        m.set("check", f.phase == .done && c.local > 0.12 ? 1 : 0, c.reduceMotion ? .snap : .easeOut(0.32))
    }

    public static func body(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let w = m["w"], h = m["h"]
        let x = Desk.size.width / 2 - w / 2
        return ZStack(alignment: .top) {
            NotchSilhouette(width: w, height: h, ear: m["sh"], bottomRadius: m["r"])
                .fill(Color.black)
                .frame(width: w + 40, height: h)
                .shadow(color: .black.opacity(h > 40 ? 0.35 : 0), radius: 18, y: 8)
            ears(f, c, m, w: w)
            rows(f, c, m, w: w, h: h)
        }
        .frame(width: w + 40, height: max(h, Desk.menuBar), alignment: .top)
        .offset(x: x - 20)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    static func ears(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank, w: CGFloat) -> some View {
        let o = m["ears"]
        let orbState: OrbState = f.phase == .working ? .working : .listening
        HStack(spacing: 0) {
            ThinkingOrb(state: orbState, size: .px20, theme: .dark, paused: c.reduceMotion)
                .frame(width: 20, height: 20)
                .frame(width: ear, height: Desk.menuBar)
                .opacity(f.phase == .done ? 0 : 1)
            Spacer(minLength: Desk.notch.width)
            ZStack {
                if f.phase == .working {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.16), in: Circle())
                } else if f.phase == .done {
                    HStack(spacing: 5) {
                        Check(progress: m["check"], color: Color(red: 0.35, green: 0.9, blue: 0.5), lineWidth: 2.2)
                            .frame(width: 14, height: 14)
                        Text("Sent").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .opacity(m["check"])
                    }
                } else {
                    VoiceRing(.ring, state: f.phase == .idle ? .idle : .listening, source: .level({ m["level"] }), size: 22)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: ear, height: Desk.menuBar)
        }
        .frame(width: max(w, compact), height: Desk.menuBar)
        .frame(width: w, height: Desk.menuBar)
        .clipped()
        .opacity(o)
    }

    @ViewBuilder
    static func rows(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank, w: CGFloat, h: CGFloat) -> some View {
        let top = Desk.menuBar
        ZStack(alignment: .top) {
            let hearing = m["c.hearing"]
            if hearing > 0.005 {
                WordStream(words: f.words, size: 17, color: .white, maxWidth: max(0, w - 48), reduceMotion: c.reduceMotion)
                    .frame(width: w - 40, height: 46)
                    .opacity(hearing)
                    .blur(radius: (1 - hearing) * 4)
            }
            let working = m["c.working"]
            if working > 0.005 {
                ShimmerText(text: f.label.isEmpty ? "Working" : f.label, size: 15, t: c.t,
                            base: .white.opacity(0.62), highlight: .white, reduceMotion: c.reduceMotion)
                    .frame(width: w - 40, height: 40)
                    .opacity(working)
                    .blur(radius: (1 - working) * 4)
            }
            let asking = m["c.asking"]
            if asking > 0.005 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(f.question).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Text("\u{201C}" + f.detail + "\u{201D}").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        IslandButton(title: f.options.first ?? "", key: "\u{23CE}", primary: true)
                        IslandButton(title: f.options.dropFirst().first ?? "", key: "esc", primary: false)
                    }
                    .padding(.top, 12)
                }
                .frame(width: 452 - 56, alignment: .leading)
                .padding(.top, 18)
                .opacity(asking)
                .blur(radius: (1 - asking) * 6)
                .scaleEffect(c.reduceMotion ? 1 : 0.96 + 0.04 * asking, anchor: .top)
            }
            let problem = m["c.problem"]
            if problem > 0.005 {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(Color(red: 1, green: 0.62, blue: 0.24), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.problemTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        Text(f.problemDetail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                        IslandButton(title: f.problemAction, key: nil, primary: false).padding(.top, 8)
                    }
                }
                .frame(width: 452 - 56, alignment: .leading)
                .padding(.top, 16)
                .opacity(problem)
                .blur(radius: (1 - problem) * 6)
                .scaleEffect(c.reduceMotion ? 1 : 0.96 + 0.04 * problem, anchor: .top)
            }
        }
        .frame(width: w, height: max(0, h - top), alignment: .top)
        .clipped()
        .offset(y: top)
    }
}

struct IslandButton: View {
    var title: String
    var key: String?
    var primary: Bool
    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            if let key {
                Text(key).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .opacity(0.5)
            }
        }
        .foregroundStyle(primary ? Color.black : Color.white)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(primary ? Color.white : Color.white.opacity(0.14), in: Capsule())
    }
}
