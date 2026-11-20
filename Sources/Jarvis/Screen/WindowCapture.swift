import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One picture of one window, taken only because the person asked a
/// question the accessibility text couldn't answer. The privacy promise:
/// "One picture of one window to OpenAI, password boxes blacked out,
/// nothing kept."
///
/// - Only the named window is captured (`desktopIndependentWindow`), so
///   Jarvis's own overlays and every other app stay out of it; a Jarvis
///   window itself is refused.
/// - Password boxes and other secret fields are painted black before
///   the image is encoded. The caller passes their frames (the screen
///   reader's `redactions`) and whether that list is complete; an
///   incomplete list refuses, because a missed box would be sent.
/// - The picture lives in memory as PNG bytes. Nothing is written to disk.
/// - Screen Recording is asked for here, the first time a picture is
///   needed, never during first run.
enum WindowCapture {
    static let maxLongEdge: CGFloat = 1280
    static let redactionPadding: CGFloat = 2

    enum Failure: Error, LocalizedError, Equatable {
        case redactionsIncomplete, needsScreenRecording, windowNotFound, ownWindow, captureFailed, encodeFailed

        var errorDescription: String? {
            switch self {
            case .redactionsIncomplete: return "I couldn't find every password box in that window, so I won't take a picture of it."
            case .needsScreenRecording: return "To look at pictures on your screen, allow Jarvis in System Settings, Privacy & Security, Screen Recording."
            case .windowNotFound: return "That window isn't on screen any more."
            case .ownWindow: return "That's one of my own windows."
            case .captureFailed: return "macOS didn't let me take the picture."
            case .encodeFailed: return "I couldn't prepare the picture."
            }
        }
    }

    struct Picture: Sendable {
        let png: Data
        /// Pixel size of the PNG; with `windowFrame` it maps a box Terra
        /// names in the picture back to points on screen.
        let pixelSize: CGSize
        /// The window's frame in global top-left points at capture time.
        let windowFrame: CGRect
    }

    /// Captures and redacts one window. `redactions` are global top-left
    /// points, the same space as accessibility frames.
    static func capture(windowID: CGWindowID, redactions: [CGRect],
                        redactionsComplete: Bool) async throws -> Picture {
        guard redactionsComplete else { throw Failure.redactionsIncomplete }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw Failure.needsScreenRecording
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw Failure.windowNotFound
        }
        let owner = window.owningApplication
        if owner?.processID == ProcessInfo.processInfo.processIdentifier
            || owner?.bundleIdentifier == Bundle.main.bundleIdentifier {
            throw Failure.ownWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = pixelSize(points: window.frame.size, scale: CGFloat(filter.pointPixelScale))
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw Failure.captureFailed
        }
        guard let redacted = redact(image, windowFrame: window.frame, redactions: redactions),
              let png = encodePNG(redacted) else { throw Failure.encodeFailed }
        return Picture(png: png, pixelSize: CGSize(width: redacted.width, height: redacted.height),
                       windowFrame: window.frame)
    }

    /// Backing pixels for a window, scaled down so the long edge is at
    /// most `maxLongEdge`.
    static func pixelSize(points: CGSize, scale: CGFloat) -> CGSize {
        let full = CGSize(width: points.width * scale, height: points.height * scale)
        let longEdge = max(full.width, full.height)
        guard longEdge > maxLongEdge else { return CGSize(width: full.width.rounded(), height: full.height.rounded()) }
        let shrink = maxLongEdge / longEdge
        return CGSize(width: (full.width * shrink).rounded(), height: (full.height * shrink).rounded())
    }

    /// Redaction frames in image pixels, top-left origin, padded and
    /// clipped to the picture. Frames outside the window drop out.
    static func imageRects(for redactions: [CGRect], windowFrame: CGRect, imageSize: CGSize) -> [CGRect] {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
        let sx = imageSize.width / windowFrame.width, sy = imageSize.height / windowFrame.height
        let bounds = CGRect(origin: .zero, size: imageSize)
        return redactions.compactMap { frame in
            let local = frame.insetBy(dx: -redactionPadding, dy: -redactionPadding)
                .offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
            let pixels = CGRect(x: local.minX * sx, y: local.minY * sy,
                                width: local.width * sx, height: local.height * sy)
                .integral.intersection(bounds)
            return pixels.isNull || pixels.isEmpty ? nil : pixels
        }
    }

    /// The image with every redaction painted solid black.
    static func redact(_ image: CGImage, windowFrame: CGRect, redactions: [CGRect]) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let size = CGSize(width: width, height: height)
        for rect in imageRects(for: redactions, windowFrame: windowFrame, imageSize: size) {
            context.fill(CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
        }
        return context.makeImage()
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
