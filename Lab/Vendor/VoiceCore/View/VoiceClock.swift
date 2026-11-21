import SwiftUI

// JARVIS PATCH: an injectable clock. The canvas normally keeps its engine in
// @State and reads TimelineView's wall clock; ImageRenderer rebuilds @State
// every frame and never advances a TimelineView. When a VoiceClock is in the
// environment, canvases draw at its time and keep their engines in it.
@MainActor
public final class VoiceClock {
    public var time: Double
    var engines: [String: OrbEngine] = [:]
    public init(time: Double = 0) { self.time = time }
    func engine(_ key: String) -> OrbEngine {
        if let engine = engines[key] { return engine }
        let engine = OrbEngine()
        engines[key] = engine
        return engine
    }
}

private struct VoiceClockKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: VoiceClock? = nil
}

extension EnvironmentValues {
    public var voiceClock: VoiceClock? {
        get { self[VoiceClockKey.self] }
        set { self[VoiceClockKey.self] = newValue }
    }
}
