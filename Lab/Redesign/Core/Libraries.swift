/// Every library a direction uses, pinned to the vendored commit
/// (Lab/Vendor/*/VENDOR.md and .agent/REUSE.md).
public enum Lib {
    static let librariesDev = "Libraries.dev@14ae9d2"
    public static let thinkingOrbs = LibraryUse("ThinkingOrbsKit (libraries.dev Orb)", librariesDev, "MIT", "https://libraries.dev/orbs", role: "Thinking orb: listening and working states")
    public static let voiceRing = LibraryUse("VoiceRingKit (libraries.dev Voice ring)", librariesDev, "MIT", "https://libraries.dev/voice-ring", role: "Ring of light that bends with the voice level")
    public static let borderBeam = LibraryUse("BorderBeamKit (libraries.dev Beam)", librariesDev, "MIT", "https://libraries.dev/beam", role: "Light that rides a border")
    public static let orb = LibraryUse("Orb (metasidd)", "a48fc33", "MIT", "https://github.com/metasidd/Orb", role: "Glowing orb")
    public static let aurora = LibraryUse("Aurora (tornikegomareli)", "a3f9296", "MIT (stated in README; no LICENSE file upstream)", "https://github.com/tornikegomareli/Aurora", role: "Apple Intelligence edge glow: a Metal port of Siri's IntelligentLight algorithm")
    public static let dynamicNotchKit = LibraryUse("DynamicNotchKit (geometry)", "cd0b3e5", "MIT", "https://github.com/MrKai77/DynamicNotchKit", role: "Notch silhouette; the product host for a notch window")
    public static let swiftUISpring = LibraryUse("SwiftUI Spring (Apple)", "macOS 26 SDK", "Platform", "https://developer.apple.com/documentation/swiftui/spring", role: "Interruptible spring physics with velocity carry")
    public static let sfSymbols = LibraryUse("SF Symbols (Apple)", "macOS 26 SDK", "Platform", "https://developer.apple.com/sf-symbols/", role: "State glyphs: done and needs-you")
    public static let meshGradient = LibraryUse("SwiftUI MeshGradient (Apple)", "macOS 26 SDK", "Platform", "https://developer.apple.com/documentation/swiftui/meshgradient", role: "GPU mesh gradient")
}
