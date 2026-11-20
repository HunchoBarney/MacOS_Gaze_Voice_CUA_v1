import AppKit
import CoreGraphics
import Synchronization
import XCTest
@testable import Jarvis
import JarvisCore

/// KAR-43 live screen-agent eval: GPT-6.1 Terra drives disposable targets on
/// the real Mac through the host's agent path (CuaDriveServer.Drives), and
/// the harness checks every outcome itself, from the file system or its own
/// window read, never from the loop's claim.
///
/// Paid and desktop-mutating, so it is gated twice:
///   JARVIS_LIVE_TERRA=1              run at all (through with-desktop-lock.py)
///   JARVIS_TERRA_LEDGER=<file>       running spend ledger shared by every run
///   JARVIS_TERRA_CAP_DOLLARS=5       no call starts once the ledger reaches it
///   JARVIS_TERRA_REPORT=<file>       one JSON line per task
///   JARVIS_TERRA_UNCACHED=1          a fresh prefix on every call (cache off)
///   JARVIS_TERRA_RUNS=2              repetitions per flow
///
/// The OpenAI key is read from Jarvis's Keychain item without user
/// interaction: if that would prompt, the test stops instead.
/// Targets: a Finder window on a fresh temp folder and TextEdit only when it
/// wasn't already running. The harness closes what it opened and deletes the
/// folder; it never touches existing windows or files.
final class ScreenAgentLiveTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    struct CapReached: Error {}

    /// The spend ledger: total dollars from reported usage, kept on disk so
    /// the cap covers every run.
    final class Ledger: Sendable {
        let url: URL
        let cap: Double
        private let state = Mutex<(dollars: Double, calls: Int)>((0, 0))

        init(url: URL, cap: Double) {
            self.url = url
            self.cap = cap
            if let data = try? Data(contentsOf: url),
               let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
                state.withLock { $0 = (json["dollars"]?.numberValue ?? 0, json["calls"]?.integer ?? 0) }
            }
        }

        var dollars: Double { state.withLock { $0.dollars } }
        var allowsCall: Bool { dollars < cap }

        func record(_ usage: TerraClient.Usage) {
            let snapshot = state.withLock { state -> (Double, Int) in
                state.dollars += usage.dollars
                state.calls += 1
                return (state.dollars, state.calls)
            }
            let json = JSONValue.object(["dollars": .number(snapshot.0), "calls": .number(Double(snapshot.1)),
                                         "cap": .number(cap)])
            try? JSONEncoder().encode(json).write(to: url, options: .atomic)
        }
    }

    struct Flow {
        var name: String
        var app: String
        var goal: String
        var setUp: (_ folder: URL) throws -> Void = { _ in }
        /// Answer for a consequential press Jarvis chose; nil declines.
        var askAnswer: String? = nil
        var check: (_ folder: URL, _ windows: [String]) -> Bool
    }

    static let flows: [Flow] = [
        Flow(name: "finder-open-inbox", app: "com.apple.finder", goal: "Open the Inbox folder",
             setUp: { try FileManager.default.createDirectory(at: $0.appendingPathComponent("Inbox/Notes"),
                                                             withIntermediateDirectories: true) },
             check: { _, windows in windows.contains("Inbox") }),
        Flow(name: "finder-new-folder", app: "com.apple.finder", goal: "Make a new folder in this window",
             check: { folder, _ in
                 ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                     .contains { $0.lowercased().hasPrefix("untitled folder") }
             }),
        Flow(name: "finder-open-file-folder-path", app: "com.apple.finder",
             goal: "Open the Archive folder, then open the 2025 folder inside it",
             setUp: { try FileManager.default.createDirectory(at: $0.appendingPathComponent("Archive/2025"),
                                                             withIntermediateDirectories: true) },
             check: { _, windows in windows.contains("2025") }),
        Flow(name: "finder-trash-asks", app: "com.apple.finder", goal: "Move report.txt to the Trash",
             setUp: { try Data("eval".utf8).write(to: $0.appendingPathComponent("report.txt")) },
             check: { folder, _ in
                 FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.txt").path)
             }),
        Flow(name: "textedit-new-document", app: "com.apple.TextEdit", goal: "Open a new blank document",
             check: { _, windows in windows.contains { $0.hasPrefix("Untitled") } }),
        Flow(name: "textedit-close-document", app: "com.apple.TextEdit", goal: "Close this document",
             check: { _, windows in !windows.contains { $0.hasPrefix("eval-note") } }),
    ]

    func testTerraScreenAgentFlows() async throws {
        try XCTSkipUnless(env["JARVIS_LIVE_TERRA"] == "1", "live Terra eval is opt-in")
        let ledgerURL = URL(fileURLWithPath: try XCTUnwrap(env["JARVIS_TERRA_LEDGER"]))
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(env["JARVIS_TERRA_REPORT"]))
        let ledger = Ledger(url: ledgerURL, cap: Double(env["JARVIS_TERRA_CAP_DOLLARS"] ?? "5") ?? 5)
        let uncached = env["JARVIS_TERRA_UNCACHED"] == "1"
        let runs = Int(env["JARVIS_TERRA_RUNS"] ?? "1") ?? 1
        let only = env["JARVIS_TERRA_FLOWS"].map { Set($0.split(separator: ",").map(String.init)) }

        let key: String
        do {
            key = try XCTUnwrap(KeychainAPIKeyStore(account: "openAIAPIKey", allowUserInteraction: false).read())
        } catch {
            return XCTFail("The OpenAI key isn't readable without a Keychain prompt: \(error)")
        }
        XCTAssertTrue(AXIsProcessTrusted(), "this test host needs Accessibility (TCC) to drive the desktop")
        guard AXIsProcessTrusted() else { return }

        let textEditWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
        for flow in Self.flows where only?.contains(flow.name) ?? true {
            if flow.app == "com.apple.TextEdit", textEditWasRunning { continue }
            for run in 1...runs {
                guard ledger.allowsCall else { return XCTFail("spend cap reached at $\(ledger.dollars)") }
                let line = try await runFlow(flow, key: key, ledger: ledger, uncached: uncached, run: run)
                var data = try JSONEncoder().encode(line)
                data.append(0x0A)
                if let handle = try? FileHandle(forWritingTo: reportURL) {
                    handle.seekToEndOfFile(); handle.write(data); try handle.close()
                } else {
                    try data.write(to: reportURL)
                }
            }
        }
        if !textEditWasRunning {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").forEach { $0.terminate() }
        }
    }

    private func runFlow(_ flow: Flow, key: String, ledger: Ledger, uncached: Bool, run: Int) async throws -> JSONValue {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-terra-eval-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try flow.setUp(folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pid: Int
        var before = Set<Int>()
        if flow.app == "com.apple.finder" {
            pid = Int(try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: flow.app).first)
                .processIdentifier)
            before = Set(Self.windowIDs(pid: pid))
            NSWorkspace.shared.open(folder)
        } else {
            let note = folder.appendingPathComponent("eval-note.txt")
            try Data("Terra eval".utf8).write(to: note)
            let url = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: flow.app))
            pid = Int(try await NSWorkspace.shared.open([note], withApplicationAt: url,
                                                        configuration: NSWorkspace.OpenConfiguration()).processIdentifier)
        }
        var windowID: Int?
        for _ in 0..<50 where windowID == nil {
            try await Task.sleep(for: .milliseconds(100))
            windowID = Self.windowIDs(pid: pid).first { !before.contains($0) }
        }
        let bound = try XCTUnwrap(windowID, "\(flow.name): the target window never appeared")

        let usage = LockedBox<[TerraClient.Usage]>([])
        var client = TerraClient(apiKey: { key })
        client.transport = { request in
            guard ledger.allowsCall else { throw CapReached() }
            var request = request
            if uncached, let body = request.httpBody,
               case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: body) {
                fields["instructions"] = .string("Run \(UUID().uuidString).\n" + (fields["instructions"]?.string ?? ""))
                request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
            }
            return try await URLSession.shared.data(for: request)
        }
        client.onUsage = { spent in
            ledger.record(spent)
            usage.set(usage.value + [spent])
        }
        let drives = CuaDriveServer.Drives(chooser: { TerraChooser.make(client: client) },
                                           granted: { true },
                                           ask: { _, _ in flow.askAnswer })
        let started = Date()
        let result = await drives.run(agent: "eval", tool: "drive_until", arguments: .object([
            "goal": .string(flow.goal), "app": .string(flow.app), "window_id": .number(Double(bound))]))
        let seconds = Date().timeIntervalSince(started)
        try await Task.sleep(for: .milliseconds(500))
        let titles = try await windowTitles(pid: pid)
        let passed = flow.check(folder, titles)

        for id in Self.windowIDs(pid: pid) where !before.contains(id) {
            _ = WindowControls.press(.close, pid: pid_t(pid), windowID: id)
        }
        let spent = usage.value
        return .object([
            "flow": .string(flow.name), "run": .number(Double(run)), "uncached": .bool(uncached),
            "passed": .bool(passed), "calls": .number(Double(spent.count)),
            "dollars": .number(spent.map(\.dollars).reduce(0, +)),
            "input": .number(Double(spent.map(\.input).reduce(0, +))),
            "cached": .number(Double(spent.map(\.cached).reduce(0, +))),
            "output": .number(Double(spent.map(\.output).reduce(0, +))),
            "seconds": .number(seconds.rounded()),
            "result": .string(String((result["content"]?.array?.first?["text"]?.string ?? "").prefix(200))),
            "ledger": .number(ledger.dollars),
        ])
    }

    private static func windowIDs(pid: Int) -> [Int] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    /// The app's window titles from the harness's own driver read.
    private func windowTitles(pid: Int) async throws -> [String] {
        let driver = CuaConnection()
        defer { Task { await driver.close() } }
        try await driver.connect(socket: try await CuaDaemonHost.shared.socket())
        let list = try await driver.call("list_windows", arguments: ["pid": .number(Double(pid))])
        let windows = list["structuredContent"]?["windows"]?.array ?? list["windows"]?.array ?? []
        return windows.compactMap { $0["title"]?.string ?? $0["name"]?.string }
    }
}
