import SwiftUI

extension Redesign {
    /// Batch 3's windows: Settings and Agents.
    static var windowComponents: [ComponentEntry] { [settingsWindow, agentsWindow] }

    public static let settingsWindow = ComponentEntry(
        id: "settings-window", title: "Settings", batch: 3,
        summary: "How Jarvis listens, talks and helps, as a native macOS 26 settings window, including Live voice and the comfort label size.",
        currentIDs: ["settings-window", "live-usage"],
        currentNote: "Today: one long page of cards with hand-sized 28/17/14/13 pt type that ignores the label-size setting (SW-1), a sidebar of two pages, and Live voice as a stock progress bar.",
        states: SettingsScript.states, flow: SettingsScript.flow,
        directions: [AnyDirection(SettingsIsland.self), AnyDirection(SettingsGlow.self), AnyDirection(SettingsQuiet.self)],
        crop: CGRect(x: 166, y: 40, width: 1180, height: 942), showsMail: false)

    public static let agentsWindow = ComponentEntry(
        id: "agents-window", title: "Agents", batch: 3,
        summary: "The helpers Jarvis runs for you, each with the face it wears on screen, and Activity, Jarvis's own feed of what you asked and what it did.",
        currentIDs: ["agents-window", "settings-window"],
        currentNote: "Today: a sidebar of coloured dots with 11-15 pt hand-sized type, a spinner while an agent works, and Activity on a separate page of the Settings window.",
        states: AgentsWindowScript.states, flow: AgentsWindowScript.flow,
        directions: [AnyDirection(AgentsWindowIsland.self), AnyDirection(AgentsWindowGlow.self), AnyDirection(AgentsWindowQuiet.self)],
        crop: CGRect(x: 126, y: 100, width: 1260, height: 740), showsMail: false)
}
