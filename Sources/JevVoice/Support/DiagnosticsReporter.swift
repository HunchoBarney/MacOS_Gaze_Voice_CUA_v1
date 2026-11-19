import Foundation
import MetricKit
import OSLog

/// The diagnostic floor a shipped app needs: MetricKit crash, hang and
/// resource reports are kept on disk, and one export bundles them with this
/// launch's logs. Nothing is uploaded; the user decides what to share.
final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber {
    private let directory: URL
    private let subsystem = "com.chriswozniczek.jevvoice"
    private let keep = 20

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("JevVoice/Diagnostics", isDirectory: true)) {
        self.directory = directory
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "diagnostic") }
    }

    func save(_ data: Data, kind: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(kind)-\(Int(Date().timeIntervalSince1970 * 1000)).json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        let stale = storedReports().dropFirst(keep)
        for url in stale { try? FileManager.default.removeItem(at: url) }
    }

    /// Newest first.
    func storedReports() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
    }

    func exportReport(latency: String, logs: [String]? = nil) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        var sections = [
            "Jev Voice \(version) (\(build)) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Exported \(ISO8601DateFormatter().string(from: Date()))",
            "== Latency ==\n" + latency,
            "== Logs (this launch) ==\n" + (logs ?? recentLogs()).joined(separator: "\n"),
        ]
        for url in storedReports() {
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "(unreadable)"
            sections.append("== \(url.lastPathComponent) ==\n" + body)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private func recentLogs() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return ["(logs unavailable)"]
        }
        let since = store.position(timeIntervalSinceLatestBoot: 0)
        let predicate = NSPredicate(format: "subsystem BEGINSWITH %@", subsystem)
        let formatter = ISO8601DateFormatter()
        guard let entries = try? store.getEntries(at: since, matching: predicate) else {
            return ["(logs unavailable)"]
        }
        return entries.compactMap { $0 as? OSLogEntryLog }.suffix(2_000).map {
            "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)"
        }
    }
}
