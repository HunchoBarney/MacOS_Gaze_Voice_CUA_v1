import SwiftUI

// JARVIS PATCH: an injectable clock, as in VoiceCore's VoiceClock.
@MainActor
public final class VoiceGlowClock {
    public var time: Double
    var engines: [String: VoiceGlowEngine] = [:]
    public init(time: Double = 0) { self.time = time }
    func engine(_ key: String) -> VoiceGlowEngine {
        if let engine = engines[key] { return engine }
        let engine = VoiceGlowEngine()
        engines[key] = engine
        return engine
    }
}

private struct VoiceGlowClockKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: VoiceGlowClock? = nil
}

extension EnvironmentValues {
    public var voiceGlowClock: VoiceGlowClock? {
        get { self[VoiceGlowClockKey.self] }
        set { self[VoiceGlowClockKey.self] = newValue }
    }
}
