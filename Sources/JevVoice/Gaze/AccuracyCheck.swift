import Foundation

/// Settings → "Check eye-tracking accuracy". Asks the running tracker for a
/// full calibration followed by the JARA-27 protocol v1 accuracy grid and
/// hit test (POST /control accuracy_check), then waits for the
/// accuracy_report.json the tracker writes beside its calibration file and
/// turns it into one plain sentence.
@MainActor
final class AccuracyCheck: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var message = "Takes about four minutes: follow the dot, then look at each target until it moves."

    /// Calibration (~1 min) + 16 targets × 1.5 s + up to 75 trials × 2 s,
    /// with margin for a calibration retry.
    static let timeout: TimeInterval = 8 * 60
    private var task: Task<Void, Never>?

    func start() {
        guard !running else { return }
        running = true
        message = "Running — follow the dot on screen. Press Esc to stop."
        let started = Date()
        task = Task { [weak self] in
            do {
                try await TrackerControl.post(action: "accuracy_check")
            } catch {
                self?.finish("The eye tracker isn't running — turn on “Track my eyes” and try again.")
                return
            }
            let report = GazeErrorBand.directory?.appendingPathComponent("accuracy_report.json")
            while !Task.isCancelled, Date().timeIntervalSince(started) < Self.timeout {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let report,
                      let modified = (try? report.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified > started,
                      let data = try? Data(contentsOf: report)
                else { continue }
                self?.finish(Self.summary(from: data) ?? "The check finished but its report couldn't be read.")
                return
            }
            self?.finish("No result — the check was stopped or calibration didn't pass. Try again in good light.")
        }
    }

    private func finish(_ text: String) {
        message = text
        running = false
        task = nil
    }

    /// Plain-words result: typical error, the 90% bound, and the smallest
    /// target hit 9 times in 10 (S90).
    static func summary(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let overall = (root["held_out"] as? [String: Any])?["overall"] as? [String: Any],
              let median = (overall["median_deg"] as? NSNumber)?.doubleValue,
              let p90 = (overall["p90_deg"] as? NSNumber)?.doubleValue
        else { return nil }
        let deg = { (v: Double) in String(format: "%.1f°", v) }
        var text = "Typical error \(deg(median)); 9 in 10 targets were within \(deg(p90))."
        if let hit = root["hit_test"] as? [String: Any] {
            if let s90 = (hit["s90_deg"] as? NSNumber)?.doubleValue {
                text += " You hit targets \(deg(s90)) in radius or larger 9 times in 10."
            } else {
                text += " No target size up to 3° was hit 9 times in 10."
            }
        }
        return text
    }
}
