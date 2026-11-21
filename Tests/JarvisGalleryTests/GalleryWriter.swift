import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// The manifest fragment the gallery site reads (gallery/README.md).
/// Image sizes are in pixels; scale turns them back into points.
struct GalleryVariant: Codable {
    var scheme: String
    var reduceMotion: Bool
    var image: String
    var width: Int
    var height: Int
    var scale: Int
    var backdrop: String
}

struct GalleryClip: Codable {
    var scheme: String
    var reduceMotion: Bool
    var video: String
    var poster: String
    var width: Int
    var height: Int
    var durationMs: Int
    var caption: String?
}

struct GalleryState: Codable {
    var id: String
    var title: String
    var note: String?
    var kind: String?
    var superseded: String?
    var variants: [GalleryVariant] = []
    var clips: [GalleryClip]?
}

struct GalleryComponent: Codable {
    var id: String
    var title: String
    var area: String
    var summary: String
    var sources: [String]
    var owner: String?
    var states: [GalleryState]
}

struct GalleryScene: Codable {
    var id: String
    var title: String
    var summary: String
    var components: [String]
    var image: String
    var width: Int
    var height: Int
    var clip: GalleryClip?
    var kind: String?
    var superseded: String?
}

struct GalleryFragment: Codable {
    var producer = "native"
    var commit: String
    var generatedAt: String
    var components: [GalleryComponent]
    var scenes: [GalleryScene]
}

struct GalleryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Scheme: String, CaseIterable {
    case light, dark

    var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
}

/// A timed frame for a clip: seconds from the clip's start.
struct ClipFrame {
    var time: Double
    var image: CGImage
}

/// Writes PNGs, MP4s and the manifest fragment under the output folder.
@MainActor
final class GalleryWriter {
    /// Every "proposed" mockup this harness draws is from the JARA-56 audit,
    /// which the owner rejected; they stay on the site for the record.
    static let supersededProposals = "Superseded. The owner rejected these proposed directions on 2026-11-21, and JARA-57 owns the redesign. Kept for the record only."
    let out: URL
    let scale: CGFloat = 2
    private(set) var components: [GalleryComponent] = []
    private(set) var scenes: [GalleryScene] = []

    init(out: URL) throws {
        self.out = out
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    func declare(_ id: String, title: String, area: String, summary: String,
                 sources: [String], owner: String? = nil) {
        guard !components.contains(where: { $0.id == id }) else { return }
        components.append(GalleryComponent(id: id, title: title, area: area, summary: summary,
                                           sources: sources, owner: owner, states: []))
    }

    private func slot(_ component: String, _ state: String, title: String, note: String?,
                      kind: String?) throws -> (Int, Int) {
        guard let c = components.firstIndex(where: { $0.id == component }) else {
            throw GalleryError("undeclared component \(component)")
        }
        if let s = components[c].states.firstIndex(where: { $0.id == state }) { return (c, s) }
        components[c].states.append(GalleryState(id: state, title: title, note: note, kind: kind,
                                                 superseded: kind == "proposed" ? Self.supersededProposals : nil))
        return (c, components[c].states.count - 1)
    }

    func still(_ image: CGImage, component: String, state: String, title: String,
               note: String? = nil, kind: String? = nil, scheme: Scheme, reduceMotion: Bool,
               backdrop: String) throws {
        let (c, s) = try slot(component, state, title: title, note: note, kind: kind)
        let name = "\(component)/\(state)-\(scheme.rawValue)\(reduceMotion ? "-rm" : "").png"
        try writePNG(image, to: out.appendingPathComponent(name))
        components[c].states[s].variants.append(GalleryVariant(
            scheme: scheme.rawValue, reduceMotion: reduceMotion, image: name,
            width: image.width, height: image.height, scale: Int(scale), backdrop: backdrop))
    }

    func clip(_ frames: [ClipFrame], component: String, state: String, title: String,
              note: String? = nil, kind: String? = nil, scheme: Scheme, reduceMotion: Bool,
              caption: String?) throws {
        let (c, s) = try slot(component, state, title: title, note: note, kind: kind)
        let entry = try encode(frames, base: "\(component)/\(state)-\(scheme.rawValue)\(reduceMotion ? "-rm" : "")",
                               scheme: scheme, reduceMotion: reduceMotion, caption: caption)
        components[c].states[s].clips = (components[c].states[s].clips ?? []) + [entry]
    }

    func scene(_ image: CGImage, id: String, title: String, summary: String, components ids: [String],
               kind: String? = nil, clip: [ClipFrame]? = nil, scheme: Scheme) throws {
        let name = "scenes/\(id).png"
        try writePNG(image, to: out.appendingPathComponent(name))
        let encoded = try clip.map {
            try encode($0, base: "scenes/\(id)", scheme: scheme, reduceMotion: false, caption: nil)
        }
        scenes.append(GalleryScene(id: id, title: title, summary: summary, components: ids, image: name,
                                   width: image.width, height: image.height, clip: encoded, kind: kind,
                                   superseded: kind == "proposed" ? Self.supersededProposals : nil))
    }

    private func encode(_ frames: [ClipFrame], base: String, scheme: Scheme, reduceMotion: Bool,
                        caption: String?) throws -> GalleryClip {
        guard let poster = frames.last?.image else { throw GalleryError("empty clip \(base)") }
        try ClipEncoder.encode(frames, to: out.appendingPathComponent(base + ".mp4"))
        try writePNG(poster, to: out.appendingPathComponent(base + ".poster.png"))
        let duration = Int(((frames.last?.time ?? 0) + 0.4) * 1000)
        return GalleryClip(scheme: scheme.rawValue, reduceMotion: reduceMotion, video: base + ".mp4",
                           poster: base + ".poster.png", width: poster.width & ~1, height: poster.height & ~1,
                           durationMs: duration, caption: caption)
    }

    func writeManifest(commit: String) throws {
        let fragment = GalleryFragment(commit: commit, generatedAt: ISO8601DateFormatter().string(from: Date()),
                                       components: components, scenes: scenes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(fragment).write(to: out.appendingPathComponent("manifest.native.json"))
    }
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw GalleryError("can't write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw GalleryError("can't finish \(url.path)") }
}

/// H.264 MP4s from timed frames with AVFoundation, so the gallery needs no
/// ffmpeg. Frames keep their own timestamps, so a clip keeps real timing.
enum ClipEncoder {
    static func encode(_ frames: [ClipFrame], to url: URL) throws {
        guard let first = frames.first?.image else { throw GalleryError("no frames for \(url.lastPathComponent)") }
        let width = first.width & ~1, height = first.height & ~1
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GalleryError("writer didn't start") }
        writer.startSession(atSourceTime: .zero)
        var last = -1.0
        var padded = frames
        if let tail = frames.last { padded.append(ClipFrame(time: tail.time + 0.4, image: tail.image)) }
        for frame in padded where frame.time > last {
            last = frame.time
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { throw GalleryError("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw GalleryError("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.setFillColor(NSColor.black.cgColor)
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context?.draw(frame.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: frame.time, preferredTimescale: 600))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? GalleryError("writer failed") }
    }

    /// Frame folders other producers leave (gallery/tracker): <name>.frames/0000.png…
    /// plus clip.json {"fps": 60} become <name>.mp4 and <name>.poster.png.
    static func encodeFrameFolders(under root: URL) throws -> [String] {
        var encoded: [String] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let folders = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "frames" }
        for folder in folders {
            var fps = 60.0
            if let data = try? Data(contentsOf: folder.appendingPathComponent("clip.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json["fps"] as? Double { fps = value }
            let pngs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let frames: [ClipFrame] = pngs.enumerated().compactMap { index, url in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                return ClipFrame(time: Double(index) / fps, image: image)
            }
            guard let poster = frames.last?.image else { continue }
            let base = folder.deletingPathExtension()
            try encode(frames, to: base.appendingPathExtension("mp4"))
            try writePNG(poster, to: URL(fileURLWithPath: base.path + ".poster.png"))
            encoded.append(base.lastPathComponent)
        }
        return encoded
    }
}
