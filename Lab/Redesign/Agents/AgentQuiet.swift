import Orb
import SwiftUI

/// C. Pointers: no light. Each agent is a coloured pointer with its name in
/// a flag of the same colour (the multiplayer cursor everyone already reads),
/// the control it works on gets a crisp outline in that colour, and the shelf
/// is a column of plain cards with each agent's marble. Needs-you is an
/// orange outline and a question mark.
@MainActor
public enum AgentQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Pointers", axis: "Quietest: coloured pointers and crisp outlines, no glow",
        pitch: "Wins if agents should feel like collaborators in a shared document: instantly legible, colour for identity, and the light show left to the voice surface.",
        cost: "Identity rests on colour alone; with four agents two colours sit close, and a 1.5 pt outline is easier to miss than light on a busy window.",
        libraries: [Lib.orb, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The shelf stack and pointer (shared with A and B), the name flag and the outlines.",
        skills: [SkillNote("emil-design-eng", "Restraint: one stroke weight, one accent per agent, opaque flags with white 12 pt type that read on any window (AC-1)."),
                 SkillNote("apple-design", "Familiarity: the coloured multiplayer pointer is a pattern people already know, so no learning; the shelf uses opaque cards, not thin material (AS-1)."),
                 SkillNote("break-ui", "The needs-you glyph is an orange filled circle with a white question mark and an outline, legible on a light desktop where today's yellow glyph wasn't; flags cap at 200 pt x the label scale, truncate the action, never the name, and swing to the pointer's left when they would leave the screen at 2x."),
                 SkillNote("choreograph", "Chip, then pointer 220 ms later; the outline draws when the pointer lands; on done the pointer returns into its card before the card leaves."),
                 SkillNote("remove-animations", "The marble only turns while its agent acts and stops under Reduce Motion; idle cards are completely still.")],
        alwaysOn: true)

    static func size(_ a: AgentFixture.Agent, _ k: Double) -> CGSize {
        let glyph = a.status == .asking ? 22 * k : 0
        return CGSize(width: 9 * k + 14 * k + 8 * k + AgentMotion.textWidth(a, k) + glyph + 11 * k, height: 28 * k)
    }

    static func flagText(_ a: AgentFixture.Agent?) -> String {
        guard let a, a.status != .done else { return "Done" }
        return a.status == .asking ? (a.question ?? "Needs you") : a.action
    }

    static func flagWidth(_ a: AgentFixture.Agent, _ k: Double) -> CGFloat {
        8 * k + TextMetrics.width(AgentRoster.entry(a.id).name, size: 12 * k, weight: .semibold) + 8 * k
            + min(200 * k, TextMetrics.width(flagText(a), size: 12 * k, weight: .regular)) + 6 * k
    }

    public static func update(_ f: AgentFixture, _ c: Ctx, _ m: MotionBank) {
        AgentMotion.update(f, c, m, size: size, grow: .spring(response: 0.3, damping: 1))
        AgentMotion.flag(f, c, m, width: flagWidth)
    }

    public static func body(_ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(AgentRoster.all, id: \.id) { entry in
                if m["tgt.\(entry.id)"] > 0.01 { target(entry, c, m) }
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

    static func target(_ e: AgentRoster.Entry, _ c: Ctx, _ m: MotionBank) -> some View {
        let id = e.id
        let r = AgentMotion.targetFrame(id, m, outset: 3)
        let tint = e.color.mix(with: AgentRoster.ask, by: m["ask.\(id)"].clamped(0, 1))
        let shape = RoundedRectangle(cornerRadius: m["tr.\(id)"] + 3, style: .continuous)
        return shape.fill(tint.opacity(c.dark ? 0.14 : 0.08))
            .overlay(shape.strokeBorder(tint, lineWidth: 1.5))
            .frame(width: r.width, height: r.height)
            .opacity(m["tgt.\(id)"].clamped(0, 1))
            .offset(x: r.minX, y: r.minY)
    }

    static func chip(_ e: AgentRoster.Entry, _ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let id = e.id
        let k = m.value("k", 1)
        let fr = AgentMotion.chipFrame(id, m)
        let on = m["on.\(id)"]
        let a = f.agent(id)
        let ask = m["ask.\(id)"].clamped(0, 1)
        let ink = c.dark ? Color.white : Color.black.opacity(0.85)
        let shape = RoundedRectangle(cornerRadius: 9 * k, style: .continuous)
        let turning = a?.status == .acting && !c.reduceMotion
        return ZStack(alignment: .leading) {
            shape.fill(c.dark ? Color(white: 0.15) : Color.white)
                .overlay(shape.strokeBorder((c.dark ? Color.white : Color.black).opacity(0.12), lineWidth: 0.5))
                .overlay(shape.strokeBorder(AgentRoster.ask.opacity(ask), lineWidth: 1.5 * max(1, k * 0.75)))
                .shadow(color: .black.opacity(c.dark ? 0.35 : 0.12), radius: 6, y: 2)
            HStack(spacing: 8 * k) {
                ZStack {
                    if m["done.\(id)"] > 0.01 {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14 * k)).foregroundStyle(.white, AgentRoster.done)
                            .opacity(m["done.\(id)"])
                    } else {
                        OrbView(configuration: OrbConfiguration(backgroundColors: [e.color, e.color.mix(with: .white, by: 0.35), e.color.mix(with: .black, by: 0.2)],
                                                                glowColor: .white, coreGlowIntensity: 0.7,
                                                                showParticles: false, showShadow: false,
                                                                speed: turning ? 20 : 0))
                            .frame(width: 14 * k, height: 14 * k)
                    }
                }
                .frame(width: 14 * k, height: 14 * k)
                HStack(spacing: 6 * k) {
                    Text(e.name).font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(ink)
                    Text(AgentMotion.statusText(a)).font(.system(size: 12 * k))
                        .foregroundStyle(ask > 0.5 ? AgentRoster.ask.mix(with: .black, by: c.dark ? 0 : 0.25) : ink.opacity(0.6))
                }
                .fixedSize()
                if ask > 0.01 {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 14 * k, weight: .semibold))
                        .foregroundStyle(.white, AgentRoster.ask)
                        .opacity(ask)
                }
            }
            .padding(.leading, 9 * k)
        }
        .frame(width: fr.width, height: fr.height)
        .offset(x: fr.minX + (c.reduceMotion ? 0 : (1 - on) * 8), y: fr.minY)
        .opacity(on)
    }

    static func pointer(_ e: AgentRoster.Entry, _ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let id = e.id
        let k = m.value("k", 1)
        let ps = AgentMotion.pointer(k)
        let a = f.agent(id)
        let lab = m["lab.\(id)"].clamped(0, 1)
        let text = flagText(a)
        let base = 8 * k + TextMetrics.width(e.name, size: 12 * k, weight: .semibold) + 8 * k
        let extra = min(200 * k, TextMetrics.width(text, size: 12 * k, weight: .regular))
        let w = base + (extra + 6 * k) * lab
        let full = base + extra + 6 * k
        let fx = m.value("fx.\(id)", 11 * ps)
        let flag = RoundedRectangle(cornerRadius: 6 * k, style: .continuous)
        return ZStack(alignment: .topLeading) {
            AgentPointer(fill: e.color, stroke: .white, scale: ps)
            HStack(spacing: 6 * k) {
                Text(e.name).font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(.white).fixedSize()
                Text(text).font(.system(size: 12 * k)).foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: extra, alignment: .leading)
                    .opacity(lab)
            }
            .padding(.leading, 8 * k)
            .frame(width: w, height: 21 * k, alignment: .leading)
            .background(flag.fill(e.color))
            .clipShape(flag)
            .overlay(flag.strokeBorder(AgentRoster.ask.opacity(m["ask.\(id)"].clamped(0, 1)), lineWidth: 2))
            .offset(x: fx + (fx < 0 ? full - w : 0), y: 16 * ps)
        }
        .offset(x: m["cx.\(id)"], y: m["cy.\(id)"])
        .opacity(AgentMotion.pointerOpacity(id, c, m))
    }
}
