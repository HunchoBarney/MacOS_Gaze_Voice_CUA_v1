import SwiftUI
import ThinkingOrbsKit
import VoiceRingKit

/// A. Island card: every ask is the island grown into a card, with the
/// island's white and translucent capsules and their key hints (LI-5). While
/// Jarvis waits for a spoken answer the ears come back: the orb listens and
/// the ring follows your voice.
@MainActor
public enum AskIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island card", axis: "Asks are the island grown into a card",
        pitch: "Wins with the Island voice surface: the question appears exactly where Jarvis was listening, and changes shape without ever leaving the notch.",
        cost: "A 452 pt black card covers the menu bar's middle and the top of the front window for as long as Jarvis waits.",
        libraries: [Lib.thinkingOrbs, Lib.voiceRing, Lib.dynamicNotchKit, Lib.swiftUISpring],
        custom: "The four card layouts, the folder move row and the \u{201C}or say\u{201D} line; silhouette, ears and buttons are batch 1's Island parts.",
        skills: [SkillNote("emil-design-eng", "LI-5: stock blue prominent buttons become the island's white primary and translucent secondary capsules, each with its key (return, esc) and the phrase that does the same."),
                 SkillNote("apple-design", "One surface, many shapes: asks morph height on the voice surface's spring (0.48 / 0.74 growing, 0.36 / 0.9 shrinking), so moving from one ask to the next reads as the island answering."),
                 SkillNote("choreograph", "The shape leads; the old card's content leaves in 0.12 s and the new one focuses in 0.09 s later, scaling from 0.96 at the top edge, never from zero."),
                 SkillNote("find-animation-opportunities", "The ears return only for the open question: the listening orb and voice ring say it's your turn to talk, which a Cancel button alone can't."),
                 SkillNote("break-ui", "The heard words and the problem text wrap inside a fixed 396 pt column; the approval names its folders in tags so a long path can't push the buttons off."),
                 SkillNote("gestures", "30 pt capsules with return and esc mapped, so keyboard, pointer and voice all answer the same ask.")],
        alwaysOn: true)

    static func width(_ k: Double) -> CGFloat { min(452 * k, 820) }
    static func pad(_ k: Double) -> CGFloat { 28 * k }

    static func height(_ f: AskFixture, _ c: Ctx) -> CGFloat {
        let k = f.labelScale
        guard f.phase != .idle else { return Desk.menuBar }
        let inner = width(k) - pad(k) * 2
        let measured = Measure.size("askA-\(f.phase.rawValue)-\(k)", width: inner) { content(f.phase, c, k) }
        return Desk.menuBar + 16 * k + measured.height + 18 * k
    }

    public static func update(_ f: AskFixture, _ c: Ctx, _ m: MotionBank) {
        let idle = f.phase == .idle
        let w = idle ? Desk.notch.width : width(f.labelScale)
        let h = height(f, c)
        let growing = w * h >= m.value("w", w) * m.value("h", h)
        let spring: MotionSpec = growing ? .spring(response: 0.48, damping: 0.74) : .spring(response: 0.36, damping: 0.9)
        m.set("w", w, c.geo(spring))
        m.set("h", h, c.geo(spring))
        m.set("r", idle ? Desk.notchRadius : 36, c.geo(spring))
        m.set("sh", idle ? 6 : 12, c.geo(spring))
        AskMotion.content(f, c, m, delay: 0.09)
        let ears = f.phase == .question && c.local > (c.reduceMotion ? 0 : 0.06)
        m.set("ears", ears ? 1 : 0, ears ? c.fade(.easeOut(0.22)) : c.fade(.easeOut(0.12)))
        m.set("level", f.level, .spring(response: 0.12, damping: 1))
    }

    public static func body(_ f: AskFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let w = m["w"], h = m["h"]
        let k = f.labelScale
        return ZStack(alignment: .top) {
            NotchSilhouette(width: w, height: h, ear: m["sh"], bottomRadius: m["r"])
                .fill(Color.black)
                .frame(width: w + 40, height: h)
                .shadow(color: .black.opacity(h > 40 ? 0.35 : 0), radius: 18, y: 8)
            if m["ears"] > 0.002 {
                VoiceIsland.ears(VoiceFixture(phase: .listening, level: f.level), c, m, w: w)
            }
            ZStack(alignment: .top) {
                ForEach(AskMotion.phases, id: \.rawValue) { phase in
                    let p = m["c." + phase.rawValue].clamped(0, 1)
                    if p > 0.005 {
                        content(phase, c, k)
                            .frame(width: width(k) - pad(k) * 2, alignment: .leading)
                            .padding(.top, 16 * k)
                            .modifier(AskFocus(p: p))
                    }
                }
            }
            .frame(width: w, height: max(0, h - Desk.menuBar), alignment: .top)
            .clipped()
            .offset(y: Desk.menuBar)
        }
        .frame(width: w + 40, height: max(h, Desk.menuBar), alignment: .top)
        .offset(x: Desk.size.width / 2 - w / 2 - 20)
        .environment(\.colorScheme, .dark)
        .environment(\.reduceMotionForAsks, c.reduceMotion)
    }

    static func buttons(_ phase: AskFixture.Phase, _ k: Double) -> some View {
        let a = AskScript.actions(phase)
        return AnswerRow(say: a.say, color: .white.opacity(0.4), scale: k) {
            if let primary = a.primary { IslandButton(title: primary, key: "\u{23CE}", primary: true, scale: k) }
            IslandButton(title: a.secondary, key: "esc", primary: false, scale: k)
        }
    }

    @ViewBuilder
    static func content(_ phase: AskFixture.Phase, _ c: Ctx, _ k: Double) -> some View {
        let title = Font.system(size: 17 * k, weight: .semibold)
        switch phase {
        case .idle:
            EmptyView()
        case .review:
            VStack(alignment: .leading, spacing: 6 * k) {
                Text("Check what I heard").font(.system(size: 12.5 * k, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Text("\u{201C}" + AskScript.heard + "\u{201D}").font(title).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(.review, k).padding(.top, 12 * k)
            }
        case .question:
            VStack(alignment: .leading, spacing: 10 * k) {
                Text(AskScript.question).font(title).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    ShimmerText(text: "Listening for your answer", size: 14 * k, t: c.t, base: .white.opacity(0.5), highlight: .white,
                                reduceMotion: c.reduceMotion)
                    Spacer(minLength: 8 * k)
                    IslandButton(title: "Cancel", key: "esc", primary: false, scale: k)
                }
            }
        case .approval:
            VStack(alignment: .leading, spacing: 10 * k) {
                Text(AskScript.approval).font(title).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                MoveRow(ink: .white, sub: .white.opacity(0.45), fill: .white.opacity(0.09), scale: k)
                buttons(.approval, k).padding(.top, 2 * k)
            }
        case .problem:
            HStack(alignment: .top, spacing: 12 * k) {
                Image(systemName: "exclamationmark").font(.system(size: 13 * k, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 24 * k, height: 24 * k)
                    .background(Color(red: 1, green: 0.62, blue: 0.24), in: Circle())
                VStack(alignment: .leading, spacing: 4 * k) {
                    Text(AskScript.problemTitle).font(.system(size: 16 * k, weight: .semibold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AskScript.problemDetail).font(.system(size: 13 * k)).foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                    buttons(.problem, k).padding(.top, 8 * k)
                }
            }
        }
    }
}

/// Content arriving in a card: opacity, a little blur and a 0.96 to 1 scale
/// from the top edge; under Reduce Motion only the opacity.
struct AskFocus: ViewModifier {
    var p: Double
    @Environment(\.reduceMotionForAsks) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(p)
            .blur(radius: reduceMotion ? 0 : (1 - p) * 6)
            .scaleEffect(reduceMotion ? 1 : 0.96 + 0.04 * p, anchor: .top)
    }
}

extension EnvironmentValues {
    @Entry var reduceMotionForAsks = false
}
