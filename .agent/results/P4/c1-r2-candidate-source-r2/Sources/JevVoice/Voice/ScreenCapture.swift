import AppKit
import ScreenCaptureKit

/// One-shot desktop capture for the realtime lane — the screen image that
/// rides with each command turn so the model can answer "what's on my
/// screen?" without a tool call. Never fatal: any failure means the turn
/// goes out without an image.
enum ScreenCapture {
    /// JPEG of the main display, scaled to fit `maxWidth`. Our own overlay
    /// windows are excluded so the model sees the user's screen, not our
    /// floating card.
    static func jpeg(maxWidth: Int = 1536, quality: CGFloat = 0.6) async throws -> Data {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw ScreenCaptureError.noDisplay }
        let own = NSRunningApplication.current
        let ours = content.applications.filter { $0.bundleIdentifier == own.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours,
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1, CGFloat(maxWidth) / max(1, CGFloat(display.width)))
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: quality])
        else { throw ScreenCaptureError.encodeFailed }
        return data
    }

    enum ScreenCaptureError: Error { case noDisplay, encodeFailed }
}
