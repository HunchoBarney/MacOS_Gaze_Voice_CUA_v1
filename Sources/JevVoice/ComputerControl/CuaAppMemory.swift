import Foundation

/// A small observed-facts patch applied to one app's memory record. Nil
/// fields leave the stored value alone — only what a run actually observed
/// is written.
struct CuaAppMemoryUpdate: Sendable, Equatable {
    /// True after a run found no interactive elements; false once an AX
    /// element lane provably lands, clearing a stale sparse report.
    var axSparse: Bool?
    /// True once a pixel or visual lane wins — the app's surface lives in
    /// pixels, not the AX tree.
    var prefersVisual: Bool?
    /// Lane kinds that dispatched successfully this run, coarse vocabulary
    /// ("click", "type", "pixel", "visual", "menu", "key", "scroll",
    /// "navigate", "browser_click"…). Empty means no observation — the
    /// stored list is kept.
    var laneKinds: [String] = []
    /// One durable note — a user correction re-mapping a target, a learned
    /// quirk. Deduped verbatim and capped per app.
    var note: String?
    init(axSparse: Bool? = nil, prefersVisual: Bool? = nil,
         laneKinds: [String] = [], note: String? = nil) {
        self.axSparse = axSparse; self.prefersVisual = prefersVisual
        self.laneKinds = laneKinds; self.note = note
    }
}

/// Per-app memory the drive lane carries between tasks: whether the AX
/// tree was sparse, which lanes landed, and corrections the user made.
/// File-backed at ~/Library/Application Support/JevVoice/app-memory.json so
/// a restart keeps it. Small by contract — notes cap at 8 per app and 40
/// apps LRU. A corrupt or unreadable file reads as an empty store, never
/// a crash; a failed write degrades to in-memory memory.
actor CuaAppMemory {
    static let shared = CuaAppMemory()

    private struct AppRecord: Codable {
        var appName: String?
        var axSparse = false
        var prefersVisual = false
        var lastGoodLaneKinds: [String] = []
        var notes: [String] = []
        var lastUsed: TimeInterval = 0
    }
    private struct Store: Codable { var apps: [String: AppRecord] = [:] }

    private static let maxApps = 40
    private static let maxNotes = 8

    private let fileURL: URL
    private var store = Store()
    /// The file is read lazily on first access — a runtime that never
    /// drives never pays the read.
    private var loaded = false
    /// Monotonic recency stamp — a wall clock can tie on back-to-back
    /// writes, which would make LRU eviction order arbitrary.
    private var tick = 0

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JevVoice", isDirectory: true)
            .appendingPathComponent("app-memory.json")
    }

    /// Merge a patch into the app's record and persist. The record keys on
    /// the bundle id when known, else the name spelling — both normalize to
    /// lowercase-trim so "Safari" and "safari" share one entry.
    func note(bundleID: String?, appName: String?, record: CuaAppMemoryUpdate) {
        let key = Self.key(bundleID: bundleID, appName: appName)
        guard !key.isEmpty else { return }
        load()
        var entry = store.apps[key] ?? AppRecord()
        if let appName, !appName.isEmpty { entry.appName = appName }
        if let axSparse = record.axSparse { entry.axSparse = axSparse }
        if let prefersVisual = record.prefersVisual { entry.prefersVisual = prefersVisual }
        if !record.laneKinds.isEmpty {
            entry.lastGoodLaneKinds = Array(record.laneKinds.prefix(8))
        }
        if let note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty, !entry.notes.contains(note) {
            entry.notes.append(String(note.prefix(160)))
            if entry.notes.count > Self.maxNotes {
                entry.notes.removeFirst(entry.notes.count - Self.maxNotes)
            }
        }
        tick += 1
        entry.lastUsed = TimeInterval(tick)
        store.apps[key] = entry
        // LRU: beyond the cap the least recently used apps drop first.
        if store.apps.count > Self.maxApps {
            for key in store.apps
                .sorted(by: { $0.value.lastUsed < $1.value.lastUsed })
                .prefix(store.apps.count - Self.maxApps).map(\.key) {
                store.apps.removeValue(forKey: key)
            }
        }
        save()
    }

    /// One compact line for `previous_context`, or nil when the app is
    /// unknown. Lookup accepts a bundle id or a display name — records
    /// written under a bundle id still answer a name-spelled query via the
    /// stored `appName`.
    func context(forApp app: String) -> String? {
        load()
        let needle = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        guard let entry = store.apps[needle] ?? store.apps.values.first(where: {
            $0.appName?.lowercased() == needle
        }) else { return nil }
        var parts: [String] = []
        if entry.axSparse { parts.append("accessibility tree is sparse") }
        if entry.prefersVisual { parts.append("prefers visual/pixel lanes") }
        if !entry.lastGoodLaneKinds.isEmpty {
            parts.append("lanes that worked: \(entry.lastGoodLaneKinds.joined(separator: ", "))")
        }
        if !entry.notes.isEmpty {
            parts.append("notes: \(entry.notes.joined(separator: " | "))")
        }
        guard !parts.isEmpty else { return nil }
        return "Memory for \(entry.appName ?? app): " + parts.joined(separator: "; ")
    }

    private static func key(bundleID: String?, appName: String?) -> String {
        let raw = (bundleID?.isEmpty == false ? bundleID : appName) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Store.self, from: data) else { return }
        store = decoded
        // Keep the recency clock ahead of anything the file carried in.
        tick = max(tick, decoded.apps.values.map { Int($0.lastUsed) }.max() ?? 0)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
