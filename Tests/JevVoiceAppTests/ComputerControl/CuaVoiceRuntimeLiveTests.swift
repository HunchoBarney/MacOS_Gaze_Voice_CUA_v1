import AppKit
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaVoiceRuntimeLiveTests: XCTestCase {
    private final class ToolCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        private var textLengths: [Int] = []
        func record(_ tool: String, textLength: Int?) {
            lock.lock(); defer { lock.unlock() }
            values[tool, default: 0] += 1
            if let textLength { textLengths.append(textLength) }
        }
        func snapshot() -> (tools: [String: Int], textLengths: [Int]) {
            lock.lock(); defer { lock.unlock() }
            return (values, textLengths)
        }
    }

    private struct FixtureKeyStore: APIKeyStore {
        let key: String
        func read() throws -> String? { key }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private struct ParallelFixture {
        let name: String
        let bundleID: String
        let title: String
        let seed: String
        let inserted: String
        let process: Process
        let bundle: URL
        let windowID: Int
    }

    func testIndependentBackgroundTasksProgressInParallelOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_RUNTIME_CONCURRENCY_TEST"] == "1" else {
            throw XCTSkip("Opt-in two-task background execution in disposable native windows")
        }
        let key = try CuaLiveCredential.jev()
        let observer = try CuaLiveDriver.connection()
        try await observer.connect()
        let observerSession = "Jarvis parallel observer \(UUID().uuidString.prefix(8))"
        _ = try await observer.call("start_session", arguments: ["session": .string(observerSession)])

        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let priorPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let descriptions: [(name: String, bundleID: String, title: String, seed: String, inserted: String)] = [
            ("Jarvis Parallel Cedar \(identifier.prefix(6))", "com.jarvis.parallel.\(identifier).a",
             "Cedar target \(identifier.prefix(6))", "Seed A remains intact.", "cedar marker alpha"),
            ("Jarvis Parallel Maple \(identifier.prefix(6))", "com.jarvis.parallel.\(identifier).b",
             "Maple target \(identifier.prefix(6))", "Seed B remains intact.", "maple marker beta")
        ]
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Jarvis-Parallel-\(identifier)", isDirectory: true)
        let source = base.appendingPathComponent("ParallelFixture.swift")
        let compiledExecutable = base.appendingPathComponent("JarvisParallelFixture")
        var bundles: [URL] = []
        var processes: [Process] = []
        var fixtures: [ParallelFixture] = []
        var runtime: CuaVoiceRuntime?
        var runtimeConnections: [CuaConnection] = []

        func restoreAndClean() async {
            await runtime?.shutdown()
            for connection in runtimeConnections { await connection.close() }
            for process in processes where process.isRunning { process.terminate() }
            for _ in 0..<50 where processes.contains(where: \.isRunning) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            _ = try? await observer.call("end_session", arguments: ["session": .string(observerSession)])
            await observer.close()
            for bundle in bundles { try? FileManager.default.removeItem(at: bundle) }
            try? FileManager.default.removeItem(at: base)
            if let priorPID, let prior = NSRunningApplication(processIdentifier: priorPID) {
                _ = prior.activate(options: [])
                for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != priorPID {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let appSource = #"""
            import AppKit

            final class FixtureDelegate: NSObject, NSApplicationDelegate {
                var window: NSWindow!
                func applicationDidFinishLaunching(_ notification: Notification) {
                    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
                    scroll.hasVerticalScroller = true
                    scroll.autoresizingMask = [.width, .height]
                    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
                    text.string = CommandLine.arguments[2]
                    text.isEditable = true
                    text.isSelectable = true
                    scroll.documentView = text
                    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.title = CommandLine.arguments[1]
                    window.contentView = scroll
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = FixtureDelegate()
            app.delegate = delegate
            app.run()
            """#
            try appSource.write(to: source, atomically: true, encoding: .utf8)
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["swiftc", source.path, "-framework", "AppKit", "-o", compiledExecutable.path]
            let compilerError = Pipe()
            compiler.standardError = compilerError
            try compiler.run()
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else {
                let detail = String(data: compilerError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw DriverConnectionError.refused("The two disposable native fixtures did not build: \(detail.prefix(500))")
            }

            for (index, description) in descriptions.enumerated() {
                let bundle = base.appendingPathComponent("Fixture-\(index).app", isDirectory: true)
                let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
                let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
                try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
                let info: [String: Any] = [
                    "CFBundleExecutable": "JarvisParallelFixture",
                    "CFBundleIdentifier": description.bundleID,
                    "CFBundleName": description.name,
                    "CFBundleDisplayName": description.name,
                    "CFBundlePackageType": "APPL",
                    "NSPrincipalClass": "NSApplication"
                ]
                let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                try plist.write(to: contents.appendingPathComponent("Info.plist"))
                let executable = executableDirectory.appendingPathComponent("JarvisParallelFixture")
                try FileManager.default.copyItem(at: compiledExecutable, to: executable)
                bundles.append(bundle)

                let process = Process()
                process.executableURL = executable
                process.arguments = [description.title, description.seed]
                try process.run()
                processes.append(process)
                var exactWindow: JSONValue?
                var body: String?
                for _ in 0..<100 {
                    let windows = try await observer.call("list_windows", arguments: [
                        "pid": .number(Double(process.processIdentifier)), "session": .string(observerSession)
                    ])
                    let matches = (windows["windows"]?.array ?? []).filter { $0["title"] == .string(description.title) }
                    if matches.count == 1, let windowID = matches[0]["window_id"]?.integer {
                        exactWindow = matches[0]
                        let state = try await observer.call("get_window_state", arguments: [
                            "pid": .number(Double(process.processIdentifier)), "window_id": .number(Double(windowID)),
                            "include_screenshot": .bool(false), "session": .string(observerSession)
                        ])
                        body = (state["elements"]?.array ?? []).first { $0["role"] == .string("AXTextArea") }?["value"]?.string
                        if body == description.seed { break }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let exactWindow, body == description.seed,
                      let windowID = exactWindow["window_id"]?.integer else {
                    throw DriverConnectionError.refused("Cua did not observe the exact seeded window for \(description.name).")
                }
                fixtures.append(ParallelFixture(name: description.name, bundleID: description.bundleID,
                    title: description.title, seed: description.seed, inserted: description.inserted,
                    process: process, bundle: bundle, windowID: windowID))
            }

            if let priorPID, let prior = NSRunningApplication(processIdentifier: priorPID) {
                _ = prior.activate(options: [])
                for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != priorPID {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let foregroundBeforeTasks = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let model = JevClient(apiKey: key)
            runtimeConnections = try (0..<descriptions.count).map { _ in try CuaLiveDriver.connection() }
            var nextConnection = 0
            var modelCalls = 0
            let config = Config(defaults: UserDefaults(suiteName: "CuaVoiceRuntimeParallel-\(identifier)")!,
                                keyStore: FixtureKeyStore(key: key), environment: [:])
            let taskRuntime = CuaVoiceRuntime(config: config, makeConnection: {
                let connection = runtimeConnections[nextConnection]
                nextConnection += 1
                return connection
            }, judge: { state, questions in
                modelCalls += 1
                let answers = try await model.systemOne(state: state, questions: questions).response.answers
                for (key, answer) in answers {
                    guard case let .choice(choice, _, _) = answer,
                          case let .choice(_, criteria)? = questions[key] else { continue }
                    print("Parallel Jev \(key):", criteria[choice].flatMap { $0 } ?? choice)
                }
                return answers
            })
            runtime = taskRuntime
            let requests = fixtures.map { fixture in
                "Dictate exactly \"\(fixture.inserted)\" into the text area in \(fixture.name), window \(fixture.title). Preserve all existing text."
            }
            taskRuntime.begin(app: fixtures[0].name)
            taskRuntime.update(requests[0], final: true)

            let firstDeadline = Date().addingTimeInterval(30)
            while Date() < firstDeadline {
                guard let first = taskRuntime.tasks.first else {
                    try await Task.sleep(for: .milliseconds(100)); continue
                }
                if first.status == "Failed" || first.status == "Cancelled" {
                    throw DriverConnectionError.refused("The first independent task did not start: \(first.message)")
                }
                if first.status == "Working", first.bundle == fixtures[0].bundleID { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let first = taskRuntime.tasks.first, first.status == "Working",
                  first.bundle == fixtures[0].bundleID else {
                throw DriverConnectionError.refused("The first task did not acquire its exact app lease in time.")
            }

            taskRuntime.begin(app: fixtures[1].name)
            taskRuntime.update(requests[1], final: true)
            let taskDeadline = Date().addingTimeInterval(120)
            var observedParallelProgress = false
            var foregroundStayedPut = true
            while Date() < taskDeadline {
                let works = taskRuntime.tasks
                if works.count >= 2 {
                    let pair = Array(works.suffix(2))
                    if pair.allSatisfy({ $0.active && $0.status == "Working" }) {
                        observedParallelProgress = true
                    }
                    if pair.allSatisfy({ !$0.active }) { break }
                }
                if let foregroundBeforeTasks,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundBeforeTasks {
                    foregroundStayedPut = false
                }
                if works.suffix(2).contains(where: { $0.status == "Failed" || $0.status == "Cancelled" }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let works = taskRuntime.tasks
            XCTAssertEqual(works.count, 2)
            XCTAssertTrue(observedParallelProgress, "Both unrelated background tasks must be Working at the same time.")
            XCTAssertTrue(foregroundStayedPut, "Background tasks must preserve the pre-task foreground app.")
            for (work, fixture) in zip(works, fixtures) {
                XCTAssertFalse(work.active, "Task did not reach a terminal result: \(work.message)")
                XCTAssertEqual(work.status, "Completed", work.message)
                XCTAssertEqual(work.bundle, fixture.bundleID)
                XCTAssertEqual(work.window, fixture.windowID)
            }
            for fixture in fixtures {
                let observed = try await observer.call("get_window_state", arguments: [
                    "pid": .number(Double(fixture.process.processIdentifier)),
                    "window_id": .number(Double(fixture.windowID)), "include_screenshot": .bool(false),
                    "session": .string(observerSession)
                ])
                let fields = (observed["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
                let value = try XCTUnwrap(fields.first?["value"]?.string)
                XCTAssertEqual(value.components(separatedBy: fixture.inserted).count - 1, 1)
                let range = try XCTUnwrap(value.range(of: fixture.inserted))
                XCTAssertEqual(value.replacingCharacters(in: range, with: ""), fixture.seed,
                               "Each task may only append its exact literal to its own named window.")
            }
            if let foregroundBeforeTasks {
                XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, foregroundBeforeTasks)
            }
            let queueWaits = works.map { $0.timings["Queue wait"] ?? -1 }
            let taskOutcomes = works.map { "\($0.bundle ?? "unknown") window \($0.window ?? -1): \($0.status)" }
            print("Parallel runtime fixture: model requests \(modelCalls); queue waits \(queueWaits); tasks \(taskOutcomes); foreground PID \(foregroundBeforeTasks.map { String($0) } ?? "unknown").")
            await restoreAndClean()
        } catch {
            await restoreAndClean()
            throw error
        }
    }

    func testNativeExecutionPostconditionsOptIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let literalTrial = environment["JARVIS_CUA_RUNTIME_LITERAL_TEST"] == "1"
        let keyboardTrial = environment["JARVIS_CUA_RUNTIME_KEY_TEST"] == "1"
        guard literalTrial != keyboardTrial else {
            throw XCTSkip("Set exactly one opt-in flag for a production text or candidate keyboard trial")
        }
        let key = try CuaLiveCredential.jev()
        let connection = try CuaLiveDriver.connection()
        try await connection.connect()
        let session = "Jarvis runtime literal \(UUID().uuidString.prefix(8))"
        _ = try await connection.call("start_session", arguments: ["session": .string(session)])

        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let displayName = "Jarvis Runtime Fixture \(identifier.prefix(8))"
        let windowTitle = "Disposable text \(identifier.prefix(8))"
        let bundleID = "com.jarvis.fixture.\(identifier)"
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("\(displayName).app")
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("JarvisFixture-\(identifier).swift")
        let executable = executableDirectory.appendingPathComponent("JarvisRuntimeFixture")
        let seed = "Existing disposable text must remain unchanged."
        let inserted = "copper lantern beside the window"
        let priorPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var fixturePID: Int32?
        var runtime: CuaVoiceRuntime?

        do {
            try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleExecutable": "JarvisRuntimeFixture",
                "CFBundleIdentifier": bundleID,
                "CFBundleName": displayName,
                "CFBundlePackageType": "APPL",
                "NSPrincipalClass": "NSApplication"
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            let appSource = #"""
            import AppKit

            final class FixtureDelegate: NSObject, NSApplicationDelegate {
                var window: NSWindow!
                func applicationDidFinishLaunching(_ notification: Notification) {
                    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
                    scroll.hasVerticalScroller = true
                    scroll.autoresizingMask = [.width, .height]
                    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
                    text.string = "__SEED__"
                    text.isEditable = true
                    text.isSelectable = true
                    scroll.documentView = text
                    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.title = "__TITLE__"
                    window.contentView = scroll
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = FixtureDelegate()
            app.delegate = delegate
            app.run()
            """#
            .replacingOccurrences(of: "__SEED__", with: seed)
            .replacingOccurrences(of: "__TITLE__", with: windowTitle)
            try appSource.write(to: source, atomically: true, encoding: .utf8)

            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["swiftc", source.path, "-framework", "AppKit", "-o", executable.path]
            let compilerError = Pipe()
            compiler.standardError = compilerError
            try compiler.run()
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else {
                let detail = String(data: compilerError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw DriverConnectionError.refused("The disposable native fixture did not build: \(detail.prefix(500))")
            }

            let process = Process()
            process.executableURL = executable
            try process.run()
            fixturePID = process.processIdentifier
            var windowID: Int?
            var initialText: String?
            var lastWindows: [JSONValue] = []
            var lastFields: [String] = []
            for _ in 0..<100 {
                let windows = try await connection.call("list_windows", arguments: ["pid": .number(Double(process.processIdentifier)), "session": .string(session)])
                lastWindows = windows["windows"]?.array ?? []
                let exact = lastWindows.filter { $0["title"] == .string(windowTitle) }
                if exact.count == 1 {
                    windowID = exact[0]["window_id"]?.integer
                    if let windowID {
                        let state = try await connection.call("get_window_state", arguments: [
                            "pid": .number(Double(process.processIdentifier)), "window_id": .number(Double(windowID)),
                            "include_screenshot": .bool(false), "session": .string(session)
                        ])
                        let fields = (state["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
                        lastFields = (state["elements"]?.array ?? []).map {
                            "\($0["role"]?.string ?? "?") label=\($0["label"]?.string ?? "") valueLength=\($0["value"]?.string?.count ?? -1) token=\($0["element_token"]?.string != nil)"
                        }
                        if fields.count == 1 { initialText = fields[0]["value"]?.string }
                    }
                    if initialText == seed { break }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let windowID, initialText == seed else {
                let permissions = try? await connection.call("check_permissions", arguments: ["prompt": .bool(false), "session": .string(session)])
                print("Native fixture preflight: pid", process.processIdentifier, "running", process.isRunning,
                      "permissions", permissions?[
                        "accessibility"]?.bool ?? false, permissions?["screen_recording"]?.bool ?? false,
                      "windows", lastWindows.map { "\($0["title"]?.string ?? "")#\($0["window_id"]?.integer ?? -1)" },
                      "fields", lastFields)
                throw DriverConnectionError.refused("Cua did not observe the exact disposable native text target and seed.")
            }
            let observedApp = try await connection.call("get_accessibility_tree", arguments: ["session": .string(session)])
            guard (observedApp["apps"]?.array ?? []).contains(where: {
                $0["bundle_id"] == .string(bundleID) && $0["pid"] == .number(Double(process.processIdentifier))
            }) else { throw DriverConnectionError.refused("Cua did not identify the disposable fixture's exact process.") }

            // Restore the prior foreground app before the production request.
            if let priorPID, let prior = NSRunningApplication(processIdentifier: priorPID) {
                _ = prior.activate(options: [])
                for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != priorPID {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let originalFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

            let model = JevClient(apiKey: key)
            var modelCalls = 0
            var keyDispatches = 0
            var accidentalTextDispatches = 0
            var keyToolCalls: [String] = []
            var keyFailure: String?
            let preInsertionBody = seed
            if keyboardTrial {
                let keyLoop = CuaAgentLoop(call: { tool, arguments in
                    keyToolCalls.append(tool)
                    if tool == "press_key" { keyDispatches += 1 }
                    if tool == "type_text" { accidentalTextDispatches += 1 }
                    return try await connection.call(tool, arguments: arguments.merging(["session": .string(session)]) { _, value in value })
                }, judge: { state, questions in
                    modelCalls += 1
                    let response = try await model.systemOne(state: state, questions: questions).response.answers
                    for (key, answer) in response {
                        guard case let .choice(choice, _, _) = answer,
                              case let .choice(_, criteria)? = questions[key] else { continue }
                        let label = criteria[choice].flatMap { $0 } ?? choice
                        print("Candidate key Jev \(key):", label)
                    }
                    return response
                })
                do {
                    let r = try await keyLoop.drive(DriveTask(
                        goal: "In the foreground, press the key \"return\" in the text area of \(displayName), window \(windowTitle). One disposable native text fixture with an exact, observed window.",
                        pid: Int(process.processIdentifier), windowID: windowID))
                    if case .done = r.status {} else { keyFailure = r.history.last ?? "\(r.status)" }
                } catch { keyFailure = error.localizedDescription }
                XCTAssertEqual(keyDispatches, 1, "The quoted key must select one bound press_key action.")
                XCTAssertEqual(accidentalTextDispatches, 0, "A key label must never become text insertion data.")
                var afterKeyBody: String?
                for _ in 0..<30 {
                    let afterKey = try await connection.call("get_window_state", arguments: [
                        "pid": .number(Double(process.processIdentifier)), "window_id": .number(Double(windowID)),
                        "include_screenshot": .bool(false), "session": .string(session)
                    ])
                    afterKeyBody = (afterKey["elements"]?.array ?? []).first { $0["role"] == .string("AXTextArea") }?["value"]?.string
                    if afterKeyBody != seed { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if let keyFailure {
                    XCTAssertFalse(keyFailure.isEmpty, keyFailure)
                    XCTAssertTrue(afterKeyBody == seed || afterKeyBody == seed + "\n",
                                  "The key's delayed effect, if any, must be observed only in the disposable window.")
                } else {
                    XCTAssertEqual(afterKeyBody, seed + "\n", "A successful Return must have one independently observed effect.")
                }
                let foregroundAfterKey = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if keyToolCalls.contains("bring_to_front") {
                    XCTAssertEqual(foregroundAfterKey, process.processIdentifier,
                                   "An explicit foreground request may leave its exact disposable target in front.")
                } else if let originalFrontmostPID {
                    XCTAssertEqual(foregroundAfterKey, originalFrontmostPID,
                                   "Cua's foreground key route must restore the prior frontmost app.")
                }
                if let originalFrontmostPID, let prior = NSRunningApplication(processIdentifier: originalFrontmostPID) {
                    _ = prior.activate(options: [])
                    for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != originalFrontmostPID {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                print("Candidate key fixture: failure \(keyFailure ?? "none"); readback \(afterKeyBody == seed + "\n" ? "one newline" : "unchanged"); Jev requests \(modelCalls); key dispatches \(keyDispatches); activation calls \(keyToolCalls.filter { $0 == "bring_to_front" }.count); window \(windowID).")
                _ = try await connection.call("end_session", arguments: ["session": .string(session)])
                await connection.close()
                if let app = NSRunningApplication(processIdentifier: process.processIdentifier) {
                    app.terminate()
                    for _ in 0..<50 where !app.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
                }
                try? FileManager.default.removeItem(at: bundle)
                try? FileManager.default.removeItem(at: source)
                return
            }

            let config = Config(defaults: UserDefaults(suiteName: "CuaVoiceRuntimeLiveTests-\(identifier)")!,
                                keyStore: FixtureKeyStore(key: key), environment: [:])
            let toolCalls = ToolCalls()
            let taskRuntime = CuaVoiceRuntime(config: config, makeConnection: { CuaConnection(onToolCall: { tool, length in toolCalls.record(tool, textLength: length) }) }, judge: { state, questions in
                modelCalls += 1
                let response = try await model.systemOne(state: state, questions: questions).response.answers
                for (key, answer) in response {
                    guard case let .choice(choice, _, _) = answer,
                          case let .choice(_, criteria)? = questions[key] else { continue }
                    let label = criteria[choice].flatMap { $0 } ?? choice
                    print("Production Jev \(key):", label)
                }
                return response
            })
            runtime = taskRuntime
            taskRuntime.begin(app: displayName)
            taskRuntime.update("Dictate exactly \"\(inserted)\" into the existing text area in \(displayName), window \(windowTitle). Preserve all existing text.", final: true)
            for _ in 0..<900 {
                if taskRuntime.tasks.first?.active == false { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let work = try XCTUnwrap(taskRuntime.tasks.first)
            XCTAssertFalse(work.active, "The production runtime did not reach a terminal state: \(work.message)")
            XCTAssertEqual(work.status, "Completed", work.message)
            XCTAssertEqual(work.bundle, bundleID)
            XCTAssertEqual(work.window, windowID)
            XCTAssertTrue(work.dispatchedEffect)
            let runtimeCalls = toolCalls.snapshot()
            XCTAssertEqual(runtimeCalls.tools["type_text"], 1, "An uncertain insertion must never be replayed.")
            XCTAssertEqual(runtimeCalls.textLengths, [inserted.count], "Cua must receive the complete source phrase exactly once.")

            let result = try await connection.call("get_window_state", arguments: [
                "pid": .number(Double(process.processIdentifier)), "window_id": .number(Double(windowID)),
                "include_screenshot": .bool(false), "session": .string(session)
            ])
            let bodies = (result["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
            let actual = try XCTUnwrap(bodies.first?["value"]?.string)
            XCTAssertEqual(actual.components(separatedBy: inserted).count - 1, 1, "The exact literal must occur once.")
            let range = try XCTUnwrap(actual.range(of: inserted))
            XCTAssertEqual(actual.replacingCharacters(in: range, with: ""), preInsertionBody, "Removing the one inserted literal must restore the preceding document exactly.")
            if let originalFrontmostPID {
                XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, originalFrontmostPID,
                               "A background text action must preserve the pre-request foreground app.")
            }
            print("Production literal fixture: request \(work.request); status \(work.status): \(work.message); previous document length \(preInsertionBody.count); Jev requests: \(modelCalls); runtime Driver calls: \(runtimeCalls.tools), text argument lengths: \(runtimeCalls.textLengths); keyboard candidate dispatched \(keyboardTrial); window: \(windowID).")
            await taskRuntime.shutdown()
            _ = try await connection.call("end_session", arguments: ["session": .string(session)])
            await connection.close()
        } catch {
            await runtime?.shutdown()
            _ = try? await connection.call("end_session", arguments: ["session": .string(session)])
            await connection.close()
            if let fixturePID, let app = NSRunningApplication(processIdentifier: fixturePID) {
                app.terminate()
                for _ in 0..<50 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
            }
            try? FileManager.default.removeItem(at: bundle)
            try? FileManager.default.removeItem(at: source)
            throw error
        }

        if let fixturePID, let app = NSRunningApplication(processIdentifier: fixturePID) {
            app.terminate()
            for _ in 0..<50 where !app.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
        }
        try? FileManager.default.removeItem(at: bundle)
        try? FileManager.default.removeItem(at: source)
    }

    /// Temporary diagnostic: reproduce the physical "add 7+7" Calculator run
    /// where the task reported finished after only "7+" landed. Records the
    /// full Jev decision trail plus the driver tool sequence, then reads the
    /// Calculator display independently.
    func testCalculatorMathReproOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_CALC_REPRO_TEST"] == "1" else {
            throw XCTSkip("Opt-in Calculator math reproduction against the real desktop")
        }
        let key = try CuaLiveCredential.jev()
        let connection = try CuaLiveDriver.connection()
        try await connection.connect()
        let session = "Jarvis calc repro \(UUID().uuidString.prefix(8))"
        _ = try await connection.call("start_session", arguments: ["session": .string(session)])

        let calcURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let configuration = NSWorkspace.OpenConfiguration()
        let calc = try await NSWorkspace.shared.openApplication(at: calcURL, configuration: configuration)
        let pid = calc.processIdentifier
        var windowID: Int?
        for _ in 0..<100 {
            let windows = try await connection.call("list_windows", arguments: ["pid": .number(Double(pid)), "session": .string(session)])
            if let first = (windows["windows"]?.array ?? []).first {
                windowID = first["window_id"]?.integer
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let windowID else { throw DriverConnectionError.refused("Calculator window never observed") }
        _ = calc.activate(options: [])
        for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            try await Task.sleep(for: .milliseconds(100))
        }

        let model = JevClient(apiKey: key)
        let config = Config(defaults: UserDefaults(suiteName: "CuaCalcRepro-\(UUID().uuidString)")!,
                            keyStore: FixtureKeyStore(key: key), environment: [:])
        let toolCalls = ToolCalls()
        let runtime = CuaVoiceRuntime(config: config, makeConnection: { CuaConnection(onToolCall: { tool, length in
            print("REPRO driver call:", tool, "textLength", length.map(String.init) ?? "-")
            toolCalls.record(tool, textLength: length)
        }) }, judge: { state, questions in
            let response = try await model.systemOne(state: state, questions: questions).response.answers
            for (key, answer) in response {
                guard case let .choice(choice, _, _) = answer,
                      case let .choice(_, criteria)? = questions[key] else { continue }
                let label = criteria[choice].flatMap { $0 } ?? choice
                print("REPRO Jev \(key):", label)
            }
            return response
        })
        runtime.begin(app: "Calculator")
        runtime.update("Add 7+7", final: true)
        for _ in 0..<900 {
            if runtime.tasks.first?.active == false { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let work = try XCTUnwrap(runtime.tasks.first)
        print("REPRO outcome: active \(work.active); status \(work.status); message \(work.message); request \(work.request)")

        let state = try await connection.call("get_window_state", arguments: [
            "pid": .number(Double(pid)), "window_id": .number(Double(windowID)),
            "include_screenshot": .bool(false), "session": .string(session)
        ])
        let display = (state["elements"]?.array ?? []).compactMap { element -> String? in
            guard let value = element["value"]?.string, !value.isEmpty else { return nil }
            return "\(element["role"]?.string ?? "?")=\(value)"
        }
        print("REPRO Calculator display elements:", display)
        let snapshot = toolCalls.snapshot()
        print("REPRO tools:", snapshot.tools, "textLengths:", snapshot.textLengths)
        XCTAssertEqual(snapshot.tools["type_text"], 1,
            "The expression must arrive as one process-scoped keyboard dispatch")
        XCTAssertEqual(snapshot.textLengths, [4], "The bound payload is exactly \"7+7=\"")
        XCTAssertLessThanOrEqual(snapshot.tools["click"] ?? 0, 2,
            "Blind per-button retyping must not replace the keyboard dispatch")
        if work.status == "Completed" {
            XCTAssertEqual(snapshot.tools["parse_visual_regions"], 1,
                "Completion requires observed evidence; Calculator exposes no readable AX value, so visual inspection must have run")
        }
        await runtime.shutdown()
        _ = try await connection.call("end_session", arguments: ["session": .string(session)])
        await connection.close()
    }

    /// Temporary diagnostic: reproduce the reported "open a new tab in google
    /// chrome" failure against the real Chrome instance. Chrome keeps ~9
    /// invisible helper windows; the runtime must pick the one plausible
    /// window itself, not ask. Asserts a tab was actually created.
    func testChromeNewTabReproOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_CHROME_TAB_TEST"] == "1" else {
            throw XCTSkip("Opt-in real-Chrome new-tab reproduction under the desktop lock")
        }
        let key = try CuaLiveCredential.jev()
        let connection = try CuaLiveDriver.connection()
        try await connection.connect()
        let session = "Jarvis chrome tab \(UUID().uuidString.prefix(8))"
        _ = try await connection.call("start_session", arguments: ["session": .string(session)])

        let chrome: NSRunningApplication
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
            chrome = running
        } else {
            chrome = try await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
                configuration: NSWorkspace.OpenConfiguration())
        }
        let pid = chrome.processIdentifier
        _ = chrome.activate(options: [])
        for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            try await Task.sleep(for: .milliseconds(100))
        }

        func plausibleWindow() async throws -> Int? {
            let windows = (try await connection.call("list_windows", arguments: [
                "pid": .number(Double(pid)), "session": .string(session)]))["windows"]?.array ?? []
            let visible = windows.filter { $0["is_on_screen"] != .bool(false) }
            var candidates = visible.filter { !($0["title"]?.string ?? "").isEmpty }
            if candidates.isEmpty { candidates = visible.isEmpty ? windows.filter { !($0["title"]?.string ?? "").isEmpty } : visible }
            return candidates.count == 1 ? candidates[0]["window_id"]?.integer : nil
        }
        /// Suspension changes radio labels ("…Inactive tab - N MB freed up"), so
        /// raw counts are unstable; compare the label multiset instead.
        func tabLabels(_ windowID: Int) async throws -> [String] {
            let state = try await connection.call("get_window_state", arguments: [
                "pid": .number(Double(pid)), "window_id": .number(Double(windowID)),
                "include_screenshot": .bool(false), "max_elements": .number(220), "session": .string(session)])
            return (state["elements"]?.array ?? []).compactMap {
                ["AXRadioButton", "AXTab"].contains($0["role"]?.string ?? "") ? $0["label"]?.string : nil
            }
        }
        var windowID: Int?
        for _ in 0..<100 where windowID == nil {
            windowID = try await plausibleWindow()
            try await Task.sleep(for: .milliseconds(100))
        }
        let wid = try XCTUnwrap(windowID, "Chrome had no plausible window to attach")
        let tabsBefore = try await tabLabels(wid)
        print("REPRO tabs before:", tabsBefore.count)

        let model = JevClient(apiKey: key)
        let config = Config(defaults: UserDefaults(suiteName: "CuaChromeTab-\(UUID().uuidString)")!,
                            keyStore: FixtureKeyStore(key: key), environment: [:])
        let toolCalls = ToolCalls()
        let runtime = CuaVoiceRuntime(config: config, makeConnection: { CuaConnection(onToolCall: { tool, length in
            print("REPRO driver call:", tool, "textLength", length.map(String.init) ?? "-")
            toolCalls.record(tool, textLength: length)
        }) }, judge: { state, questions in
            let response = try await model.systemOne(state: state, questions: questions).response.answers
            for (key, answer) in response {
                guard case let .choice(choice, _, _) = answer,
                      case let .choice(_, criteria)? = questions[key] else { continue }
                print("REPRO Jev \(key):", criteria[choice].flatMap { $0 } ?? choice)
            }
            return response
        })
        runtime.begin(app: "Google Chrome")
        runtime.update("open a new tab in google chrome", final: true)
        var approvedConsent = false
        for _ in 0..<900 {
            if runtime.tasks.first?.active == false { break }
            // Answer the consent prompt the way a user tapping Confirm does.
            if let work = runtime.tasks.first, work.approval != nil {
                approvedConsent = true
                runtime.resolveApproval(work.id, approved: true)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("REPRO consent prompt seen+approved:", approvedConsent)
        let work = try XCTUnwrap(runtime.tasks.first)
        print("REPRO outcome: active \(work.active); status \(work.status); message \(work.message)")
        let snapshot = toolCalls.snapshot()
        print("REPRO tools:", snapshot.tools)

        let tabsAfter = try await tabLabels(wid)
        print("REPRO tabs after:", tabsAfter.count)
        await runtime.shutdown()
        _ = try await connection.call("end_session", arguments: ["session": .string(session)])
        await connection.close()

        XCTAssertFalse(work.message.contains("Which window"), "Phantom windows must not surface a question")
        // A fresh tab is labeled "New Tab" until navigated; suspensions rename
        // other tabs, so assert on the label that could only come from creation.
        let newTabs = { (labels: [String]) in labels.filter { $0.hasPrefix("New Tab") }.count }
        XCTAssertTrue(newTabs(tabsAfter) > newTabs(tabsBefore) || tabsAfter.count > tabsBefore.count,
                      "A new tab must actually exist in the Chrome window (before: \(tabsBefore), after: \(tabsAfter))")
    }

    /// Temporary diagnostic: feed the reported "open a new tab" transcripts
    /// through the real planner path and print its decisions, then replay
    /// an answer utterance against a synthetic pending clarification to see
    /// whether it routes back or loops into a fresh question.
    func testChromeTabClarificationProbeOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_DECIDE_PROBE"] == "1" else {
            throw XCTSkip("Opt-in planner probe against the real text provider")
        }
        let brain = CompanionBrain(settings: .shared)

        for text in [
            "can you open a new tab in google with my google chrome open",
            "open a new tab in google chrome",
            "open a new tab",
            "new tab in chrome",
        ] {
            print("PROBE ===> \"\(text)\"")
            do {
                let decision = try await brain.decide(utterance: text, context: PlannerContext())
                print("PROBE decision:", decision)
            } catch { print("PROBE threw:", error) }
        }

        // A pending task-clarification question, then a short reply that should route as an answer.
        let pending = PlannerContext(pendingClarify: ClarifyRequest(
            question: "Which task do you mean?", options: ["open a new tab in google chrome"]))
        for reply in ["open a new tab in chrome", "the new tab", "that one", "yes"] {
            print("PROBE reply ===> \"\(reply)\"")
            do {
                let decision = try await brain.decide(utterance: reply, context: pending)
                print("PROBE reply decision:", decision)
            } catch { print("PROBE reply threw:", error) }
        }
    }

    /// Opt-in clarification workflow on a disposable two-window fixture: an
    /// ambiguous dictate request must surface a pending question rather than
    /// substitute a window; the answering utterance then resumes the same
    /// intent in place, and the literal may land only in the answered window.
    func testClarificationAnswerResumeBindsOwnerOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_RUNTIME_DIALOGUE_TEST"] == "1" else {
            throw XCTSkip("Opt-in clarification/answer resume in a disposable two-window fixture")
        }
        let key = try CuaLiveCredential.jev()
        let connection = try CuaLiveDriver.connection()
        try await connection.connect()
        let session = "Jarvis dialogue \(UUID().uuidString.prefix(8))"
        _ = try await connection.call("start_session", arguments: ["session": .string(session)])

        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let displayName = "Jarvis Dialogue \(identifier.prefix(6))"
        let bundleID = "com.jarvis.dialogue.\(identifier)"
        let titleA = "Dialogue first \(identifier.prefix(6))"
        let titleB = "Dialogue second \(identifier.prefix(6))"
        let seedA = "Seed A must stay intact."
        let seedB = "Seed B baseline."
        let inserted = "dialogue marker \(identifier.prefix(4))"
        let priorPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("JarvisDialogue-\(identifier).app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/JarvisDialogueFixture")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("JarvisDialogue-\(identifier).swift")
        var fixturePID: pid_t?
        var runtime: CuaVoiceRuntime?

        func restoreAndClean() async {
            await runtime?.shutdown()
            _ = try? await connection.call("end_session", arguments: ["session": .string(session)])
            await connection.close()
            if let fixturePID, let app = NSRunningApplication(processIdentifier: fixturePID) {
                app.terminate()
                for _ in 0..<50 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
            }
            try? FileManager.default.removeItem(at: bundle)
            try? FileManager.default.removeItem(at: source)
            if let priorPID, let prior = NSRunningApplication(processIdentifier: priorPID) {
                _ = prior.activate(options: [])
                for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != priorPID {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        do {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleExecutable": "JarvisDialogueFixture",
                "CFBundleIdentifier": bundleID,
                "CFBundleName": displayName,
                "CFBundleDisplayName": displayName,
                "CFBundlePackageType": "APPL",
                "NSPrincipalClass": "NSApplication"
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            let appSource = #"""
            import AppKit

            final class FixtureDelegate: NSObject, NSApplicationDelegate {
                var windows: [NSWindow] = []
                func applicationDidFinishLaunching(_ notification: Notification) {
                    for index in 0..<2 {
                        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
                        scroll.hasVerticalScroller = true
                        scroll.autoresizingMask = [.width, .height]
                        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
                        text.string = CommandLine.arguments[3 + index]
                        text.isEditable = true
                        text.isSelectable = true
                        scroll.documentView = text
                        let window = NSWindow(contentRect: NSRect(x: 120 + index * 160, y: 120 + index * 40,
                                                                  width: 560, height: 320),
                                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                        window.title = CommandLine.arguments[1 + index]
                        window.contentView = scroll
                        window.makeKeyAndOrderFront(nil)
                        windows.append(window)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = FixtureDelegate()
            app.delegate = delegate
            app.run()
            """#
            try appSource.write(to: source, atomically: true, encoding: .utf8)

            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["swiftc", source.path, "-framework", "AppKit", "-o", executable.path]
            let compilerError = Pipe()
            compiler.standardError = compilerError
            try compiler.run()
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else {
                let detail = String(data: compilerError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw DriverConnectionError.refused("The disposable dialogue fixture did not build: \(detail.prefix(500))")
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = [titleA, titleB, seedA, seedB]
            try process.run()
            fixturePID = process.processIdentifier

            var windowIDs: [String: Int] = [:]
            for _ in 0..<100 where windowIDs.count < 2 {
                let windows = try await connection.call("list_windows", arguments: [
                    "pid": .number(Double(process.processIdentifier)), "session": .string(session)])
                for window in windows["windows"]?.array ?? [] {
                    guard let title = window["title"]?.string, let id = window["window_id"]?.integer else { continue }
                    windowIDs[title] = id
                }
                if windowIDs[titleA] != nil && windowIDs[titleB] != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard windowIDs.count == 2 else {
                throw DriverConnectionError.refused("Cua did not observe both disposable dialogue windows.")
            }
            if let priorPID, let prior = NSRunningApplication(processIdentifier: priorPID) {
                _ = prior.activate(options: [])
                for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != priorPID {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }

            let model = JevClient(apiKey: key)
            var modelCalls = 0
            let toolCalls = ToolCalls()
            let config = Config(defaults: UserDefaults(suiteName: "CuaVoiceRuntimeDialogue-\(identifier)")!,
                                keyStore: FixtureKeyStore(key: key), environment: [:])
            let taskRuntime = CuaVoiceRuntime(config: config,
                makeConnection: { CuaConnection(onToolCall: { tool, length in toolCalls.record(tool, textLength: length) }) },
                judge: { state, questions in
                    modelCalls += 1
                    let response = try await model.systemOne(state: state, questions: questions).response.answers
                    for (key, answer) in response {
                        guard case let .choice(choice, _, _) = answer,
                              case let .choice(_, criteria)? = questions[key] else { continue }
                        print("Dialogue Jev \(key):", criteria[choice].flatMap { $0 } ?? choice)
                    }
                    return response
                })
            runtime = taskRuntime

            taskRuntime.begin(app: displayName)
            taskRuntime.update("Dictate exactly \"\(inserted)\" into a text area in \(displayName). Preserve all existing text.", final: true)
            let firstDeadline = Date().addingTimeInterval(120)
            while Date() < firstDeadline {
                if let first = taskRuntime.tasks.first, !first.active { break }
                if taskRuntime.dialogue.entries.contains(where: {
                    if case .awaitingAnswer = $0.status { return true }
                    return false
                }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let ambiguous = try XCTUnwrap(taskRuntime.tasks.first)
            XCTAssertFalse(ambiguous.active, "The ambiguous request must settle: \(ambiguous.message)")
            let awaiting = taskRuntime.dialogue.entries.contains(where: {
                if case .awaitingAnswer = $0.status { return true }
                return false
            })
            XCTAssertTrue(awaiting || ambiguous.status == "Completed",
                "Ambiguity must either ask or pick verifiably — never claim otherwise: \(ambiguous.message)")
            XCTAssertEqual(toolCalls.snapshot().tools["type_text"] ?? 0,
                           awaiting ? 0 : 1,
                           "No literal may dispatch while the window is unresolved")

            if awaiting {
                // The answering utterance resumes the question's owner in place:
                // same intent id, exactly one follow-up work record, and the
                // literal may be dispatched at most once in a single window.
                taskRuntime.update("Use the window titled \"\(titleB)\".", final: true)
                let resumeDeadline = Date().addingTimeInterval(120)
                while Date() < resumeDeadline {
                    let works = taskRuntime.tasks
                    if works.count >= 2, works.last?.active == false { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let resumed = try XCTUnwrap(taskRuntime.tasks.last)
                XCTAssertEqual(taskRuntime.tasks.count, 2, "An answer never adds a second intent's work")
                XCTAssertEqual(resumed.intentID, ambiguous.intentID,
                    "The answering utterance resumes the pending question's owner in place")
                XCTAssertFalse(resumed.active, "The resumed attempt must settle: \(resumed.message)")
            }

            guard let windowA = windowIDs[titleA], let windowB = windowIDs[titleB] else {
                throw DriverConnectionError.refused("Both fixture window ids must be known.")
            }
            let stateA = try await connection.call("get_window_state", arguments: [
                "pid": .number(Double(process.processIdentifier)), "window_id": .number(Double(windowA)),
                "include_screenshot": .bool(false), "session": .string(session)])
            let stateB = try await connection.call("get_window_state", arguments: [
                "pid": .number(Double(process.processIdentifier)), "window_id": .number(Double(windowB)),
                "include_screenshot": .bool(false), "session": .string(session)])
            let bodyA = (stateA["elements"]?.array ?? []).first { $0["role"] == .string("AXTextArea") }?["value"]?.string
            let bodyB = (stateB["elements"]?.array ?? []).first { $0["role"] == .string("AXTextArea") }?["value"]?.string
            let dispatches = toolCalls.snapshot().tools["type_text"] ?? 0
            let inA = bodyA?.contains(inserted) ?? false
            let inB = bodyB?.contains(inserted) ?? false
            if awaiting {
                // The answer named the destination window; the resumed attempt
                // must bind that answer — a dispatch into A or no dispatch at all
                // means the reply never reached the re-asked question.
                XCTAssertEqual(dispatches, 1,
                    "The answer resolved the only ambiguity; the literal must dispatch exactly once")
                XCTAssertTrue(inB, "The answer named \"\(titleB)\"; the literal must land in that window")
                XCTAssertFalse(inA, "The unanswered window must stay untouched")
                XCTAssertEqual(bodyB, seedB + inserted,
                    "Removing the literal restores the answered window's seed exactly")
                XCTAssertEqual(bodyA, seedA, "The unanswered window keeps its seed untouched")
            } else {
                XCTAssertLessThanOrEqual(dispatches, 1, "The literal is dispatched at most once")
                if dispatches == 0 {
                    XCTAssertFalse(inA || inB, "Without a dispatch no window may carry the literal")
                    XCTAssertEqual(bodyA, seedA)
                    XCTAssertEqual(bodyB, seedB)
                } else {
                    XCTAssertNotEqual(inA, inB,
                        "Any dispatched literal lands in exactly one observed window — never substituted or duplicated")
                    XCTAssertEqual(inA ? bodyA : bodyB, (inA ? seedA : seedB) + inserted,
                        "Removing the one literal restores that window's seed exactly")
                    XCTAssertEqual(inA ? bodyB : bodyA, inA ? seedB : seedA,
                        "The unselected window keeps its seed untouched")
                }
            }
            print("Dialogue fixture: ambiguous \(ambiguous.status): \(ambiguous.message); resumed \(taskRuntime.tasks.last?.status ?? "none"): \(taskRuntime.tasks.last?.message ?? ""); Jev requests \(modelCalls); type_text dispatches \(dispatches).")
        } catch {
            await restoreAndClean()
            throw error
        }
        await restoreAndClean()
    }

    /// Broad smoke: one runtime, one driver session, real commands across many
    /// real apps — the same path the typed command box and voice capture use.
    /// Every row is verified by independent observation, never by trusting a
    /// dispatch response. One command failing must not hide the rest, so rows
    /// collect their verdicts and report together.
    func testBroadAppCommandMatrixOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_MATRIX_TEST"] == "1" else {
            throw XCTSkip("Opt-in broad real-app command matrix under the desktop lock")
        }
        let key = try CuaLiveCredential.jev()
        let observer = try CuaLiveDriver.connection()
        try await observer.connect()
        let observerSession = "Jarvis matrix observer \(UUID().uuidString.prefix(8))"
        _ = try await observer.call("start_session", arguments: ["session": .string(observerSession)])

        let priorPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let model = JevClient(apiKey: key)
        let toolCalls = ToolCalls()
        let config = Config(defaults: UserDefaults(suiteName: "CuaVoiceRuntimeMatrix-\(UUID().uuidString)")!,
                            keyStore: FixtureKeyStore(key: key), environment: [:])
        let runtime = CuaVoiceRuntime(config: config,
            makeConnection: { CuaConnection(onToolCall: { tool, length in
                print("MATRIX driver call:", tool)
                toolCalls.record(tool, textLength: length)
            }) },
            judge: { state, questions in
                let answers = try await model.systemOne(state: state, questions: questions).response.answers
                for (key, answer) in answers {
                    guard case let .choice(choice, _, _) = answer,
                          case let .choice(_, criteria)? = questions[key] else { continue }
                    print("MATRIX Jev \(key):", criteria[choice].flatMap { $0 } ?? choice)
                }
                return answers
            })

        func frontmost(_ bundleID: String) async -> Bool {
            // The open lane verifies with the driver's own is_frontmost read;
            // NSWorkspace can lag a moment behind a just-raised window.
            for _ in 0..<25 {
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
                try? await Task.sleep(for: .milliseconds(80))
            }
            return false
        }
        func onScreenWindows(_ bundleID: String) async throws -> Int {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return 0 }
            let listed = try await observer.call("list_windows", arguments: [
                "pid": .number(Double(running.processIdentifier)), "session": .string(observerSession)])
            return (listed["windows"]?.array ?? []).filter { $0["is_on_screen"] != .bool(false) }.count
        }
        func isRunning(_ bundleID: String) async -> Bool {
            for _ in 0..<25 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return false }
                try? await Task.sleep(for: .milliseconds(80))
            }
            return true
        }
        func awaitingCount() -> Int {
            runtime.dialogue.entries.filter {
                if case .awaitingAnswer = $0.status { return true }
                return false
            }.count
        }
        func lastQuestion() -> String {
            runtime.dialogue.entries.last {
                if case .awaitingAnswer = $0.status { return true }
                return false
            }?.question?.prompt ?? ""
        }

        struct Row {
            let command: String
            let label: String
            let verify: () async throws -> Bool
        }
        let rows: [Row] = [
            Row(command: "open Calculator", label: "open Calculator → frontmost",
                verify: { await frontmost("com.apple.calculator") }),
            Row(command: "open TextEdit", label: "open TextEdit → frontmost",
                verify: { await frontmost("com.apple.TextEdit") }),
            Row(command: "open Notes", label: "open Notes → frontmost",
                verify: { await frontmost("com.apple.Notes") }),
            Row(command: "open Music", label: "open Music → frontmost",
                verify: { await frontmost("com.apple.Music") }),
            Row(command: "open Terminal", label: "open Terminal → frontmost",
                verify: { await frontmost("com.apple.Terminal") }),
            Row(command: "open Finder", label: "open Finder → frontmost",
                verify: { await frontmost("com.apple.finder") }),
            Row(command: "open System Settings", label: "open System Settings → frontmost",
                verify: { await frontmost("com.apple.systempreferences") }),
            // Calculator returns to front so window verbs target unambiguously.
            Row(command: "open Calculator", label: "raise existing Calculator → frontmost",
                verify: { await frontmost("com.apple.calculator") }),
            Row(command: "hide Calculator", label: "hide Calculator → no on-screen windows",
                verify: { try await onScreenWindows("com.apple.calculator") == 0 }),
            Row(command: "show Calculator", label: "show Calculator → frontmost again",
                verify: { await frontmost("com.apple.calculator") }),
            Row(command: "minimize the Calculator window", label: "minimize → no on-screen windows",
                verify: { try await onScreenWindows("com.apple.calculator") == 0 }),
            Row(command: "quit Calculator", label: "quit Calculator → process gone",
                verify: { await !isRunning("com.apple.calculator") }),
        ]

        var failures: [String] = []
        for row in rows {
            let countBefore = runtime.tasks.count
            runtime.begin(app: nil)
            runtime.update(row.command, final: true)
            let deadline = Date().addingTimeInterval(90)
            let askedBefore = awaitingCount()
            while Date() < deadline {
                if runtime.tasks.count > countBefore,
                   let work = runtime.tasks.last, !work.active { break }
                if let work = runtime.tasks.last, work.approval != nil {
                    print("MATRIX approving:", work.approval ?? "")
                    runtime.resolveApproval(work.id, approved: true)
                }
                if awaitingCount() > askedBefore { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let work = runtime.tasks.count > countBefore ? runtime.tasks.last : nil
            // A task still working at the deadline keeps dispatching into the
            // next row's apps; stop it so its strays cannot contaminate.
            if let work, work.active { runtime.cancel(work.id) }
            let status = work?.status ?? (awaitingCount() > askedBefore ? "asked a question" : "no task created")
            let verified = (try? await row.verify()) ?? false
            let detail = work?.message ?? lastQuestion()
            if !(status == "Completed" && verified) {
                failures.append("\(row.label): status=\(status) verified=\(verified) msg=\(detail)")
            }
            print("MATRIX \(verified ? "✓" : "✗") \(row.command) → \(status); verified=\(verified); \(detail)")
        }

        await runtime.shutdown()
        let snapshot = toolCalls.snapshot()
        print("MATRIX tools:", snapshot.tools)
        _ = try? await observer.call("end_session", arguments: ["session": .string(observerSession)])
        await observer.close()
        if let priorPID, let prior = NSRunningApplication(processIdentifier: priorPID) {
            _ = prior.activate(options: [])
        }

        XCTAssertEqual(snapshot.tools["start_session"], 1,
            "Eleven commands must ride one driver session")
        XCTAssertEqual(snapshot.tools["set_agent_cursor_enabled"], 1,
            "The cursor policy is applied once per session")
        XCTAssertEqual(snapshot.tools["end_session"], 1,
            "The shared session ends exactly once at shutdown")
        XCTAssertTrue(failures.isEmpty, "Matrix failures:\n\(failures.joined(separator: "\n"))")
    }

    /// Real-person workflows: compound requests that open an app and then do
    /// work inside it — the way someone actually talks to their computer.
    /// Every row is verified by an independent read of the resulting app
    /// state (window titles, field values, process state), never by trusting
    /// a dispatch response. Rows report together so one failure cannot hide
    /// the rest.
    func testWorkflowMatrixOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_MATRIX_TEST"] == "1" else {
            throw XCTSkip("Opt-in real-person workflow matrix under the desktop lock")
        }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           (session["CGSSessionScreenIsLocked"] as? Bool) == true
           || ((session["IOConsoleUsers"] as? [[String: Any]]) ?? []).contains(where: { ($0["CGSSessionScreenIsLocked"] as? Bool) == true }) {
            throw XCTSkip("The screen is locked; desktop control cannot be exercised. Unlock and re-run.")
        }
        let key = try CuaLiveCredential.jev()
        let observer = try CuaLiveDriver.connection()
        try await observer.connect()
        let observerSession = "Jarvis workflow observer \(UUID().uuidString.prefix(8))"
        _ = try await observer.call("start_session", arguments: ["session": .string(observerSession)])

        let priorPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let model = JevClient(apiKey: key)
        let toolCalls = ToolCalls()
        let config = Config(defaults: UserDefaults(suiteName: "CuaVoiceWorkflowMatrix-\(UUID().uuidString)")!,
                            keyStore: FixtureKeyStore(key: key), environment: [:])
        let runtime = CuaVoiceRuntime(config: config,
            makeConnection: { CuaConnection(onToolCall: { tool, length in
                print("WORKFLOW driver call:", tool)
                toolCalls.record(tool, textLength: length)
            }) },
            judge: { state, questions in
                let answers = try await model.systemOne(state: state, questions: questions).response.answers
                for (key, answer) in answers {
                    guard case let .choice(choice, _, _) = answer,
                          case let .choice(_, criteria)? = questions[key] else { continue }
                    print("WORKFLOW Jev \(key):", criteria[choice].flatMap { $0 } ?? choice)
                }
                return answers
            })

        func frontmost(_ bundleID: String) async -> Bool {
            for _ in 0..<25 {
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
                try? await Task.sleep(for: .milliseconds(80))
            }
            return false
        }
        func windowTitles(_ bundleID: String) async -> [String] {
            // Every running instance — an isolated-profile browser is a second
            // process under the same bundle id, so .first can pick the wrong one.
            var titles: [String] = []
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                guard let listed = try? await observer.call("list_windows", arguments: [
                    "pid": .number(Double(running.processIdentifier)), "session": .string(observerSession)]) else { continue }
                titles += (listed["windows"]?.array ?? []).compactMap { $0["title"]?.string }
            }
            return titles
        }
        /// Every string-valued element across every on-screen window of every
        /// running instance — address bars, text areas, terminal buffers.
        func fieldTexts(_ bundleID: String) async -> [String] {
            var texts: [String] = []
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                guard let listed = try? await observer.call("list_windows", arguments: [
                    "pid": .number(Double(running.processIdentifier)), "session": .string(observerSession)]) else { continue }
                for window in (listed["windows"]?.array ?? []).filter({ $0["is_on_screen"] != .bool(false) }) {
                    guard let wid = window["window_id"]?.integer,
                          let state = try? await observer.call("get_window_state", arguments: [
                              "pid": .number(Double(running.processIdentifier)), "window_id": .number(Double(wid)),
                              "include_screenshot": .bool(false), "max_elements": .number(220),
                              "session": .string(observerSession)]) else { continue }
                    texts += (state["elements"]?.array ?? []).compactMap { $0["value"]?.string }
                }
            }
            return texts
        }
        func observed(_ bundleID: String, _ needle: String) async -> Bool {
            for _ in 0..<25 {
                if await windowTitles(bundleID).contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
                if await fieldTexts(bundleID).contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return false
        }
        /// OCR text of windows exposing no readable elements — a terminal's
        /// scrollback is pixels, not AX values, so semantic reads see nothing.
        /// Vision reads the same capture first; the driver's ONNX parse is the
        /// fallback when no text is found.
        func visualTexts(_ bundleID: String) async -> [String] {
            var texts: [String] = []
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                guard let listed = try? await observer.call("list_windows", arguments: [
                    "pid": .number(Double(running.processIdentifier)), "session": .string(observerSession)]) else { continue }
                for window in (listed["windows"]?.array ?? []).filter({ $0["is_on_screen"] != .bool(false) }) {
                    guard let wid = window["window_id"]?.integer else { continue }
                    let file = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("jarvis-test-capture-\(UUID().uuidString).png")
                    guard let capture = try? await observer.call("get_window_state", arguments: [
                        "pid": .number(Double(running.processIdentifier)), "window_id": .number(Double(wid)),
                        "include_screenshot": .bool(true), "include_accessibility_tree": .bool(false),
                        "screenshot_out_file": .string(file.path),
                        "session": .string(observerSession)]) else { continue }
                    defer { try? FileManager.default.removeItem(at: file) }
                    let regions = await Task.detached(priority: .utility) {
                        CuaVisionRegions.recognize(file: file,
                            width: capture["screenshot_width"]?.integer ?? 0,
                            height: capture["screenshot_height"]?.integer ?? 0)
                    }.value
                    if let regions, !regions.isEmpty {
                        texts += regions.compactMap { $0["text"]?.string }
                        continue
                    }
                    guard let captureID = capture["capture_id"]?.string,
                          let parsed = try? await observer.call("parse_visual_regions", arguments: [
                              "capture_id": .string(captureID), "session": .string(observerSession)]) else { continue }
                    texts += (parsed["regions"]?.array ?? []).compactMap { $0["text"]?.string ?? $0["label"]?.string }
                }
            }
            return texts
        }
        /// A terminal-style run is proven by output, not by the command line —
        /// the typed command itself carries the token. Executed output appears
        /// as a bare-token line (or a second occurrence) that a mistyped
        /// command's error output does not produce.
        func ranAndShowed(_ bundleID: String, _ token: String) async -> Bool {
            for _ in 0..<30 {
                let texts = await fieldTexts(bundleID) + visualTexts(bundleID)
                // A "command not found" line also carries the token but proves
                // the run FAILED — exclude errors before counting.
                let hits = texts.filter { $0.localizedCaseInsensitiveContains(token) }
                    .filter { !$0.localizedCaseInsensitiveContains("not found") }
                if hits.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveCompare(token) == .orderedSame })
                    || hits.count >= 2 { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        func awaitingCount() -> Int {
            runtime.dialogue.entries.filter {
                if case .awaitingAnswer = $0.status { return true }
                return false
            }.count
        }
        func lastQuestion() -> String {
            runtime.dialogue.entries.last {
                if case .awaitingAnswer = $0.status { return true }
                return false
            }?.question?.prompt ?? ""
        }

        /// Only window *titles* prove a navigation happened — an omnibox field
        /// value echoing the typed text does not.
        func titled(_ bundleID: String, _ needle: String) async -> Bool {
            for _ in 0..<30 {
                if await windowTitles(bundleID).contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }

        struct Row {
            let command: String
            let label: String
            let verify: () async throws -> Bool
        }
        // A fresh token each run keeps earlier scrollback from satisfying the
        // check, and plain words survive OCR — digits and hyphens fragment.
        let wordBank = ["mango", "orchid", "thunder", "harbor", "cobalt",
                        "willow", "ember", "prism", "falcon", "maple",
                        "juniper", "saffron", "beacon", "copper", "drift"]
        let terminalToken = (0..<3).compactMap { _ in wordBank.randomElement() }.joined(separator: " ")
        // Same for document bodies — a leftover doc/note from an earlier run
        // must not satisfy a create/write request it never produced.
        let textEditToken = (0..<3).compactMap { _ in wordBank.randomElement() }.joined(separator: " ")
        let notesToken = (0..<3).compactMap { _ in wordBank.randomElement() }.joined(separator: " ")
        let rows: [Row] = [
            // The reported failing command — verbatim.
            Row(command: "open google and search for the weather today in yuba city",
                label: "google search → results page title",
                verify: { await frontmost("com.google.Chrome") ? await titled("com.google.Chrome", "yuba") : false }),
            Row(command: "open TextEdit and create a new document then type \(textEditToken)",
                label: "TextEdit new doc + type → text in document",
                verify: { await frontmost("com.apple.TextEdit") ? await observed("com.apple.TextEdit", textEditToken) : false }),
            Row(command: "open Notes and write a note that says \(notesToken)",
                label: "Notes write → text in note body",
                verify: { await frontmost("com.apple.Notes") ? await observed("com.apple.Notes", notesToken) : false }),
            Row(command: "open Terminal and run echo \(terminalToken)",
                label: "Terminal run → command output visible",
                verify: { await frontmost("com.apple.Terminal") ? await ranAndShowed("com.apple.Terminal", terminalToken) : false }),
            Row(command: "open a new tab in Chrome and go to apple.com",
                label: "new tab + navigate → Apple page title",
                verify: { await titled("com.google.Chrome", "apple") }),
        ]

        var failures: [String] = []
        for row in rows {
            let countBefore = runtime.tasks.count
            runtime.begin(app: nil)
            runtime.update(row.command, final: true)
            let deadline = Date().addingTimeInterval(120)
            let askedBefore = awaitingCount()
            while Date() < deadline {
                if runtime.tasks.count > countBefore,
                   let work = runtime.tasks.last, !work.active { break }
                if let work = runtime.tasks.last, work.approval != nil {
                    print("WORKFLOW approving:", work.approval ?? "")
                    runtime.resolveApproval(work.id, approved: true)
                }
                if awaitingCount() > askedBefore { break }
                try await Task.sleep(for: .milliseconds(120))
            }
            let work = runtime.tasks.count > countBefore ? runtime.tasks.last : nil
            // A task still working at the deadline keeps dispatching into the
            // next row's apps; stop it so its strays cannot contaminate.
            if let work, work.active { runtime.cancel(work.id) }
            let status = work?.status ?? (awaitingCount() > askedBefore ? "asked a question" : "no task created")
            let verified = (try? await row.verify()) ?? false
            let detail = work?.message ?? lastQuestion()
            if !(status == "Completed" && verified) {
                failures.append("\(row.label): status=\(status) verified=\(verified) msg=\(detail)")
            }
            print("WORKFLOW \(verified ? "✓" : "✗") \(row.command) → \(status); verified=\(verified); \(detail)")
        }

        await runtime.shutdown()
        let snapshot = toolCalls.snapshot()
        print("WORKFLOW tools:", snapshot.tools)
        _ = try? await observer.call("end_session", arguments: ["session": .string(observerSession)])
        await observer.close()
        if let priorPID, let prior = NSRunningApplication(processIdentifier: priorPID) {
            _ = prior.activate(options: [])
        }

        XCTAssertEqual(snapshot.tools["start_session"], 1,
            "All workflows ride one driver session")
        XCTAssertEqual(snapshot.tools["end_session"], 1,
            "The shared session ends exactly once at shutdown")
        XCTAssertTrue(failures.isEmpty, "Workflow failures:\n\(failures.joined(separator: "\n"))")
    }
}
