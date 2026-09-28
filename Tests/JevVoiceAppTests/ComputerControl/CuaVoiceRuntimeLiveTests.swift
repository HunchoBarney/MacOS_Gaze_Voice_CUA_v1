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
                let keyAgent = CuaTaskAgent(call: { tool, arguments in
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
                }, windowID: windowID, actionSurface: .candidate)
                do {
                    _ = try await keyAgent.run(goal: "In the foreground, press the key \"return\" in the text area of \(displayName), window \(windowTitle).",
                                               context: "One disposable native text fixture with an exact, observed window.",
                                               progress: { _ in })
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
                    XCTAssertTrue(keyFailure.contains("did not produce exactly one newline"), keyFailure)
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
}
