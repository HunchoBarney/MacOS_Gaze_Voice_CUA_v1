import AppKit
import XCTest
@testable import Jarvis
import JarvisCore

/// Phase 0 flow benchmark (JARA-41): each core flow enters as a typed final
/// transcript through the production path — VoiceController, the Realtime
/// lane's local admission, FastLane and the coordinator — and is timed from
/// the transcript to the moment the action reaches the driver. No model is
/// called and nothing on the desktop changes: the driver is a fixture desk
/// behind the coordinator's `commandDriver` seam, Mission Control is a fake,
/// and every fixture app uses a pid no process has.
///
/// The desk replays read latencies from a declared profile: `list_apps` and
/// `list_windows` are timed live on this Mac through the platform calls the
/// driver wraps; `get_window_state` uses the crew's modelled AX snapshot
/// cost (KAR-28). The zero profile isolates Jarvis's own code.
///
/// Off by default. `make bench-flows` sets JARVIS_BENCH_FLOWS=1 and
/// JARVIS_BENCH_OUT; bench/flows/report.py turns the rows into the table.
@MainActor
final class FlowBenchTests: XCTestCase {
    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    struct Flow {
        let name: String
        let phrase: String
        /// Driver tools that are this flow's action; nil means the action is
        /// app-side (the name chips) and lands as the task's outcome line.
        let actions: Set<String>?
    }

    static let flows = [
        Flow(name: "open_app", phrase: "open Calculator", actions: ["launch_app"]),
        Flow(name: "click_named", phrase: "click Reply", actions: ["click", "press", "perform_action"]),
        Flow(name: "show_names", phrase: "show names", actions: nil),
        Flow(name: "lost_window", phrase: "where is Safari", actions: ["activate_app"]),
        Flow(name: "switch_desktop", phrase: "next desktop", actions: ["hotkey", "press_key"]),
    ]

    /// Fixture desk: Mail frontmost with a toolbar, Safari's window on
    /// another desktop until Safari is activated, Calculator installed but
    /// not running until it is launched.
    final class Desk: @unchecked Sendable {
        private let lock = NSLock()
        private var profile: [String: Double]
        private var actions: Set<String>?
        private(set) var actionAt: Double?
        private(set) var actionTool: String?
        private(set) var calls: [(tool: String, at: Double)] = []
        private var calculatorRunning = false
        private var safariShown = false
        let verbose: Bool

        init(profile: [String: Double], verbose: Bool) {
            self.profile = profile
            self.verbose = verbose
        }

        func arm(_ actions: Set<String>?) {
            lock.lock(); defer { lock.unlock() }
            self.actions = actions
            actionAt = nil; actionTool = nil; calls = []
            calculatorRunning = false; safariShown = false
        }

        private func record(_ tool: String) -> Double {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock(); defer { lock.unlock() }
            calls.append((tool, now))
            if actionAt == nil, actions?.contains(tool) == true { actionAt = now; actionTool = tool }
            if tool == "launch_app" { calculatorRunning = true }
            return profile[tool] ?? 0
        }

        /// The coordinator's app activation: macOS follows an activated
        /// app to its desktop, so Safari's window comes on screen.
        func activate(_ pid: Int) {
            _ = record("activate_app")
            lock.lock(); defer { lock.unlock() }
            if pid == Self.safariPID { safariShown = true }
        }

        func call(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            let delay = record(tool)
            if verbose { print("bench desk \(tool) \(args.keys.sorted())") }
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            lock.lock(); defer { lock.unlock() }
            return Self.respond(tool, calculatorRunning: calculatorRunning, safariShown: safariShown)
        }

        static let mailPID = 424_201, safariPID = 424_202, calculatorPID = 424_203

        static func window(_ id: Int, _ pid: Int, _ app: String, _ title: String, onScreen: Bool, z: Int) -> JSONValue {
            .object(["window_id": .number(Double(id)), "pid": .number(Double(pid)),
                     "app_name": .string(app), "title": .string(title),
                     "bounds": .object(["x": .number(80), "y": .number(60), "width": .number(1100), "height": .number(760)]),
                     "z_index": .number(Double(z)), "is_on_screen": .bool(onScreen),
                     "is_minimized": .bool(!onScreen)])
        }

        static func button(_ index: Int, _ label: String, x: Double) -> JSONValue {
            .object(["element_index": .number(Double(index)), "element_token": .string("tok-\(index)"),
                     "role": .string("AXButton"), "label": .string(label),
                     "actions": .array([.string("AXPress")]),
                     "frame": .object(["x": .number(x), "y": .number(70), "w": .number(56), "h": .number(28)])])
        }

        static func respond(_ tool: String, calculatorRunning: Bool, safariShown: Bool) -> JSONValue {
            switch tool {
            case "list_apps":
                return .object(["apps": .array([
                    .object(["name": .string("Mail"), "bundle_id": .string("com.apple.mail"), "pid": .number(Double(mailPID)), "active": .bool(true)]),
                    .object(["name": .string("Safari"), "bundle_id": .string("com.apple.Safari"), "pid": .number(Double(safariPID))]),
                ] + (calculatorRunning ? [
                    .object(["name": .string("Calculator"), "bundle_id": .string("com.apple.calculator"), "pid": .number(Double(calculatorPID))]),
                ] : []))])
            case "list_windows":
                return .object(["windows": .array([
                    window(11, mailPID, "Mail", "Inbox", onScreen: true, z: 1),
                    window(12, safariPID, "Safari", "Apple", onScreen: safariShown, z: safariShown ? 3 : 2),
                ] + (calculatorRunning ? [window(13, calculatorPID, "Calculator", "Calculator", onScreen: true, z: 4)] : []))])
            case "get_window_state":
                return .object(["pid": .number(Double(mailPID)), "window_id": .number(11),
                                "window_title": .string("Inbox"), "snapshot_id": .string("bench-snapshot"),
                                "elements": .array(["Reply", "Reply All", "Forward", "Archive", "Delete", "Flag"]
                                    .enumerated().map { button($0.offset + 1, $0.element, x: 120 + Double($0.offset) * 64) })])
            case "launch_app":
                return .object(["pid": .number(Double(calculatorPID)), "effect": .string("confirmed")])
            default:
                return .object(["effect": .string("confirmed")])
            }
        }
    }

    /// One Mission Control with two desktops; the hotkey lands on the next.
    final class Spaces {
        var system: DesktopSpaceSwitch.System {
            DesktopSpaceSwitch.System(
                roots: { [] }, children: { _ in nil }, attr: { _, _ in nil },
                pressable: { _ in false }, press: { _ in false },
                displayID: { 9 }, labels: { nil },
                openMissionControl: {}, pause: {},
                watchSpaceChange: { { _ in true } },
                layout: { nil }, shortcutEnabled: { _ in true })
        }
    }

    func testFlows() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_BENCH_FLOWS"] == "1" else { throw XCTSkip("set JARVIS_BENCH_FLOWS=1 (make bench-flows)") }
        usePrivateStandingGrants()
        let runs = Int(env["JARVIS_BENCH_RUNS"] ?? "") ?? 15
        let verbose = env["JARVIS_BENCH_VERBOSE"] == "1"
        let label = env["JARVIS_BENCH_LABEL"] ?? "current"
        let out = env["JARVIS_BENCH_OUT"].map(URL.init(fileURLWithPath:))
        var rows: [[String: Any]] = []

        let measured = Self.measuredReads()
        let profiles: [(String, [String: Double])] = [
            ("zero", [:]),
            ("modeled", ["list_apps": measured.listApps, "list_windows": measured.listWindows, "get_window_state": 85]),
        ]
        rows.append(["v": 1, "kind": "profile", "label": label,
                     "list_apps_ms": measured.listApps, "list_windows_ms": measured.listWindows,
                     "get_window_state_ms": 85])

        for (profileName, profile) in profiles {
            for flow in Self.flows {
                let desk = Desk(profile: profile, verbose: verbose)
                let world = makeWorld(desk)
                for run in -1..<runs {
                    desk.arm(flow.actions)
                    let entriesBefore = Set(world.coordinator.feed.entries.map(\.id))
                    let start = ProcessInfo.processInfo.systemUptime
                    world.controller.submitTypedCommand(flow.phrase)
                    var actionAt: Double?
                    var outcome: String?
                    let deadline = start + 5
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        let fresh = world.coordinator.feed.entries.filter { !entriesBefore.contains($0.id) }
                        if let line = fresh.first(where: { $0.kind == .outcome }) {
                            outcome = line.text
                            if flow.actions == nil { actionAt = ProcessInfo.processInfo.systemUptime + line.at.timeIntervalSinceNow }
                        }
                        if flow.actions != nil, let at = desk.actionAt { actionAt = at }
                        if actionAt != nil, outcome != nil { break }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    if verbose {
                        print("bench \(profileName) \(flow.name) run \(run): action \(desk.actionTool ?? "-") at \(actionAt.map { String(format: "%.1f", ($0 - start) * 1000) } ?? "none") ms; outcome \(outcome ?? "-")")
                        print("bench calls " + desk.calls.map { "\($0.tool)@\(String(format: "%.1f", ($0.at - start) * 1000))" }.joined(separator: " "))
                    }
                    world.overlay.hideAll()
                    world.coordinator.stopAll()
                    try await Task.sleep(for: .milliseconds(150))
                    guard run >= 0 else { continue }
                    var row: [String: Any] = ["v": 1, "kind": "flow", "label": label, "profile": profileName,
                                              "flow": flow.name, "run": run,
                                              "reads_before_action": desk.calls.filter { $0.at <= (actionAt ?? .infinity) && !(flow.actions?.contains($0.tool) ?? false) }.map(\.tool)]
                    if let actionAt { row["transcript_to_action_ms"] = max(0, (actionAt - start) * 1000) }
                    row["action_tool"] = desk.actionTool ?? (flow.actions == nil && actionAt != nil ? "overlay" : nil)
                    rows.append(row)
                }
                await world.controller.shutdown()
            }
        }
        if let out {
            let text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
                .joined(separator: "\n") + "\n"
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: out) {
                try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
            } else {
                try Data(text.utf8).write(to: out)
            }
        }
        let missing = rows.filter { $0["kind"] as? String == "flow" && $0["transcript_to_action_ms"] == nil }
        XCTAssertTrue(missing.isEmpty, "flows that never reached their action: \(Set(missing.compactMap { $0["flow"] as? String }))")
    }

    struct World {
        let controller: VoiceController
        let coordinator: VoiceTaskCoordinator
        let overlay: TargetOverlay
    }

    private func makeWorld(_ desk: Desk) -> World {
        let config = Config(defaults: UserDefaults(suiteName: "flow-bench-\(UUID())")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        config.ttsEnabled = false
        config.alwaysAllowComputerUse = true
        let overlay = TargetOverlay()
        let coordinator = VoiceTaskCoordinator(
            config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: overlay,
            resolver: AppResolver(exactBundleApps: { _ in [] }, listApps: {
                [AppResolver.App(name: "Mail", bundle: "com.apple.mail", pid: Desk.mailPID),
                 AppResolver.App(name: "Safari", bundle: "com.apple.Safari", pid: Desk.safariPID)]
            }),
            commandDriver: { tool, args in try await desk.call(tool, args) },
            foregroundAppLauncher: { _ in
                _ = try await desk.call("launch_app", [:])
                return Desk.calculatorPID
            },
            desktopSpaces: Spaces().system,
            activateApp: { desk.activate($0) })
        let lane = RealtimeVoiceLane(apiKey: { "" }, client: RealtimeVoiceClient(wireFactory: { _ in
            preconditionFailure("the flow bench never opens a Realtime connection")
        }))
        let controller = VoiceController(config: config, speech: lane, authorize: { true },
                                         frontmost: { "Mail" },
                                         focusedWindow: { (Desk.mailPID, "com.apple.mail", 11) },
                                         cuaRuntime: coordinator)
        return World(controller: controller, coordinator: coordinator, overlay: overlay)
    }

    /// The driver's `list_apps` and `list_windows` wrap these platform
    /// reads; their median on this Mac stands in for the call's cost.
    static func measuredReads() -> (listApps: Double, listWindows: Double) {
        func median(_ body: () -> Void) -> Double {
            let samples = (0..<25).map { _ -> Double in
                let t = ProcessInfo.processInfo.systemUptime
                body()
                return (ProcessInfo.processInfo.systemUptime - t) * 1000
            }.sorted()
            return samples[samples.count / 2]
        }
        let apps = median { _ = NSWorkspace.shared.runningApplications.map { ($0.localizedName, $0.bundleIdentifier, $0.processIdentifier) } }
        let windows = median { _ = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) }
        return ((apps * 10).rounded() / 10, (windows * 10).rounded() / 10)
    }
}
