import SwiftUI

/// The lab's catalog: every redesigned component, its states and its directions.
@MainActor
public enum Redesign {
    public static var components: [ComponentEntry] { [voice] + highlightComponents }

    public static let voice = ComponentEntry(
        id: "voice-island", title: "Voice surface", batch: 1,
        summary: "What you see while Jarvis listens, works, asks and finishes: the surface you see most.",
        currentIDs: ["listening-indicator"],
        currentNote: "Today: a black tab under the notch that swaps states in one frame.",
        states: VoiceScript.states, flow: VoiceScript.flow,
        directions: [AnyDirection(VoiceIsland.self), AnyDirection(VoiceAurora.self), AnyDirection(VoiceLumen.self)],
        crop: CGRect(x: 0, y: 0, width: Desk.size.width, height: 560),
        showsMail: true)
}
