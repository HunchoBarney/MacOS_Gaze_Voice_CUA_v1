import SwiftUI

/// What Jarvis's menu bar item shows. Fixture states mirror the product's
/// (AppDelegate.refreshStatusIcon and refreshAskBadge) plus working, which
/// the product leaves to the on-screen tab.
public struct ItemFixture {
    public enum Phase: String, CaseIterable {
        case standby, listening, working, asks = "asks-parked", paused, noMic = "no-mic"
    }
    public var phase: Phase
    /// The bigger-labels comfort setting (Config.labelScale): 1 to 2 in quarter steps.
    public var labelScale: Double = 1
    /// Microphone level while Jarvis hears you.
    public var level: Double = 0
    /// Parked asks waiting for you.
    public var asks = 2
    /// The pointer rests on the item, so its tooltip shows.
    public var tooltip = false

    /// Jarvis is live: listening, working or waiting for you.
    var live: Bool { phase == .listening || phase == .working || phase == .asks }
}

public enum ItemScript {
    /// The tooltip and VoiceOver description, as the product words them.
    static func describe(_ f: ItemFixture) -> String {
        switch f.phase {
        case .standby: return "Jarvis is waiting for \u{201C}Hey Jarvis\u{201D}"
        case .listening: return "Jarvis is listening"
        case .working: return "Jarvis is working on a task"
        case .asks: return "Jarvis needs you: \(f.asks) questions are waiting"
        case .paused: return "Jarvis is paused"
        case .noMic: return "Jarvis can't hear you. Microphone access is off."
        }
    }

    @MainActor
    static func phase(of state: String?) -> ItemFixture.Phase? {
        guard let state, let entry = states.first(where: { $0.id == state }) else { return nil }
        return (entry.fixture(0) as? ItemFixture)?.phase
    }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("standby", "Waiting for \u{201C}Hey Jarvis\u{201D}", caption: "At rest: Jarvis listens on your Mac for its name. The glyph is as quiet as the system's own.", duration: 1.6) { _ in
            ItemFixture(phase: .standby)
        },
        StateEntry("listening", "Listening", caption: "You said \u{201C}Hey Jarvis\u{201D}: the item comes alive while it hears you.", duration: 2.4) { t in
            ItemFixture(phase: .listening, level: VoiceScript.speech(t, until: 2.0))
        },
        StateEntry("working", "Working", caption: "Jarvis is doing a task on your Mac.", duration: 2.4) { _ in
            ItemFixture(phase: .working)
        },
        StateEntry("asks-parked", "Needs you (2 questions)", caption: "Two questions wait for you. The item says so inside its own width, so nothing in the menu bar shifts (MB-1).", duration: 2.4) { _ in
            ItemFixture(phase: .asks)
        },
        StateEntry("paused", "Paused", caption: "You paused listening from the menu.", duration: 1.6) { _ in
            ItemFixture(phase: .paused)
        },
        StateEntry("no-mic", "Can't hear you", caption: "Microphone access is off, so Jarvis can't hear its name.", duration: 1.6) { _ in
            ItemFixture(phase: .noMic)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "Bigger labels at 2\u{00D7}: the glyph grows to the 22 pt a status item may use, and the tooltip that names the state doubles.", duration: 2.6) { _ in
            ItemFixture(phase: .asks, labelScale: 2, tooltip: true)
        },
    ]

    public static let flow = ["standby", "listening", "working", "asks-parked", "standby", "paused", "no-mic", "standby", "large", "standby"]
}
