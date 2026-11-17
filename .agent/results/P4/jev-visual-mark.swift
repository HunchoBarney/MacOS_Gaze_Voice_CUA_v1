import AppKit
import Darwin
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard [5, 7].contains(arguments.count),
      let x = Double(arguments[2]), let y = Double(arguments[3]),
      x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      CGImageSourceGetCount(source) == 1,
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    exit(64)
}
var image = original
var point = CGPoint(x: x * Double(original.width), y: y * Double(original.height))
if arguments.count == 7 {
    guard let requestedWidth = Double(arguments[5]), let requestedHeight = Double(arguments[6]),
          requestedWidth.isFinite, requestedHeight.isFinite,
          requestedWidth > 0, requestedHeight > 0 else { exit(64) }
    let width = min(Double(original.width), max(280, ceil(requestedWidth)))
    let height = min(Double(original.height), max(280, ceil(requestedHeight)))
    let rect = CGRect(x: max(0, min(Double(original.width) - width, floor(point.x - width / 2))),
                      y: max(0, min(Double(original.height) - height, floor(point.y - height / 2))),
                      width: width, height: height)
    guard let crop = original.cropping(to: rect) else { exit(65) }
    image = crop
    point.x -= rect.minX
    point.y -= rect.minY
}
guard let context = CGContext(data: nil, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(64)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
point.y = Double(image.height) - point.y
context.setStrokeColor(CGColor(gray: 0, alpha: 1))
context.setLineWidth(6)
context.strokeEllipse(in: CGRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30))
context.setStrokeColor(CGColor(gray: 1, alpha: 1))
context.setLineWidth(3)
context.strokeEllipse(in: CGRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30))
guard let marked = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: marked).representation(using: .png, properties: [:]) else {
    exit(65)
}
let descriptor = Darwin.open(arguments[4], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
guard descriptor >= 0 else { exit(73) }
let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
defer { try? file.close() }
try file.write(contentsOf: png)
