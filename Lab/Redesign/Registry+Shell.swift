import SwiftUI

extension Redesign {
    /// Batch 3's shell: the menu bar item, its menu and the first-run window.
    static var shellComponents: [ComponentEntry] { [menuBarItem, menuBarMenu, firstRun] }

    public static let menuBarItem = ComponentEntry(
        id: "menu-bar-item", title: "Menu bar item", batch: 3,
        summary: "Jarvis's one always-visible mark: where it is (waiting for its name, listening, working, needing you) in an 18 pt glyph.",
        currentIDs: ["menu-bar-item"],
        currentNote: "Today: a different SF Symbol per state (waveform, ear, pause, mic.slash), nothing for working, and parked asks set the button's title to \u{201C} \u{00B7}2\u{201D}, which widens the item and shifts the icons to its left (MB-1).",
        states: ItemScript.states, flow: ItemScript.flow,
        directions: [AnyDirection(ItemIsland.self), AnyDirection(ItemAurora.self), AnyDirection(ItemQuiet.self)],
        crop: CGRect(x: Desk.size.width - 520, y: 0, width: 520, height: 110), showsMail: true)

    public static let menuBarMenu = ComponentEntry(
        id: "menu-bar-menu", title: "Menu bar menu", batch: 3,
        summary: "What the item opens: Jarvis's commands, eye tracking, and what Jarvis is doing right now.",
        currentIDs: ["menu-bar-menu"],
        currentNote: "Today: a plain NSMenu with no status; \u{201C}Eyes\u{201D} is a disabled item that reads as unavailable rather than a heading (MM-1), and a tracker failure is cut off mid-sentence in it.",
        states: MenuScript.states, flow: MenuScript.flow,
        directions: [AnyDirection(MenuIsland.self), AnyDirection(MenuAurora.self), AnyDirection(MenuQuiet.self)],
        crop: CGRect(x: Desk.size.width - 640, y: 0, width: 640, height: 800), showsMail: true)

    public static let firstRun = ComponentEntry(
        id: "first-run", title: "First run", batch: 3,
        summary: "The window that sets Jarvis up: the microphone, Accessibility and a first request.",
        currentIDs: ["first-run"],
        currentNote: "Today: static grey \u{201C}Waiting for you to switch it on\u{2026}\u{201D} with no sign of life (FR-1), buttons that lost their default styling, and corner radii that differ from Jarvis's other windows (FR-2).",
        states: SetupScript.states, flow: SetupScript.flow,
        directions: [AnyDirection(FirstRunIsland.self), AnyDirection(FirstRunAurora.self), AnyDirection(FirstRunQuiet.self)],
        crop: CGRect(x: (Desk.size.width - 880) / 2, y: 64, width: 880, height: 690), showsMail: false)
}
