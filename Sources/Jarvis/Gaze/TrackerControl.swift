import Foundation

/// The menu-facing slice of tracker state, composed from one
/// `GET /snapshot` read. The label mirrors the tracker's own
/// `trayStateLabel` (electron/main.cjs) so the status item reports the
/// same state the Electron menu would — same precedence: pause outranks
/// calibration, calibration outranks face presence.
struct TrackerStatus: Sendable, Equatable {
    /// `/snapshot.paused` — the flag `pause_toggle` flips tracker-side.
    var paused = false
    /// `/snapshot.calibration_status` — "missing", "loaded", "invalid",
    /// "saved", "rejected_fit", … — "" when the tracker reports none.
    var calibration = ""
    /// `/snapshot.preview.head_detected`, counted only while the
    /// preview's own `updated_at` is fresh — a frozen preview keeps
    /// serving its last claim and would hold the label at "Tracking"
    /// through a wedge. nil = no live claim (absent slice or stale
    /// stamp; a preview with no parseable stamp keeps its raw claim —
    /// nothing disproves it).
    var headDetected: Bool?
    /// The preview slice's `head_detected` claim regardless of
    /// freshness — the label reads it to separate "the feed went quiet
    /// after seeing a face" ("No gaze") from "it never saw one"
    /// ("No face").
    var lastHeadDetected: Bool?
    /// `/snapshot.gaze` freshness — the fallback face signal when the
    /// preview slice is absent. nil = the tracker produced no gaze yet.
    var gazeFresh: Bool?
    /// `/snapshot.started_at` — when the tracker process booted. The label
    /// reads it for the boot grace: a tracker that has never produced a
    /// frame is "Starting" only briefly; past the window it is "No gaze",
    /// never "Tracking".
    var startedAt: Date?
    /// `/snapshot.settings` values the Settings surface edits — nil when
    /// the tracker serves no settings slice.
    var dotScale: Double?
    var dwellLock: Bool?
    /// `/snapshot.settings.gaze_dot_visible` — nil when the tracker serves
    /// no settings slice. Default in the renderer is hidden (Vision
    /// Pro-style); this reports the persisted override.
    var dotVisible: Bool?

    /// The preview slice updates slower than the gaze feed (camera
    /// frames, not the gaze pipeline) — a preview claim older than this
    /// reads as a frozen feed, not a live face.
    static let previewFreshnessWindow: TimeInterval = 3
    /// First-frame allowance for the label — mirrors the host's
    /// `gazeGraceWindow`: cold-boot shader compiles land inside it, a
    /// pipeline that never produced past it is dead air, not "Tracking".
    static let bootGraceWindow: TimeInterval = 45

    /// The state word the status item shows — same precedence as the
    /// tracker's own menu label, plus "No gaze" for a feed that went
    /// quiet after seeing a face.
    var label: String {
        if paused { return "Paused" }
        if calibration == "missing" || calibration == "invalid" {
            return "Needs calibration"
        }
        // "learning" is invisible calibration fitting from ordinary use —
        // gaze is live, so it reads like any tracking state.
        if !calibration.isEmpty, calibration != "loaded", calibration != "saved",
           calibration != "learning" {
            return "Calibrating"
        }
        if headDetected == false { return "No face" }
        if gazeFresh == false {
            // The gaze feed went quiet — "No gaze" when the tracker last
            // saw a face (it was tracking), "No face" when nothing says
            // it ever did.
            return (headDetected == true || lastHeadDetected == true)
                ? "No gaze" : "No face"
        }
        if gazeFresh == nil && headDetected == nil {
            // No gaze stamp, no live face claim — the tracker has never
            // produced a frame. Inside the boot grace that's still
            // "Starting"; past it the pipeline is dead air, not
            // "Tracking". No stamp means no proof it's still warming.
            guard let startedAt,
                  Date().timeIntervalSince(startedAt) <= Self.bootGraceWindow
            else { return "No gaze" }
            return "Starting"
        }
        return "Tracking"
    }
}

/// Why a tracker-control write or status read failed — kept distinct
/// from `GazeError` so a refused action never reads as a missing tracker.
enum TrackerControlError: Error, Equatable {
    /// Nothing answered — the tracker isn't running.
    case unreachable
    /// The tracker answered with a non-2xx — the action didn't land.
    case rejected(Int)
}

/// The tracker's control plane: `POST /control` mutates run state and
/// settings (`{"action": "<name>", "value": <any>}` — the action enum
/// lives in electron/externalApi.cjs); `GET /snapshot` feeds the
/// status-item label and the Settings surface with one cheap read.
/// Same posture as `GazeClient`: tight budgets, honest failures, an
/// injectable transport so tests open no socket.
struct TrackerControl: Sendable {
    var baseURL: URL
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(baseURL: URL? = nil,
         send: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.baseURL = baseURL ?? GazeClient.defaultBaseURL
        self.send = send ?? { request in try await Self.transport(request) }
    }

    /// Transport seam — URLSession in production, stubbed in tests so the
    /// static `post` and the drive loop's tracker verbs never touch a
    /// socket (same pattern as `GazePointer.poster`).
    static var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    /// One control POST — `{"action": "<name>"}`, plus `"value"` when the
    /// action takes one (`dot_scale`, `dwell_lock`). A dead socket reads
    /// as `.unreachable`; a non-2xx answer as `.rejected` — the caller
    /// decides whether silence or a spoken refusal is honest.
    func post(action: String, value: Any? = nil) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("control"))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["action": action]
        if let value { body["value"] = value }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response: URLResponse
        do {
            (_, response) = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces task cancellation as .cancelled — a
            // cancelled caller must see cancellation, never a false
            // "the tracker isn't running" refusal.
            throw CancellationError()
        } catch {
            throw TrackerControlError.unreachable
        }
        guard let code = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code) else {
            throw TrackerControlError.rejected(
                (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// The shared control surface — callers that don't need the seam
    /// post through the default client.
    static func post(action: String, value: Any? = nil) async throws {
        try await TrackerControl().post(action: action, value: value)
    }

    /// One snapshot read behind the status item and Settings — the whole
    /// snapshot is a single GET and carries every slice the label needs
    /// (`paused`, `calibration_status`, `preview`, `gaze`, `settings`).
    /// A dead socket, a non-2xx or an unreadable body is `.unreachable` —
    /// the menu dims rather than inventing a state from an error page.
    func status() async throws -> TrackerStatus {
        let data: Data
        let response: URLResponse
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("snapshot"))
            request.timeoutInterval = 2
            (data, response) = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TrackerControlError.unreachable
        }
        // `paused` is a real Bool on every snapshot the tracker serves
        // (externalStore seeds it false at boot) — a 200 that lacks it is
        // some other service's payload, and decoding it to the zero-value
        // status would paint "Tracking" over a tracker that isn't there.
        guard let code = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paused = snapshot["paused"] as? Bool else {
            throw TrackerControlError.unreachable
        }
        var status = TrackerStatus()
        status.paused = paused
        status.calibration = (snapshot["calibration_status"] as? String ?? "").lowercased()
        if let text = snapshot["started_at"] as? String {
            status.startedAt = Self.iso.date(from: text) ?? Self.isoNoFraction.date(from: text)
        }
        let settings = snapshot["settings"] as? [String: Any]
        status.dotScale = Self.num(settings?["dot_scale"])
        status.dwellLock = settings?["dwell_lock"] as? Bool
        status.dotVisible = settings?["gaze_dot_visible"] as? Bool
        if let preview = snapshot["preview"] as? [String: Any] {
            status.lastHeadDetected = preview["head_detected"] as? Bool
            // The preview slice carries its own `updated_at` — a frozen
            // feed keeps serving the last claim, so a stale stamp clears
            // `headDetected` rather than vouching for a face. No stamp
            // means nothing disproves the claim — it stands.
            var fresh = true
            if let text = preview["updated_at"] as? String,
               let stamp = Self.iso.date(from: text) ?? Self.isoNoFraction.date(from: text) {
                fresh = Date().timeIntervalSince(stamp) <= TrackerStatus.previewFreshnessWindow
            }
            status.headDetected = fresh ? status.lastHeadDetected : nil
        }
        if let gaze = snapshot["gaze"] as? [String: Any],
           let text = gaze["updated_at"] as? String,
           let stamp = Self.iso.date(from: text) ?? Self.isoNoFraction.date(from: text) {
            status.gazeFresh = Date().timeIntervalSince(stamp) <= GazeSample.freshnessWindow
        }
        return status
    }

    /// The host feature switch — the tracker can't enable itself, and
    /// the Config publisher in the app delegate owns the spawn/stop.
    static func setTrackingEnabled(_ enabled: Bool) async {
        await MainActor.run { Config.shared.gazeTracking = enabled }
    }

    private static func num(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFraction = ISO8601DateFormatter()
}
