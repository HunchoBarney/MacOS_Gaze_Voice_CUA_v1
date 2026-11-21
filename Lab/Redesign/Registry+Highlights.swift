import SwiftUI

extension Redesign {
    /// Batch 1's gaze highlight and orb, and the flashes and press glow.
    static var highlightComponents: [ComponentEntry] { [gaze, flashes] }

    /// The Mail window and a margin around it.
    static let mailCrop = CGRect(x: 296, y: 141, width: 920, height: 660)

    public static let gaze = ComponentEntry(
        id: "gaze-highlight", title: "Gaze highlight and orb", batch: 1,
        summary: "Where Jarvis thinks you are looking, and the control it would act on.",
        currentIDs: ["gaze-highlight", "listening-halo", "tracker-gaze-dot"],
        currentNote: "Today: a blue ring that hugs labels or whole windows, a second frosted halo, and a hidden gaze dot.",
        states: GazeScript.states, flow: GazeScript.flow,
        directions: [AnyDirection(GazeBeam.self), AnyDirection(GazeAura.self), AnyDirection(GazeLens.self)],
        crop: mailCrop, showsMail: true)

    public static let flashes = ComponentEntry(
        id: "flashes", title: "\u{201C}This\u{201D}, confirm and press", batch: 1,
        summary: "The moments Jarvis acknowledges a target and presses it.",
        currentIDs: ["deictic-flash", "confirm-flash", "press-glow"],
        currentNote: "Today: three different blue rings: a grow-and-fade, an ease-out circle and a 1.2 s glow.",
        states: FlashScript.states, flow: FlashScript.flow,
        directions: [AnyDirection(FlashBeam.self), AnyDirection(FlashSiri.self), AnyDirection(FlashQuiet.self)],
        crop: CGRect(x: 296, y: 141, width: 640, height: 300), showsMail: true)
}
