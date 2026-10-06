import Foundation
import JevVoiceCore

/// App-roster authority, split in two:
/// - The installed map: name→bundle_id rows for every app on disk, cached
///   ≥30min — built from the driver's last `list_apps` merged with a flat
///   `.app` listing of the standard Applications folders. A cold or dead
///   driver never degrades routing to running-only: an installed app that
///   is not running (Calendar) still resolves.
/// - Live fields (`running`, `pid`) ride only on rows a live read supplied
///   — the installed map itself never claims liveness. Process/window
///   authority still comes from fresh Driver observations.
@MainActor
final class CuaAppInventory {
    /// The roster shape: `{apps:[{name,bundle_id,running,pid}]}`.
    typealias Snapshot = JSONValue

    /// Install churn is human-scale — a half-hour between scans loses
    /// nothing, and the scan itself is a directory listing cheaper than a
    /// driver roundtrip.
    static let installedTTL: TimeInterval = 30 * 60
    /// bundle_id(lowercased) → installed row. Rebuilt lazily per TTL.
    private var installedCache: (fetched: Date, rows: [String: JSONValue])?
    /// The driver's last shaped rows — bundles installed outside the
    /// scanned folders only ever arrive through `list_apps`.
    private var lastDriverRows: [JSONValue] = []

    /// Validates and trims one raw list_apps response. `running`/`pid` ride
    /// along as advisory hints for fast-lane target disambiguation only —
    /// dispatch authority still comes from fresh reads. The rows also
    /// refresh the installed map's driver-side memory.
    func read(fetch: () async throws -> JSONValue) async throws -> JSONValue {
        let observed = try await fetch()
        try Task.checkCancellation()
        guard let apps = observed["apps"]?.array else { throw DriverConnectionError.malformed }
        let names = apps.compactMap { app -> JSONValue? in
            guard let name = app["name"]?.string, let bundle = app["bundle_id"]?.string, !bundle.isEmpty else { return nil }
            return .object(["name": .string(name), "bundle_id": .string(bundle),
                            "running": app["running"] ?? .bool(false),
                            "pid": app["pid"] ?? .number(0)])
        }
        noteDriverApps(names)
        return .object(["apps": .array(names)])
    }

    /// A driver `list_apps` read lands here from the runtime's roster path
    /// (which bypasses `read` for freshness) — the installed map picks up
    /// driver-reported bundles without waiting out the TTL.
    func noteDriverApps(_ rows: [JSONValue]) {
        lastDriverRows = rows
        guard var cached = installedCache else { return }
        for row in rows {
            guard let bundle = row["bundle_id"]?.string, !bundle.isEmpty,
                  let name = row["name"]?.string, !name.isEmpty else { continue }
            if cached.rows[bundle.lowercased()] == nil {
                cached.rows[bundle.lowercased()] = Self.installedRow(name: name, bundle: bundle)
            }
        }
        installedCache = cached
    }

    /// Every installed app overlaid with the caller's live rows: name→bundle
    /// resolution never degrades to running-only, while `running`/`pid` come
    /// only from `live`, so nothing claims liveness it did not observe.
    /// Routing data, never dispatch authority.
    func installedRoster(merging live: [JSONValue]) -> [JSONValue] {
        var rows = installedRows()
        for row in live {
            guard let bundle = row["bundle_id"]?.string, !bundle.isEmpty else { continue }
            let key = bundle.lowercased()
            guard var installed = rows[key]?.object else {
                // A running app outside the scanned folders — driver or
                // NSWorkspace reported it, so it enters whole.
                rows[key] = row
                continue
            }
            installed["running"] = row["running"] ?? .bool(true)
            installed["pid"] = row["pid"] ?? .number(0)
            if let name = row["name"]?.string, !name.isEmpty {
                installed["name"] = .string(name)
            }
            rows[key] = .object(installed)
        }
        return Array(rows.values)
    }

    /// bundle→installed-row map, rebuilt at most once per `installedTTL`.
    private func installedRows() -> [String: JSONValue] {
        if let cached = installedCache,
           Date().timeIntervalSince(cached.fetched) < Self.installedTTL {
            return cached.rows
        }
        var rows = Self.scanInstalledApps()
        // The driver's spelling wins — its names are localized where the
        // scan's are file names — and it covers apps outside the folders.
        for row in lastDriverRows {
            guard let bundle = row["bundle_id"]?.string, !bundle.isEmpty,
                  let name = row["name"]?.string, !name.isEmpty else { continue }
            rows[bundle.lowercased()] = Self.installedRow(name: name, bundle: bundle)
        }
        installedCache = (Date(), rows)
        return rows
    }

    /// A flat `.app` listing of the standard install folders plus each
    /// bundle's Info.plist id — no recursion, no liveness, no transport.
    static func scanInstalledApps() -> [String: JSONValue] {
        var rows: [String: JSONValue] = [:]
        for directory in applicationDirectories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
            else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                guard let bundle = Bundle(path: directory + "/" + entry)?.bundleIdentifier,
                      !bundle.isEmpty else { continue }
                rows[bundle.lowercased()] = installedRow(
                    name: String(entry.dropLast(".app".count)), bundle: bundle)
            }
        }
        return rows
    }

    /// The standard install locations — `/System/Applications/Utilities`
    /// keeps Terminal and Activity Monitor reachable, `~/Applications`
    /// covers per-user installs.
    static var applicationDirectories: [String] {
        ["/Applications", "/System/Applications", "/System/Applications/Utilities",
         NSHomeDirectory() + "/Applications"]
    }

    private static func installedRow(name: String, bundle: String) -> JSONValue {
        .object(["name": .string(name), "bundle_id": .string(bundle),
                 "running": .bool(false), "pid": .number(0)])
    }
}
