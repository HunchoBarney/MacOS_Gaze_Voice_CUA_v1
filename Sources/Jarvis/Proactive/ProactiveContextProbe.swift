import AppKit
import CoreGraphics
import Intents

/// Reads what the person is doing on this Mac for the suppression rules:
/// another app on the microphone (a call), a known screen-sharing
/// indicator window, a slideshow filling a display, and Focus.
@MainActor
enum ProactiveContextProbe {
    static let presenters: Set<String> = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"]
    /// Window names screen-sharing tools show while they share
    /// [heuristic, to be widened from the owner's physical checks].
    static let sharingWindowHints = [
        "is sharing your screen", "is sharing a window", "you are screen sharing", "zoom share",
        "sharing control bar", "screen sharing", "stop share",
    ]

    static func read(userTalking: Bool, jarvisSpeaking: Bool) -> ProactiveContext {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return ProactiveContext(userTalking: userTalking, jarvisSpeaking: jarvisSpeaking,
                                onCall: OtherMicrophoneUse.active(),
                                screenSharing: sharing(windows),
                                presenting: presenting(windows),
                                focus: focus())
    }

    static func sharing(_ windows: [[String: Any]]) -> Bool {
        windows.contains { row in
            let name = (row[kCGWindowName as String] as? String ?? "").lowercased()
            return !name.isEmpty && sharingWindowHints.contains { name.contains($0) }
        }
    }

    static func presenting(_ windows: [[String: Any]]) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier, presenters.contains(bundleID) else { return false }
        let displays = NSScreen.screens.map { CGDisplayBounds(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) }
        return windows.contains { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == front.processIdentifier,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return displays.contains(rect)
        }
    }

    /// nil when macOS won't say. Focus status needs the person's consent
    /// and the Communication Notifications entitlement, which a locally
    /// signed build doesn't carry yet.
    static func focus() -> Bool? {
        guard INFocusStatusCenter.default.authorizationStatus == .authorized else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }
}
