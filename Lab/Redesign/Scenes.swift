import SwiftUI

/// A combined scene: several components on the full desktop, each in a
/// chosen direction, driven by one cue sheet on one clock.
public struct SceneEntry {
    public struct Cue {
        public var at: Double
        public var component: String
        public var state: String?
    }

    public var id: String
    public var title: String
    public var caption: String
    /// Component id to direction id.
    public var picks: [String: String]
    public var duration: Double
    public var cues: [Cue]
}

@MainActor
public enum Scenes {
    /// "Send the deck": you ask, Jarvis drafts, you look at Send, it asks, it presses.
    static func sendTheDeck(_ family: String, _ name: String, picks: [String: String]) -> SceneEntry {
        SceneEntry(
            id: "send-the-deck-\(family.lowercased())", title: "Send the deck: \(name)",
            caption: "Wake word, the request, Jarvis working, your gaze on Send, its question, the press and done, with the \(name) family together.",
            picks: picks, duration: 14.2,
            cues: [
                .init(at: 0, component: "voice-island", state: "idle"),
                .init(at: 0, component: "gaze-highlight", state: "off"),
                .init(at: 0, component: "flashes", state: nil),
                .init(at: 0.6, component: "voice-island", state: "listening"),
                .init(at: 1.4, component: "voice-island", state: "hearing"),
                .init(at: 5.0, component: "voice-island", state: "working"),
                .init(at: 5.4, component: "gaze-highlight", state: "seeking"),
                .init(at: 7.0, component: "gaze-highlight", state: "locked"),
                .init(at: 7.6, component: "voice-island", state: "asking"),
                .init(at: 10.0, component: "gaze-highlight", state: "off"),
                .init(at: 10.0, component: "flashes", state: "confirm"),
                .init(at: 11.0, component: "flashes", state: "press"),
                .init(at: 11.4, component: "voice-island", state: "done"),
                .init(at: 12.0, component: "flashes", state: "done"),
                .init(at: 13.2, component: "voice-island", state: "idle"),
            ])
    }

    public static var all: [SceneEntry] {
        [sendTheDeck("A", "Island, Beam, Beam", picks: ["voice-island": "A", "gaze-highlight": "A", "flashes": "A"]),
         sendTheDeck("B", "Aurora, Aura, Siri", picks: ["voice-island": "B", "gaze-highlight": "B", "flashes": "B"]),
         sendTheDeck("C", "Lumen, Lens, Quiet", picks: ["voice-island": "C", "gaze-highlight": "C", "flashes": "C"])]
    }
}

/// Plays a scene: one Stage per component, cued from one clock. A component
/// with a nil state is hidden until its first cue.
@MainActor
public final class SceneStage {
    public let scene: SceneEntry
    public private(set) var time = 0.0
    private(set) var stages: [(id: String, stage: Stage, visible: Bool)] = []
    private var pending: [SceneEntry.Cue]

    public init(_ scene: SceneEntry, scheme: ColorScheme, reduceMotion: Bool) {
        self.scene = scene
        pending = scene.cues.sorted { $0.at < $1.at }
        for (id, pick) in scene.picks.sorted(by: { $0.key < $1.key }) {
            guard let entry = Redesign.components.first(where: { $0.id == id }),
                  let d = entry.directions.firstIndex(where: { $0.info.id == pick }) else { continue }
            let stage = Stage(entry, direction: d)
            stage.scheme = scheme
            stage.reduceMotion = reduceMotion
            stages.append((id, stage, false))
        }
        fire(settle: true)
    }

    private func fire(settle: Bool) {
        while let cue = pending.first, cue.at <= time + 1e-9 {
            pending.removeFirst()
            guard let i = stages.firstIndex(where: { $0.id == cue.component }) else { continue }
            guard let state = cue.state, let index = stages[i].stage.component.index(of: state) else {
                stages[i].visible = false
                continue
            }
            if settle || !stages[i].visible {
                stages[i].stage.settle(at: index)
            } else {
                stages[i].stage.go(to: index)
            }
            stages[i].visible = true
        }
    }

    public func advance(_ dt: Double) {
        time += dt
        fire(settle: false)
        for entry in stages { entry.stage.advance(dt) }
    }

    /// The whole desktop with every visible component, voice on top.
    public func view() -> some View {
        let order = ["flashes", "gaze-highlight", "voice-island"]
        let shown = stages.filter(\.visible).sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        let scheme = stages.first?.stage.scheme ?? .dark
        return ZStack(alignment: .topLeading) {
            MacDesktop(scheme: scheme, showsMail: true)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                StageView(stage: entry.stage, crop: Desk.full, backdrop: false)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, scheme)
    }
}
