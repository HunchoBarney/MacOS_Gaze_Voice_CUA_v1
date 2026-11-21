import SwiftUI

extension Redesign {
    /// Batch 2's agents on screen and the guide callout.
    static var agentComponents: [ComponentEntry] { [agents, guide] }

    public static let agents = ComponentEntry(
        id: "agent-presence", title: "Agents on screen", batch: 2,
        summary: "Who is working on your Mac: each agent's pointer and name where it acts, and the shelf of every agent running.",
        currentIDs: ["agent-cursor", "agent-shelf"],
        currentNote: "Today: a coloured dot with a 10 pt label at the action point, and 9-10 pt chips on thin material with a yellow question glyph.",
        states: AgentScript.states, flow: AgentScript.flow,
        directions: [AnyDirection(AgentIsland.self), AnyDirection(AgentAurora.self), AnyDirection(AgentQuiet.self)],
        crop: CGRect(x: 296, y: 0, width: 1216, height: 800), showsMail: true)

    public static let guide = ComponentEntry(
        id: "guide-callout", title: "Guide callout", batch: 2,
        summary: "The words of a guided step beside the control it points at, from first step to dismissal.",
        currentIDs: ["guide-callout"],
        currentNote: "Today: a black label that fades in place beside a glowing control, dims to 55% to pulse, and vanishes in one frame.",
        states: GuideScript.states, flow: GuideScript.flow,
        directions: [AnyDirection(GuideIsland.self), AnyDirection(GuideAurora.self), AnyDirection(GuideQuiet.self)],
        crop: CGRect(x: 296, y: 141, width: 920, height: 480), showsMail: true)
}
