import Aurora
import SwiftUI

/// B. Glow: Apple Intelligence light marks where agents work. Chips sit on
/// a glass-like shelf with a lit colour dot; a pointer carries a soft glow in
/// its agent's colour, the control it works on glows with the Siri edge light,
/// and an agent that needs you turns its chip and control warm.
@MainActor
public enum AgentAurora: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Glow", axis: "Light where agents work: cool while working, warm when they need you",
        pitch: "Wins with the Aurora voice surface and the Aura gaze highlight: an agent's work is the same Apple Intelligence light, and 'needs you' is the warm end of it.",
        cost: "One shader per busy control (two agents, two glows) and the most light on screen; translucent chips need Reduce Transparency's solid fallback.",
        libraries: [Lib.aurora, Lib.swiftUISpring],
        custom: "The shelf stack and pointer (shared with A and C), the glass chips and the mapping of working and needs-you to the shader's palette and burst.",
        skills: [SkillNote("apple-design", "Materials: chips are a lighter-weight translucent layer than the windows under them and materialise (blur to sharp) instead of just fading; under Reduce Transparency they go solid. 12 pt labels fix AC-1 and AS-1."),
                 SkillNote("animate", "The glow lands on a 0.3 s critically damped spring with one shader burst when the pointer arrives; pointer travel is two critically damped springs so long moves arc."),
                 SkillNote("choreograph", "Chip, then pointer 220 ms later, then the glow when it lands: cause before effect. On needs-you the chip's glow and the control's glow burst on the same frame."),
                 SkillNote("find-animation-opportunities", "The one new motion is the arrival burst: feedback that the agent touched the control. Nothing loops in the shelf."),
                 SkillNote("animation-performance", "Each glow view exists only while its agent works a control; idle agents and the empty shelf draw nothing.")],
        alwaysOn: true)

    static func size(_ a: AgentFixture.Agent, _ k: Double) -> CGSize {
        if a.status == .asking {
            let q = TextMetrics.width(a.question ?? "", size: 12 * k, weight: .regular)
            return CGSize(width: min(Desk.size.width - 330, max(270 * k, q + 56 * k)), height: 52 * k)
        }
        return CGSize(width: 12 * k + 8 * k + 8 * k + AgentMotion.textWidth(a, k) + 12 * k, height: 28 * k)
    }

    static func flagText(_ a: AgentFixture.Agent?) -> String {
        guard let a, a.status != .done else { return "Done" }
        return a.status == .asking ? "Needs you" : a.action
    }

    static func flagWidth(_ a: AgentFixture.Agent, _ k: Double) -> CGFloat {
        let base = 9 * k + 7 * k + 6 * k + TextMetrics.width(AgentRoster.entry(a.id).name, size: 12 * k, weight: .semibold) + 9 * k
        return base + min(170 * k, TextMetrics.width(flagText(a), size: 12 * k, weight: .regular)) + 6 * k
    }

    public static func update(_ f: AgentFixture, _ c: Ctx, _ m: MotionBank) {
        AgentMotion.update(f, c, m, size: size, grow: .spring(response: 0.4, damping: 0.9))
        AgentMotion.flag(f, c, m, width: flagWidth)
        for entry in AgentRoster.all {
            let id = entry.id
            guard let a = f.agent(id) else { continue }
            if a.target != nil, m["tgt.\(id)"] < 0.02 { m.set("burst.\(id)", c.t, .snap) }
            if a.status == .asking, m["ask.\(id)"] < 0.02 { m.set("burst.\(id)", c.t, .snap) }
        }
    }

    public static func body(_ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(AgentRoster.all, id: \.id) { entry in
                if m["tgt.\(entry.id)"] > 0.01 { target(entry.id, c, m) }
            }
            ForEach(AgentRoster.all, id: \.id) { entry in
                if m["on.\(entry.id)"] > 0.002 { chip(entry, f, c, m) }
            }
            ForEach(AgentRoster.all, id: \.id) { entry in
                if AgentMotion.pointerOpacity(entry.id, c, m) > 0.002 { pointer(entry, f, c, m) }
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func times(_ id: String, _ c: Ctx, _ m: MotionBank) -> AuroraGlow.Times {
        AuroraGlow.Times(elapsed: c.reduceMotion ? 0 : c.t,
                         burst: c.reduceMotion ? -1 : c.t - m.value("burst.\(id)", c.t - 10))
    }

    static func target(_ id: String, _ c: Ctx, _ m: MotionBank) -> some View {
        let r = AgentMotion.targetFrame(id, m, outset: 3)
        let ask = m["ask.\(id)"]
        return AuroraEdge(size: r.size, radius: m["tr.\(id)"] + 3, border: 2, rim: 4, bloom: 0.55 + 0.45 * ask,
                          times: times(id, c, m), reduceTransparency: c.reduceTransparency,
                          palette: ask > 0.5 ? .sunset : .appleIntelligence)
            .opacity(m["tgt.\(id)"].clamped(0, 1))
            .offset(x: r.minX, y: r.minY)
    }

    static func glass(_ c: Ctx) -> Color {
        c.dark ? Color(white: 0.1).opacity(c.reduceTransparency ? 0.97 : 0.78)
               : Color.white.opacity(c.reduceTransparency ? 0.98 : 0.86)
    }

    static func ink(_ c: Ctx) -> Color { c.dark ? .white : Color.black.opacity(0.85) }

    static func chip(_ e: AgentRoster.Entry, _ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let id = e.id
        let k = m.value("k", 1)
        let fr = AgentMotion.chipFrame(id, m)
        let on = m["on.\(id)"]
        let a = f.agent(id)
        let ask = m["ask.\(id)"].clamped(0, 1)
        let radius = 14.0 * k
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack(alignment: .topLeading) {
            if ask > 0.01 {
                AuroraEdge(size: fr.size, radius: radius, border: 2, rim: 4, bloom: ask,
                           times: times(id, c, m), reduceTransparency: c.reduceTransparency, palette: .sunset)
                    .opacity(ask)
            }
            shape.fill(glass(c))
                .overlay(shape.strokeBorder((c.dark ? Color.white : Color.black).opacity(0.12), lineWidth: 0.5))
                .padding(ask * 2)
            ZStack {
                if m["done.\(id)"] > 0.01 {
                    Check(progress: m["done.\(id)"], color: AgentRoster.done, lineWidth: 2 * k).frame(width: 11 * k, height: 11 * k)
                } else {
                    Circle().fill(e.color.mix(with: AgentRoster.ask, by: ask)).frame(width: 8 * k, height: 8 * k)
                        .shadow(color: e.color.opacity(a?.status == .acting ? 0.9 : 0), radius: 4 * k)
                }
            }
            .frame(width: 12 * k, height: 28 * k)
            .offset(x: 12 * k)
            HStack(spacing: 6 * k) {
                Text(e.name).font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(ink(c))
                Text(AgentMotion.statusText(a)).font(.system(size: 12 * k)).foregroundStyle(ink(c).opacity(0.6))
            }
            .fixedSize()
            .frame(height: 28 * k)
            .offset(x: 28 * k)
            if ask > 0.01 {
                Text(a?.question ?? "").font(.system(size: 12 * k)).foregroundStyle(ink(c).opacity(0.8))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: max(0, fr.width - 40 * k), alignment: .leading)
                    .offset(x: 28 * k, y: 26 * k + (c.reduceMotion ? 0 : (1 - ask) * 3))
                    .opacity(ask)
            }
        }
        .frame(width: fr.width, height: fr.height, alignment: .topLeading)
        .blur(radius: c.reduceMotion || c.reduceTransparency ? 0 : (1 - on) * 4)
        .scaleEffect(c.reduceMotion ? 1 : 0.94 + 0.06 * on, anchor: .trailing)
        .offset(x: fr.minX + (c.reduceMotion ? 0 : (1 - on) * 6), y: fr.minY)
        .opacity(on)
    }

    static func pointer(_ e: AgentRoster.Entry, _ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let id = e.id
        let k = m.value("k", 1)
        let ps = AgentMotion.pointer(k)
        let a = f.agent(id)
        let lab = m["lab.\(id)"].clamped(0, 1)
        let ask = m["ask.\(id)"].clamped(0, 1)
        let text = flagText(a)
        let tint = e.color.mix(with: AgentRoster.ask, by: ask)
        let base = 9 * k + 7 * k + 6 * k + TextMetrics.width(e.name, size: 12 * k, weight: .semibold) + 9 * k
        let extra = min(170 * k, TextMetrics.width(text, size: 12 * k, weight: .regular))
        let w = base + (extra + 6 * k) * lab
        let full = base + extra + 6 * k
        let fx = m.value("fx.\(id)", 12 * ps)
        return ZStack(alignment: .topLeading) {
            if !c.reduceTransparency {
                Circle().fill(tint.opacity(0.55)).frame(width: 26 * ps, height: 26 * ps).blur(radius: 8).offset(x: -8 * ps, y: -6 * ps)
            }
            AgentPointer(fill: .white, stroke: Color.black.opacity(0.55), scale: ps)
            HStack(spacing: 6 * k) {
                Circle().fill(tint).frame(width: 7 * k, height: 7 * k)
                Text(e.name).font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(ink(c)).fixedSize()
                Text(text).font(.system(size: 12 * k)).foregroundStyle(ink(c).opacity(0.65))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: extra, alignment: .leading)
                    .opacity(lab)
            }
            .padding(.leading, 9 * k)
            .frame(width: w, height: 22 * k, alignment: .leading)
            .background(Capsule().fill(glass(c)).overlay(Capsule().strokeBorder((c.dark ? Color.white : Color.black).opacity(0.12), lineWidth: 0.5)))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .offset(x: fx + (fx < 0 ? full - w : 0), y: 17 * ps)
        }
        .offset(x: m["cx.\(id)"], y: m["cy.\(id)"])
        .opacity(AgentMotion.pointerOpacity(id, c, m))
    }
}
