import BorderBeamKit
import SwiftUI
import ThinkingOrbsKit

/// A. Islands: every agent is a small black island. In the shelf it is a
/// pill with the agent's thinking orb; its pointer carries a pill label that
/// grows out of a dot when the agent lands on a control, which then runs a
/// beam in the agent's own colourway. An agent that needs you grows its pill
/// into a card, the way the Dynamic Island grows for a call.
@MainActor
public enum AgentIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Islands", axis: "Each agent is a tiny Dynamic Island that grows when it acts or asks",
        pitch: "Wins if the agents should read as part of the Island voice surface: one black material, one thinking orb, one beam, at every size.",
        cost: "Black pills are loud on a light desktop, and two beams at once is the most motion of the three; it relies on the beam staying dim on the label.",
        libraries: [Lib.thinkingOrbs, Lib.borderBeam, Lib.dynamicNotchKit, Lib.swiftUISpring],
        custom: "The shelf stack and the pointer (a filled arrow; SF Symbols' cursorarrow is outline-only), the dot-to-pill label morph and the pill-to-card morph.",
        skills: [SkillNote("apple-design", "Spatial consistency: a pointer leaves its own chip and returns into it when the agent is done, so you always know whose it is. Labels are 12 pt on opaque black (AC-1, AS-1: no 9-10 pt type on thin material)."),
                 SkillNote("choreograph", "The chip leads, the pointer follows 220 ms later; the label opens only when the pointer lands; a leaving chip drops out of the stack at once so its neighbours close the gap while it fades."),
                 SkillNote("animate", "Pointer travel is two critically damped springs (x 0.5 s, y 0.62 s), so a long move bends into a gentle arc instead of a ruler line; the card grows on 0.42 s / 0.8 damping, the one bounce, for the one moment that needs you."),
                 SkillNote("gestures", "The pointer follows the driver's reported positions through a spring that keeps velocity, so a retarget mid-glide bends instead of stopping."),
                 SkillNote("emil-design-eng", "Nothing scales from zero: chips enter from 0.92 and 8 pt to the right, and the needs-you colour is the only orange on screen."),
                 SkillNote("remove-animations", "An idle agent's orb is paused; only acting agents move."),
                 SkillNote("break-ui", "At the largest label setting (2x) every chip, card and flag grows with its type (24 pt names, 56 pt chips), the pointer grows half as much, and a flag that would run off the screen swings to the pointer's left; flags cap at 240 pt x scale and truncate the action, never the name.")],
        alwaysOn: true)

    static func size(_ a: AgentFixture.Agent, _ k: Double) -> CGSize {
        if a.status == .asking {
            let q = TextMetrics.width(a.question ?? "", size: 13 * k, weight: .regular)
            return CGSize(width: min(Desk.size.width - 330, max(286 * k, q + 64 * k)), height: 70 * k)
        }
        return CGSize(width: 10 * k + 16 * k + 8 * k + AgentMotion.textWidth(a, k) + 12 * k, height: 28 * k)
    }

    static func flagWidth(_ a: AgentFixture.Agent, _ k: Double) -> CGFloat {
        let text = a.status == .done ? "Done" : a.status == .asking ? "Needs you" : a.action
        return min(240 * k, 30 * k + TextMetrics.width(AgentRoster.entry(a.id).name, size: 12 * k, weight: .semibold)
                   + 6 * k + TextMetrics.width(text, size: 12 * k, weight: .regular) + 10 * k)
    }

    public static func update(_ f: AgentFixture, _ c: Ctx, _ m: MotionBank) {
        AgentMotion.update(f, c, m, size: size)
        AgentMotion.flag(f, c, m, width: flagWidth)
        for entry in AgentRoster.all {
            let asking = f.agent(entry.id)?.status == .asking && (c.local > (c.reduceMotion ? 0 : 0.85) || c.state == "large")
            m.set("card.\(entry.id)", asking ? 1 : 0, asking ? c.fade(.easeOut(0.24)) : c.fade(.easeOut(0.12)))
        }
    }

    public static func body(_ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(AgentRoster.all, id: \.id) { entry in
                if m["tgt.\(entry.id)"] > 0.01 { target(entry, f, c, m) }
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

    static func beam(_ id: String, asking: Bool) -> BeamColorVariant {
        if asking { return .sunset }
        return id == "calendar" ? .ocean : .colorful
    }

    static func target(_ e: AgentRoster.Entry, _ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let id = e.id
        let r = AgentMotion.targetFrame(id, m, outset: 3)
        let radius = m["tr.\(id)"] + 3
        return BorderBeam(size: .sm, colorVariant: beam(id, asking: m["ask.\(id)"] > 0.5), theme: c.dark ? .dark : .light,
                          staticColors: c.reduceMotion, borderRadius: radius, strength: m["tgt.\(id)"].clamped(0, 1)) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(e.color.opacity(0.1 * m["tgt.\(id)"]))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder((c.dark ? Color.white : Color.black).opacity(0.22 * m["tgt.\(id)"]), lineWidth: 1))
                .frame(width: r.width, height: r.height)
        }
        .environment(\.beamFrozenTime, c.reduceMotion ? 0 : c.t)
        .offset(x: r.minX, y: r.minY)
    }

    static func chip(_ e: AgentRoster.Entry, _ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let id = e.id
        let k = m.value("k", 1)
        let fr = AgentMotion.chipFrame(id, m)
        let on = m["on.\(id)"]
        let a = f.agent(id)
        let card = m["card.\(id)"]
        let orbState: OrbState = a?.status == .asking ? .listening : .working
        let moving = a?.status == .acting || a?.status == .asking
        let corner = min(fr.height / 2, 22 * k)
        let orb = 16 * k
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(c.dark ? 0.14 : 0), lineWidth: 0.5))
                .shadow(color: .black.opacity(c.dark ? 0.4 : 0.22), radius: 8, y: 3)
            ZStack {
                if m["done.\(id)"] > 0.01 {
                    Check(progress: m["done.\(id)"], color: AgentRoster.done, lineWidth: 2 * k)
                        .frame(width: 12 * k, height: 12 * k)
                } else {
                    ThinkingOrb(state: orbState, size: .px20, theme: .dark, paused: c.reduceMotion || !moving, displaySize: orb)
                        .orbFrozenTime(moving && !c.reduceMotion ? c.t : nil)
                        .frame(width: orb, height: orb)
                }
            }
            .frame(width: orb, height: orb)
            .offset(x: 10 * k, y: (min(fr.height, 40 * k) - orb) / 2)
            HStack(spacing: 6 * k) {
                Text(e.name).font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(.white)
                Text(AgentMotion.statusText(a)).font(.system(size: 12 * k)).foregroundStyle(Color.white.opacity(0.62))
            }
            .fixedSize()
            .frame(height: 28 * k)
            .offset(x: 34 * k)
            .opacity(1 - m["ask.\(id)"].clamped(0, 1))
            VStack(alignment: .leading, spacing: 3 * k) {
                Text("\(e.name) needs you").font(.system(size: 13 * k, weight: .semibold)).foregroundStyle(.white)
                Text(a?.question ?? "").font(.system(size: 13 * k)).foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(width: max(0, fr.width - 52 * k), alignment: .leading)
            .frame(height: fr.height)
            .offset(x: 34 * k, y: c.reduceMotion ? 0 : (1 - card) * 4)
            .opacity(card)
            if card > 0.01 {
                Circle().fill(AgentRoster.ask).frame(width: 7 * k, height: 7 * k)
                    .offset(x: fr.width - 17 * k, y: 10 * k)
                    .opacity(card)
            }
        }
        .frame(width: fr.width, height: fr.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .scaleEffect(c.reduceMotion ? 1 : 0.92 + 0.08 * on, anchor: .trailing)
        .offset(x: fr.minX + (c.reduceMotion ? 0 : (1 - on) * 8), y: fr.minY)
        .opacity(on)
    }

    static func pointer(_ e: AgentRoster.Entry, _ f: AgentFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let id = e.id
        let k = m.value("k", 1)
        let ps = AgentMotion.pointer(k)
        let a = f.agent(id)
        let lab = m["lab.\(id)"].clamped(0, 1.2)
        let asking = m["ask.\(id)"]
        let text = a == nil || a?.status == .done ? "Done" : a?.status == .asking ? "Needs you" : (a?.action ?? "")
        let full = a.map { flagWidth($0, k) } ?? 22 * k
        let w = 22 * k + (full - 22 * k) * lab
        return ZStack(alignment: .topLeading) {
            AgentPointer(fill: .black, stroke: .white, scale: ps)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(c.dark ? 0.16 : 0), lineWidth: 0.5))
                Circle().fill(e.color.mix(with: AgentRoster.ask, by: asking))
                    .frame(width: 8 * k, height: 8 * k)
                    .offset(x: 7 * k)
                HStack(spacing: 6 * k) {
                    Text(e.name).font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(.white).fixedSize()
                    Text(text).font(.system(size: 12 * k)).foregroundStyle(Color.white.opacity(0.68))
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(width: max(0, full - 30 * k), alignment: .leading)
                .offset(x: 21 * k)
                .opacity(lab.clamped(0, 1))
            }
            .frame(width: w, height: 22 * k, alignment: .leading)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
            .offset(x: m.value("fx.\(id)", 12 * ps) + (m.value("fx.\(id)", 0) < 0 ? full - w : 0), y: 17 * ps)
        }
        .offset(x: m["cx.\(id)"], y: m["cy.\(id)"])
        .opacity(AgentMotion.pointerOpacity(id, c, m))
    }
}
