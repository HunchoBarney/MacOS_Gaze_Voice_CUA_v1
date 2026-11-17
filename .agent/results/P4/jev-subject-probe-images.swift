import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4, let source = NSImage(contentsOfFile: arguments[1]) else {
    fatalError("source image, output directory and image prefix required")
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
for (suffix, account, document) in [
    ("original", "Account A", "Document Alpha"),
    ("account", "Account B", "Document Alpha"),
    ("document", "Account A", "Document Beta"),
    ("unknown", "Account A", "Document Unknown"),
] {
    let size = NSSize(width: source.size.width, height: source.size.height + 80)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("bitmap context failed")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    source.draw(in: NSRect(origin: .zero, size: source.size))
    let style: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    (account as NSString).draw(at: NSPoint(x: 20, y: size.height - 32), withAttributes: style)
    (document as NSString).draw(at: NSPoint(x: 20, y: size.height - 62), withAttributes: style)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    try png.write(to: output.appendingPathComponent("\(arguments[3])-\(suffix).png"),
                  options: .withoutOverwriting)
}
