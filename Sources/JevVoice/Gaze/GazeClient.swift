import Foundation

/// One gaze sample from the eye tracker's external read-only API —
/// `GET /snapshot/gaze` on `TrackerHost.port`.
///
/// Despite the wire names (`x_px`/`y_px`), the tracker computes these as
/// `display.bounds.origin + norm * bounds.size` where Electron display
/// bounds are DIPs in the global top-left screen space — the same space
/// `CGEvent` locations and `NSWindow` frame origins (after the Cocoa
/// bottom-left flip) use. Treat the values as screen *points*: host-side
/// event posts take them verbatim, driver `scope:"desktop"` pixel calls
/// take `point * screen.backingScaleFactor`.
struct GazeSample: Sendable, Equatable {
    /// Screen-space point under the user's gaze (global top-left points).
    var x: Double
    var y: Double
    /// Tracker's own confidence in the sample (0…1).
    var confidence: Double
    /// Tracker's fixation state, e.g. "fixation", "saccade", "dwell".
    var state: String
    /// When the tracker produced the sample (its clock, parsed from
    /// `updated_at` — nil when unparseable, which counts as stale).
    var updatedAt: Date?
    var capturedAt: Date?
    var observedAt: Date? { capturedAt ?? updatedAt }

    /// A sample older than this was taken before the user finished the
    /// sentence — acting on it means clicking where they *were*, not
    /// where they are.
    static let freshnessWindow: TimeInterval = 1.5
    /// Below this the tracker itself isn't sure of the point.
    static let confidenceFloor = 0.4

    var isFresh: Bool {
        isFresh(within: Self.freshnessWindow)
    }

    func isFresh(within limit: TimeInterval) -> Bool {
        guard let observedAt else { return false }
        return (0...limit).contains(Date().timeIntervalSince(observedAt))
    }
}

/// Why a gaze-referent command can't dispatch — each maps to an honest
/// spoken sentence, never a silent fallthrough to a guessed target.
enum GazeError: Error, Equatable {
    /// Nothing answered at the tracker API — it isn't running.
    case unreachable
    /// Answered, but too old to describe the user's current intent.
    case stale
    /// Answered fresh, but the tracker isn't sure where the user is looking.
    case lowConfidence
    /// The response didn't decode into a usable sample.
    case malformed

    var userFacing: String {
        switch self {
        case .unreachable:
            return "The eye tracker isn't answering — it may not be running."
        case .stale:
            return "The gaze reading is stale — the tracker hasn't seen your eyes recently."
        case .lowConfidence:
            return "The eye tracker isn't confident about where you're looking right now."
        case .malformed:
            return "The eye tracker answered with data I couldn't read."
        }
    }
}

/// Thin client for the tracker's read-only HTTP API. Fetch is injectable —
/// tests never open a socket. Polling on demand (at verb time) keeps the
/// freshest possible sample and avoids a standing connection.
struct GazeClient: Sendable {
    var baseURL: URL
    /// Injectable transport. Production: URLSession with a tight budget —
    /// a hung tracker must fail fast, not park the utterance.
    var fetch: @Sendable (URL) async throws -> Data

    init(baseURL: URL? = nil,
         fetch: (@Sendable (URL) async throws -> Data)? = nil) {
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        }
    }

    static var defaultBaseURL: URL {
        let env = TrackerHost.releaseProfile == nil ? ProcessInfo.processInfo.environment["JARVIS_GAZE_URL"] : nil
        return URL(string: env ?? "http://127.0.0.1:\(TrackerHost.port)")!
    }

    /// The current gaze point, gated on freshness + tracker confidence so a
    /// referent verb never acts on a point the tracker itself distrusts.
    func snapshot() async throws -> GazeSample {
        let data: Data
        do {
            data = try await fetch(baseURL.appendingPathComponent("snapshot/gaze"))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // A cancelled turn must read as cancelled — the callers'
            // CancellationError pass-throughs can't see one if this
            // repackages it as a dead-tracker refusal.
            throw CancellationError()
        } catch {
            throw GazeError.unreachable
        }
        return try Self.decode(data)
    }

    /// The tracker display's rect in global top-left points —
    /// `/snapshot/display.bounds` — plus its index. Used to pick the
    /// `NSScreen` whose backing scale converts gaze points into the
    /// driver's desktop pixel space. nil when unreachable.
    func display() async -> (index: Int, bounds: CGRect)? {
        guard let data = try? await fetch(baseURL.appendingPathComponent("snapshot/display")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let b = obj["bounds"] as? [String: Any]
        let rect = CGRect(x: Self.num(b?["x"]) ?? 0, y: Self.num(b?["y"]) ?? 0,
                          width: Self.num(b?["width"]) ?? 0,
                          height: Self.num(b?["height"]) ?? 0)
        return (Self.num(obj["display_index"]).map(Int.init) ?? 0, rect)
    }

    static func decode(_ data: Data) throws -> GazeSample {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = num(obj["x_px"]), let y = num(obj["y_px"]) else {
            throw GazeError.malformed
        }
        guard obj["held_reason"] == nil, obj["away"] as? Bool != true,
              obj["blink"] as? Bool != true, obj["head_turned"] as? Bool != true
        else { throw GazeError.lowConfidence }
        let captured = captureTime(obj["captured_at_ms"])
        if obj["captured_at_ms"] != nil && captured == nil { throw GazeError.malformed }
        let sample = GazeSample(
            x: x, y: y,
            confidence: num(obj["confidence"]) ?? 0,
            state: obj["gaze_state"] as? String ?? "",
            updatedAt: receiptTime(obj["updated_at"]), capturedAt: captured)
        guard sample.isFresh else { throw GazeError.stale }
        guard sample.confidence >= GazeSample.confidenceFloor else {
            throw GazeError.lowConfidence
        }
        return sample
    }

    static func captureTime(_ value: Any?) -> Date? {
        guard let ms = num(value), ms.isFinite else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static func receiptTime(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoFormatter.date(from: text) ?? isoFormatterNoFraction.date(from: text)
    }

    private static func num(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFraction = ISO8601DateFormatter()
}
