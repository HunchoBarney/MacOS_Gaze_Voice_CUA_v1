import AppKit
import Foundation
import JarvisCore

/// Resolves a spoken app name ("Spotify", "my browser") to something the
/// driver can launch: a bundle id when we can prove one, else the raw name.
/// Running apps are matched against `list_apps`; dormant ones fall back to
/// LaunchServices' own app lookup. No inventory, no scoring graph — the
/// driver refuses honestly when the name resolves to nothing.
actor AppResolver {
    struct App: Sendable {
        var name: String
        var bundle: String?
        var pid: Int?
    }

    private var running: (at: Date, apps: [App])?
    private let listApps: () async throws -> [App]
    private let exactBundleApps: ((String) -> [App])?
    private let installedApp: (String) -> App?

    init() {
        self.init(exactBundleApps: { query in
            Self.apps(NSRunningApplication.runningApplications(withBundleIdentifier: query))
        }, listApps: {
            Self.apps(NSWorkspace.shared.runningApplications)
        })
    }

    /// `installedApp` is the dormant fallback for a name no running app
    /// matches. It reads LaunchServices and the Applications folders by
    /// default; tests pass a fixture so the result never depends on what
    /// this Mac has installed.
    init(listApps: @escaping () async throws -> [App],
         installedApp: @escaping (String) -> App? = AppResolver.installedLookup) {
        self.listApps = listApps
        self.exactBundleApps = nil
        self.installedApp = installedApp
    }

    init(exactBundleApps: @escaping (String) -> [App],
         listApps: @escaping () async throws -> [App],
         installedApp: @escaping (String) -> App? = AppResolver.installedLookup) {
        self.listApps = listApps
        self.exactBundleApps = exactBundleApps
        self.installedApp = installedApp
    }

    private static func apps(_ applications: [NSRunningApplication]) -> [App] {
        applications.compactMap { app in
            guard let name = app.localizedName else { return nil }
            return App(name: name, bundle: app.bundleIdentifier,
                       pid: Int(app.processIdentifier))
        }
    }

    func resolve(_ query: String) async -> App? {
        await resolveDetailed(query).app
    }

    /// Same pipeline as `resolve`, plus every equal-tier candidate sorted
    /// by name — a caller that must refuse a named ambiguity ("Devin"
    /// matching two running apps) needs the set, not a silent first pick.
    /// `app` keeps resolve's semantics: the winning tier's first match,
    /// the dormant hit, or the honest name-only fallback.
    func resolveDetailed(_ query: String) async -> (app: App?, matches: [App]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return (nil, []) }
        let needle = q.lowercased()
        var hits = exactBundleApps?(q).filter {
            ($0.pid ?? 0) > 0 && $0.bundle?.lowercased() == needle
        } ?? []
        if hits.isEmpty { hits = await matchRunning(q) }
        if !hits.isEmpty {
            return (hits.first, hits.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })
        }
        if let dormant = installedApp(q) { return (dormant, [dormant]) }
        return (App(name: q), [])
    }

    /// Every running app at the best matching tier — exact bundle id
    /// beats exact name beats substring; a hit ends the search there.
    /// The snapshot is cached for 5 s so a burst of voice commands
    /// doesn't re-walk the process list per turn.
    private func matchRunning(_ query: String) async -> [App] {
        let apps: [App]
        if let running, Date().timeIntervalSince(running.at) < 5 {
            apps = running.apps
        } else {
            apps = (try? await listApps()) ?? []
            running = (Date(), apps)
        }
        let needle = query.lowercased()
        let byBundle = apps.filter { $0.bundle?.lowercased() == needle }
        if !byBundle.isEmpty { return byBundle }
        let byName = apps.filter { $0.name.lowercased() == needle }
        if !byName.isEmpty { return byName }
        return apps.filter {
            $0.name.lowercased().contains(needle)
                || $0.bundle?.lowercased().contains(needle) == true
        }
    }

    /// Installed-but-not-running lookup by display name or bundle id.
    static func installedLookup(_ query: String) -> App? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query),
           let bundle = Bundle(url: url) {
            return App(name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? query,
                       bundle: query)
        }
        let dirs = ["/Applications", "/System/Applications",
                    NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let path = "\(dir)/\(query).app"
            if let bundle = Bundle(path: path) {
                return App(name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? query,
                           bundle: bundle.bundleIdentifier)
            }
        }
        // Substring over installed names — "google" finds Google Chrome.app.
        // Tightest name wins so short queries don't grab a random sibling.
        let needle = query.lowercased()
        var best: (name: String, path: String)?
        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir)
            else { continue }
            for entry in entries where entry.hasSuffix(".app")
                    && entry.lowercased().contains(needle) {
                if best == nil || entry.count < best!.name.count {
                    best = (entry, "\(dir)/\(entry)")
                }
            }
        }
        if let best, let bundle = Bundle(path: best.path) {
            return App(name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                           ?? String(best.name.dropLast(5)),
                       bundle: bundle.bundleIdentifier)
        }
        return nil
    }
}
