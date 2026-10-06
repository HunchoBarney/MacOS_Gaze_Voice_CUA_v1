import AppKit
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaVoiceLiveTests: XCTestCase {
    private var warmedRuntime: CuaVoiceRuntime?
    private final class Capture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var id: UUID?
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String { id = session; return "Simulated transcript; real Jev/Cua" }
        func finish() {}
        func cancel() {}
        func emit(_ event: SpeechEvent) { if let id { onEvent?(id, event) } }
    }
    private struct Keys: APIKeyStore {
        let key: String
        func read() throws -> String? { key }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }
    func testCalculatorThroughVoiceControllerOptIn() async throws {
        let count = min(30, max(1, Int(ProcessInfo.processInfo.environment["JARVIS_WARM_SAMPLES"] ?? "1") ?? 1))
        for sample in 1...count {
            print("Warm Calculator sample", sample, "of", count)
            try await workflow(request: "Please open Calculator", bundle: "com.apple.calculator")
        }
    }
    func testNewTextEditDocumentThroughVoiceControllerOptIn() async throws {
        try await workflow(request: "Please open TextEdit and create a new document", bundle: "com.apple.TextEdit", newDocument: true)
    }
    /// The production "open Messages" / "bring to front" failures ran the
    /// fast lane on the app's own embedded daemon — this drives the same
    /// runtime end-to-end but bound to the RUNNING app's daemon socket, so
    /// every driver call executes under the app's TCC-blessed identity
    /// instead of the test host's. JARVIS_APP_CUA_SOCKET must point at the
    /// live app's jev-cua-*.sock.
    func testMessagesCommandsThroughAppDaemonOptIn() async throws {
        guard let socket = ProcessInfo.processInfo.environment["JARVIS_APP_CUA_SOCKET"],
              FileManager.default.fileExists(atPath: socket) else {
            throw XCTSkip("set JARVIS_APP_CUA_SOCKET to the running app's daemon socket")
        }
        let suite = "JarvisAppDaemonLive-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = Config(defaults: defaults, keyStore: Keys(key: ""),
                            openAIKeyStore: Keys(key: ""),
                            environment: ["JARVIS_PLANNER": "0"])
        let runtime = CuaVoiceRuntime(config: config,
            makeConnection: { CuaConnection(socketProvider: { socket }) },
            judge: { _, _ in
                throw DriverConnectionError.refused("judge must not run on the fast lane")
            },
            screenLocked: { false })
        defer { Task { await runtime.shutdown() } }
        let capture = Capture()
        let controller = VoiceController(config: config, speech: capture,
                                         authorize: { true }, cuaRuntime: runtime)
        controller.begin()
        for _ in 0..<100 where controller.status != .listening {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.status, .listening)
        defer { Task { await controller.shutdown() } }

        for request in ["open Messages", "bring Messages to the front"] {
            let priorTaskCount = controller.cuaTasks.count
            let ack = await controller.cua.beginVoiceTask(request, app: "Messages")
            print("Voice route ack:", ack)
            for _ in 0..<600 {
                if controller.cuaTasks.count > priorTaskCount,
                   controller.cuaTasks.last?.active == false { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let task = try XCTUnwrap(controller.cuaTasks.last)
            print("Voice route outcome:", task.status, task.message)
            XCTAssertEqual(task.status, "Completed", "\(request): \(task.message)")
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       "com.apple.MobileSMS", "Messages must be frontmost after both commands")
    }

    func testHiddenCalculatorThroughVoiceControllerOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_VOICE_TEST"] == "1" else { throw XCTSkip("Opt-in macOS hide/show check") }
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").first)
        _ = app.hide()
        for _ in 0..<50 where !app.isHidden { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(app.isHidden, "Fixture must be hidden before the show request")
        defer { if app.isHidden { _ = app.unhide() } }
        try await workflow(request: "Show Calculator", bundle: "com.apple.calculator")
        XCTAssertFalse(app.isHidden)
    }
    private func workflow(request: String, bundle: String, newDocument: Bool = false) async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_VOICE_TEST"] == "1" else {
            throw XCTSkip("Opt-in simulated transcript with real Jev/Cua/macOS")
        }
        let key = try CuaLiveCredential.jev()
        let suite = "JarvisVoiceLive-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = Config(defaults: defaults, keyStore: Keys(key: key), openAIKeyStore: Keys(key: ""), environment: ["JARVIS_PLANNER": "0"])
        let observer = CuaConnection()
        var activeController: VoiceController?
        do {
            try await observer.connect()
            let apps = try await observer.call("get_accessibility_tree", arguments: [:])
            let priorPID = (apps["apps"]?.array ?? []).first { $0["bundle_id"]?.string == bundle }?["pid"]?.integer
            var previousWindows = Set<Int>()
            if let priorPID {
                let windows = try await observer.call("list_windows", arguments: ["pid": .number(Double(priorPID))])
                previousWindows = Set((windows["windows"]?.array ?? []).compactMap { $0["window_id"]?.integer })
            }
            let capture = Capture()
            let runtime = warmedRuntime ?? CuaVoiceRuntime(config: config,
                judge: { state, questions in
                let result = try await JevClient(apiKey: key).systemOne(state: state, questions: questions).response.answers
                for (id, answer) in result {
                    if case let .choice(value, _, _) = answer {
                        print("Fixture decision:", id, value)
                        if id == "next", case let .choice(_, options) = questions[id] {
                            print("Fixture action:", (options[value] ?? nil) ?? "")
                            print("State: scope=\(state["scope"] ?? .null)",
                                  "produced=\(state["window_produced_by_task"] ?? .null)",
                                  "wid=\(state["selected_window_id"] ?? .null)",
                                  "title=\(state["window_title"] ?? .null)")
                        }
                    }
                }
                return result
            })
            if (Int(ProcessInfo.processInfo.environment["JARVIS_WARM_SAMPLES"] ?? "1") ?? 1) > 1 { warmedRuntime = runtime }
            let controller = VoiceController(config: config, speech: capture, authorize: { true }, cuaRuntime: runtime)
            activeController = controller
            let priorTaskCount = controller.cuaTasks.count
            controller.begin()
            for _ in 0..<100 where controller.status != .listening { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(controller.status, .listening)
            let start = ContinuousClock.now
            // The realtime model's tool call lands here — the same entry the
            // lane's computer_command uses; the ack returns at acceptance and
            // the verified outcome settles asynchronously.
            let ack = await controller.cua.beginVoiceTask(request, app: nil)
            print("Voice route ack:", ack)
            for _ in 0..<600 {
                if controller.cuaTasks.count > priorTaskCount, controller.cuaTasks.last?.active == false { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            if controller.cuaTasks.last == nil {
                print("No task materialized — ack:", ack)
            }
            let task = try XCTUnwrap(controller.cuaTasks.last)
            print("Voice route outcome:", task.status, task.message, "transcript-to-result:", start.duration(to: .now))
            if let metricsPath = ProcessInfo.processInfo.environment["JARVIS_VOICE_METRICS"] {
                let record: JSONValue = .object(["status": .string(task.status), "elapsed_ms": .number(task.elapsedMs)])
                var data = try JSONEncoder().encode(record); data.append(10)
                if !FileManager.default.fileExists(atPath: metricsPath) { FileManager.default.createFile(atPath: metricsPath, contents: nil) }
                let file = try FileHandle(forWritingTo: URL(fileURLWithPath: metricsPath))
                try file.seekToEnd(); try file.write(contentsOf: data); try file.close()
            }
            XCTAssertEqual(task.status, "Completed")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, bundle)
            if newDocument {
                let window = try XCTUnwrap(task.window)
                XCTAssertFalse(previousWindows.contains(window), "Must create a new document, not reuse an existing one")
            }
            XCTAssertEqual(controller.status, .listening, "Must complete before release")
            controller.finish(); capture.emit(.final(request))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(controller.cuaTasks.count, priorTaskCount + 1)
        } catch {
            await activeController?.shutdown()
            await observer.close()
            throw error
        }
        await activeController?.shutdown()
        await observer.close()
    }
}
