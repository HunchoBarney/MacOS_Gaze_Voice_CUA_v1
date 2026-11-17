import Foundation

var privateReplayInputs: URL {
    if let path = ProcessInfo.processInfo.environment["JARVIS_P3_RECORDINGS_ROOT"] {
        return URL(fileURLWithPath: path)
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let restored = root.appendingPathComponent(".context/c1-local/p3-audio")
    if FileManager.default.fileExists(atPath: restored.appendingPathComponent("manifest.json").path) {
        return restored
    }
    return root.appendingPathComponent(".agent/results/P3/audio")
}
