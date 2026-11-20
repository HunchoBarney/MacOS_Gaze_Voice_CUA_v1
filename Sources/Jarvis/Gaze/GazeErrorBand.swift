import CoreGraphics
import Foundation

/// The user's measured gaze error in screen points — what spreads gaze
/// evidence instead of a fixed guess. Three reports sit beside the
/// tracker's calibration file and the newest wins: the held-out accuracy
/// test (`accuracy_report.json`, `error_px.overall.median`), the
/// calibration's own verify pass (`calibration_report.json`, `median_pt`)
/// and invisible calibration's running label error (`learning_report.json`,
/// `median_pt`, rewritten as ordinary use labels the map). A recalibration
/// therefore supersedes an older accuracy run, and everyday use keeps the
/// band honest as the learned map improves or drifts.
enum GazeErrorBand {
    /// σ with no measurement yet: invisible calibration is still on its
    /// prior or the raw projection, which the literature puts at 4–7°
    /// before any personal data. 150 pt is a ~4° median at 50 cm, so the
    /// band stays wide until the first learning report narrows it.
    static let fallbackSigmaPt: Double = 150
    /// Below ~0.5° the webcam can't honestly claim more.
    static let minimumSigmaPt: Double = 20
    /// Median radial error of an isotropic 2-D Gaussian is σ·√(2 ln 2).
    static let medianToSigma = 1 / (2 * log(2.0)).squareRoot()

    /// Settable for tests; production resolves the tracker's calibration dir.
    static var directory: URL? = TrackerHost.trackerDirectory()
        .map { TrackerHost.calibrationDirectory(trackerDir: $0) }

    static func medianErrorPt(in directory: URL? = directory) -> Double? {
        guard let directory else { return nil }
        let sources: [(file: String, path: [String])] = [
            ("accuracy_report.json", ["error_px", "overall", "median"]),
            ("calibration_report.json", ["median_pt"]),
            ("learning_report.json", ["median_pt"]),
        ]
        var best: (date: Date, value: Double)?
        for source in sources {
            let url = directory.appendingPathComponent(source.file)
            guard let data = try? Data(contentsOf: url),
                  var node = try? JSONSerialization.jsonObject(with: data) as Any
            else { continue }
            for key in source.path {
                guard let next = (node as? [String: Any])?[key] else { node = NSNull(); break }
                node = next
            }
            guard let value = (node as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || date > best!.date { best = (date, value) }
        }
        return best?.value
    }

    /// The scorer's Gaussian σ from the measured median error.
    static func sigmaPt(in directory: URL? = directory) -> Double {
        guard let median = medianErrorPt(in: directory) else { return fallbackSigmaPt }
        return max(minimumSigmaPt, median * medianToSigma)
    }

    /// Gaze narrows voice picks: the candidates whose frame lies within
    /// `bandPt` of the gaze point, nearest edge first. Containing frames
    /// read distance 0 and rank smallest-first, so a button beats the
    /// window around it. nil frames never match.
    static func nearest(frames: [CGRect?], to point: CGPoint, bandPt: Double) -> [(index: Int, distance: Double)] {
        frames.enumerated()
            .compactMap { index, frame -> (index: Int, distance: Double, area: Double)? in
                guard let frame else { return nil }
                let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
                let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
                let distance = Double((dx * dx + dy * dy).squareRoot())
                return distance <= bandPt ? (index, distance, Double(frame.width * frame.height)) : nil
            }
            .sorted { ($0.distance, $0.area) < ($1.distance, $1.area) }
            .map { ($0.index, $0.distance) }
    }
}
