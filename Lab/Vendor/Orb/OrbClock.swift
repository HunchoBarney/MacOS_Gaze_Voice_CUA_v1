import SwiftUI

// JARVIS PATCH (the only behavioural change to upstream): an injectable
// clock. When set, every layer draws the instant \`orbClock\` seconds instead
// of reading TimelineView's wall clock or running repeatForever animations,
// so the gallery harness can render exact frames and the lab can slow time.

private struct OrbClockKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    var orbClock: Double? {
        get { self[OrbClockKey.self] }
        set { self[OrbClockKey.self] = newValue }
    }
}

public extension View {
    /// Draw every OrbView below this view at \`t\` seconds; nil restores the live clock.
    func orbClock(_ t: Double?) -> some View { environment(\.orbClock, t) }
}
