import Foundation
import JevVoiceCore

/// A parse is usable only for the immutable capture and window that requested it.
/// Driver owns the screenshot-to-screen transform; actions retain screenshot pixels.
struct CuaVisualObservation {
    let captureID: String
    let regions: [JSONValue]
    let actions: [CuaObservedAction]

    init(_ output: JSONValue, captureID: String, pid: Int, window: Int) throws {
        guard !captureID.isEmpty, pid > 0, window > 0,
              output["schema"] == .string("cua.visual_regions_v1"),
              let capture = output["capture"], capture["capture_id"] == .string(captureID),
              capture["source"]?["kind"] == .string("window"),
              capture["source"]?["pid"]?.integer == pid,
              capture["source"]?["window_id"]?.integer == window,
              let screenshot = capture["screenshot"],
              let reference = screenshot["reference"]?.string, !reference.isEmpty,
              screenshot["mime_type"] == .string("image/png"),
              let width = screenshot["width"]?.integer, width > 0,
              let height = screenshot["height"]?.integer, height > 0,
              let space = capture["action_coordinate_space"],
              let regions = output["regions"]?.array else { throw DriverConnectionError.malformed }

        switch space["kind"]?.string {
        case "screenshot_pixels": break
        case "affine":
            guard ["m11", "m12", "m21", "m22", "tx", "ty"].allSatisfy({ Self.number(space[$0]) != nil }),
                  let a = Self.number(space["m11"]), let b = Self.number(space["m12"]),
                  let c = Self.number(space["m21"]), let d = Self.number(space["m22"]),
                  (a * d - b * c).isFinite, a * d - b * c != 0 else { throw DriverConnectionError.malformed }
        default: throw DriverConnectionError.malformed
        }

        var ids = Set<String>()
        var actions: [CuaObservedAction] = []
        for region in regions {
            guard let id = region["id"]?.string, !id.isEmpty, ids.insert(id).inserted,
                  let kind = region["kind"]?.string, ["text", "icon"].contains(kind),
                  let confidence = Self.number(region["confidence"]), (0...1).contains(confidence),
                  region["interactive"]?.bool != nil,
                  let bounds = region["bounds"],
                  let x = bounds["x"]?.integer, x >= 0, x < width,
                  let y = bounds["y"]?.integer, y >= 0, y < height,
                  let w = bounds["width"]?.integer, w > 0, w <= width - x,
                  let h = bounds["height"]?.integer, h > 0, h <= height - y else { throw DriverConnectionError.malformed }

            let label = [region["text"]?.string, region["label"]?.string]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            // Unlabelled icons remain in observation context, but are not invented
            // semantic commands. Grounding them needs spatial or adjacent evidence.
            guard let label else { continue }
            actions.append(.init(description: "Click visual \(kind) \(label) [region \(id)]", tool: "click", arguments: [
                "pid": .number(Double(pid)), "window_id": .number(Double(window)),
                "capture_id": .string(captureID),
                "x": .number(Double(x) + Double(w) / 2),
                "y": .number(Double(y) + Double(h) / 2),
                "delivery_mode": .string("background")
            ]))
        }
        self.captureID = captureID
        self.regions = regions
        self.actions = actions
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number) = value, number.isFinite else { return nil }
        return number
    }
}
