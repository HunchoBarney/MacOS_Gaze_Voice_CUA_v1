import Foundation
import AppKit
import Vision
import JevVoiceCore

/// OCR helper for test tooling: recognizes text in a window capture when the
/// accessibility tree exposes nothing readable (a terminal's scrollback is
/// pixels, not AX values). Not part of the production action path.
enum CuaVisionRegions {
    static func recognize(file: URL, width: Int, height: Int) -> [JSONValue]? {
        guard let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var regions: [JSONValue] = []
        let request = VNRecognizeTextRequest { request, _ in
            for observation in (request.results as? [VNRecognizedTextObservation]) ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let box = observation.boundingBox
                regions.append(.object([
                    "text": .string(candidate.string),
                    "frame": .object([
                        "x": .number(box.origin.x * Double(width)),
                        "y": .number((1 - box.origin.y - box.height) * Double(height)),
                        "width": .number(box.width * Double(width)),
                        "height": .number(box.height * Double(height))])]))
            }
        }
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return regions.isEmpty ? nil : regions
    }
}
