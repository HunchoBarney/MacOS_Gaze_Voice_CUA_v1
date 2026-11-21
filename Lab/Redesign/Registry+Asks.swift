import SwiftUI

extension Redesign {
    /// Batch 2: target chips, "Things you can say" and the ask cards.
    static var askComponents: [ComponentEntry] { [targetChips, cheatSheet, askCards] }

    public static let targetChips = ComponentEntry(
        id: "target-chips", title: "Number, name and radial chips", batch: 2,
        summary: "Labels on the controls you can pick by voice: numbers, names, or a radial around an ambiguous gaze.",
        currentIDs: ["target-chips"],
        currentNote: "Today: frosted dark pills that swap in one frame; names have no width cap, so a long label covers its neighbours (TC-1).",
        states: ChipsScript.states, flow: ChipsScript.flow,
        directions: [AnyDirection(ChipsIsland.self), AnyDirection(ChipsAura.self), AnyDirection(ChipsQuiet.self)],
        crop: CGRect(x: 296, y: 81, width: 920, height: 720), showsMail: true)

    public static let cheatSheet = ComponentEntry(
        id: "cheat-sheet", title: "Things you can say", batch: 2,
        summary: "The phrases Jarvis understands, on request, and the same surface for a draft before Jarvis types it.",
        currentIDs: ["cheat-sheet"],
        currentNote: "Today: a custom dark slab under the menu bar, a third dark style beside the island and the chips (CS-1).",
        states: SheetScript.states, flow: SheetScript.flow,
        directions: [AnyDirection(SheetIsland.self), AnyDirection(SheetAurora.self), AnyDirection(SheetLumen.self)],
        crop: CGRect(x: (Desk.size.width - 880) / 2, y: 0, width: 880, height: 760), showsMail: true)

    public static let askCards = ComponentEntry(
        id: "ask-cards", title: "Ask cards", batch: 2,
        summary: "The richer asks inside the voice surface: check what I heard, an open question, a task approval and a problem.",
        currentIDs: ["listening-indicator"],
        currentNote: "Today: a fixed 420 pt black card with stock blue prominent buttons, and no hint of the keys or words that answer it (LI-5).",
        states: AskScript.states, flow: AskScript.flow,
        directions: [AnyDirection(AskIsland.self), AnyDirection(AskAurora.self), AnyDirection(AskLumen.self)],
        crop: CGRect(x: 0, y: 0, width: Desk.size.width, height: 480), showsMail: true)
}
