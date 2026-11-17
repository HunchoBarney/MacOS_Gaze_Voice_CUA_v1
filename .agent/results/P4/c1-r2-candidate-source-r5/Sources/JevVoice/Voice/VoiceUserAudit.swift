import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

/// Scripted typed commands through the installed normal controller and real
/// desktop. This is neither hardware Fn nor microphone evidence.
@MainActor
enum VoiceUserAudit {
    nonisolated static func isNetworkFreeTrace(environment: [String: String], arguments: [String]) -> Bool {
        environment["JARVIS_P3_GUI_AUDIT"] == "1" && arguments.contains("--p3-user-audit")
            && (environment["JARVIS_P3_GUI_AUDIT_TRACE_ONLY"] == "1"
                || environment["JARVIS_P3_GUI_AUDIT_TYPING_ONLY"] == "1"
                || environment["JARVIS_P3_GUI_AUDIT_BROWSER_TYPING_ONLY"] == "1")
    }
    static let networkFreeTrace = isNetworkFreeTrace(environment: ProcessInfo.processInfo.environment,
                                                     arguments: ProcessInfo.processInfo.arguments)
    private struct UnavailableCredentials: APIKeyStore {
        private enum Unavailable: Error { case diagnosticNetworkDisabled }
        func read() throws -> String? { throw Unavailable.diagnosticNetworkDisabled }
        func save(_ apiKey: String) throws { throw Unavailable.diagnosticNetworkDisabled }
        func delete() throws { throw Unavailable.diagnosticNetworkDisabled }
    }

    static func diagnosticConfiguration(defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        store: (String, Bool) -> APIKeyStore = { KeychainAPIKeyStore(account: $0, allowUserInteraction: $1) }) -> Config {
        if isNetworkFreeTrace(environment: environment, arguments: arguments) {
            var localEnvironment = environment
            localEnvironment.removeValue(forKey: "TYPESAFE_API_KEY")
            localEnvironment.removeValue(forKey: "OPENAI_API_KEY")
            return Config(defaults: defaults, keyStore: UnavailableCredentials(),
                          openAIKeyStore: UnavailableCredentials(), environment: localEnvironment,
                          codexAuth: CodexAuth(binary: nil))
        }
        return Config(defaults: defaults, keyStore: store("typesafeAPIKey", false),
                      openAIKeyStore: store("openAIAPIKey", false), environment: environment)
    }

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["JARVIS_P3_GUI_AUDIT"] == "1"
            && ProcessInfo.processInfo.arguments.contains("--p3-user-audit")
            && validRunID(ProcessInfo.processInfo.environment["JARVIS_P3_GUI_AUDIT_RUN_ID"] ?? "")
    }
    static func nativeWindowWitness(stage: VoiceCommandTrace.Stage, rows: [[String: Any]],
                                    frontmostPID: Int?, at: TimeInterval) -> [String: Any]? {
        guard stage == .nativeForegroundReadBegin || stage == .nativeForegroundReadEnd else { return nil }
        let metadata = rows.filter {
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }.map { row -> [String: Any] in
            var result: [String: Any] = [:]
            for key in [kCGWindowOwnerPID, kCGWindowNumber, kCGWindowAlpha, kCGWindowIsOnscreen] {
                if let value = row[key as String] as? NSNumber { result[key as String] = value }
            }
            if let bounds = row[kCGWindowBounds as String] as? [String: Any] {
                var geometry: [String: Double] = [:]
                for key in ["X", "Y", "Width", "Height"] {
                    if let value = bounds[key] as? NSNumber, value.doubleValue.isFinite {
                        geometry[key] = value.doubleValue
                    }
                }
                result[kCGWindowBounds as String] = geometry
            }
            return result
        }
        return ["stage": stage.rawValue, "monotonic": at,
                "frontmost_pid": frontmostPID ?? 0, "normal_window_metadata": metadata]
    }

    private static func validRunID(_ value: String) -> Bool {
        value.utf8.count <= 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    private enum Failure: Error { case timeout, unavailable, wrongDocument }
    private static let calculator = "com.apple.calculator"
    private static let textEdit = "com.apple.TextEdit"
    private static var task: Task<Void, Never>?
    private static var initialWorkIDs: Set<UUID> = []
    private static var submitted = false
    private static var submittedAt: TimeInterval?
    private static var focusDiagnostics: [String: Any] = [:]
    private static var trackerStartupWaitMS = 0.0
    private static var trackerStartupState = "not_checked"

    static func start(controller: VoiceController) {
        guard enabled, task == nil else { return }
        let observer = controller.cua.onCommandStage
        controller.cua.onCommandStage = { turn, work, stage, tool in
            observer?(turn, work, stage, tool)
            guard stage == .nativeForegroundReadBegin || stage == .nativeForegroundReadEnd else { return }
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] ?? []
            if var witness = nativeWindowWitness(stage: stage, rows: windows,
                frontmostPID: NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) },
                at: ProcessInfo.processInfo.systemUptime) {
                witness["turn"] = turn?.uuidString
                witness["task"] = work?.uuidString
                var observations = focusDiagnostics["native_window_witness"] as? [[String: Any]] ?? []
                observations.append(witness)
                focusDiagnostics["native_window_witness"] = observations
            }
        }
        task = Task {
            do { try await run(controller) }
            catch {
                let failureTrace = submittedAt.map { controller.commandTrace.snapshot(since: $0) } ?? []
                let failureWorks = controller.cuaTasks.filter {
                    !initialWorkIDs.contains($0.id) && $0.captureID != nil && !$0.isAgentAsk
                }.sorted { $0.lastActivity > $1.lastActivity }.prefix(16).map {
                    ["id": $0.id.uuidString, "active": $0.active,
                     "outcome": outcomeCode($0.outcome), "awaiting_answer": $0.awaitingAnswer,
                     "awaiting_approval": $0.awaitingApproval,
                     "application_matches_fixture": $0.spec.application == "com.apple.TextEdit",
                     "application_missing": $0.spec.application == nil,
                     "pinned_window_present": $0.spec.windowID != nil] as [String: Any]
                }
                controller.semanticAuditSubject = nil
                if submitted { controller.cancelCaptureAttempt() }
                let owned = controller.cuaTasks.filter {
                    !initialWorkIDs.contains($0.id) && $0.captureID != nil && !$0.isAgentAsk
                }
                for work in owned where work.active { controller.cancelTask(work.id) }
                var settled = false
                do {
                    try await wait(5) { owned.allSatisfy { !$0.active } && controller.canSubmitCommand }
                    settled = true
                } catch {}
                controller.auditDocumentBinding = nil
                let root = results()
                let url = root.appendingPathComponent("result.json")
                var report = (try? Data(contentsOf: url)).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? [:]
                report["status"] = "blocked_or_failed"; report["reason"] = String(describing: error)
                report["human_confirmed"] = false; report["physical_input"] = false
                report["audit_owned_tasks_cancelled"] = owned.allSatisfy { !$0.active }
                report["focus_diagnostics"] = focusDiagnostics
                report["last_submit_trace"] = failureTrace
                report["works_before_cleanup"] = failureWorks
                report["accessibility_trusted"] = AXIsProcessTrusted()
                report["desktop_ownership_release_safe"] = settled
                report["driver_inventory_prewarm"] = controller.cua.inventoryWarmupMetrics
                if !settled { report["status"] = "blocked_cleanup_ownership_retained" }
                try? save(report, url)
            }
        }
    }

    private static func results() -> URL {
        let requested = ProcessInfo.processInfo.environment["JARVIS_P3_GUI_AUDIT_RUN_ID"] ?? ""
        let valid = !requested.isEmpty && validRunID(requested)
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agent/results/P3/user-audit" + (valid ? "-\(requested)" : ""))
    }

    static func save(_ row: [String: Any], _ url: URL, diagnostics: [String: Any]? = nil) throws {
        var report = row
        report["focus_diagnostics"] = diagnostics ?? focusDiagnostics
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: url, options: .atomic)
    }

    private static func outcomeCode(_ outcome: VoiceTaskCoordinator.Work.Outcome?) -> String {
        switch outcome {
        case .done: return "done"
        case .alreadyDone: return "alreadyDone"
        case .blocked: return "blocked"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .uncertain: return "uncertain"
        case nil: return "pending"
        }
    }

    private static func statusCode(_ status: VoiceController.Status) -> String {
        switch status {
        case .error: return "error"
        case .awaitingAnswer: return "awaitingAnswer"
        default: return status.title
        }
    }

    private static func wait(_ seconds: Double = 15, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func awaitTrackerStartup(_ controller: VoiceController) async throws {
        guard controller.config.gazeTracking else { trackerStartupState = "disabled"; return }
        let start = ProcessInfo.processInfo.systemUptime
        defer { trackerStartupWaitMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        while true {
            try Task.checkCancellation()
            switch await TrackerHost.shared.state {
            case .running:
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(TrackerHost.port)/snapshot")!)
                request.timeoutInterval = 2
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let runtime = payload["runtime"] as? [String: Any],
                   let name = runtime["name"] as? String, !name.isEmpty {
                    trackerStartupState = "renderer_started"
                    return
                }
            case .failed: throw Failure.unavailable
            case .stopped, .starting: break
            }
            guard ProcessInfo.processInfo.systemUptime - start < 60 else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func auditWorkSucceeded(_ states: [(active: Bool, outcome: String,
                                              awaitingAnswer: Bool, awaitingApproval: Bool)]) -> Bool {
        guard states.count == 1, let state = states.first else { return false }
        return !state.active && state.outcome == "done" && !state.awaitingAnswer && !state.awaitingApproval
    }

    private static func settleSubmittedWork(_ controller: VoiceController, previous: Set<UUID>,
                                            started: TimeInterval) async throws {
        let remaining = 15 - (ProcessInfo.processInfo.systemUptime - started)
        guard remaining > 0 else { throw Failure.timeout }
        try await wait(remaining) {
            let fresh = controller.cuaTasks.filter { !previous.contains($0.id) }
            return !fresh.isEmpty && fresh.allSatisfy { !$0.active }
        }
        let states = controller.cuaTasks.filter { !previous.contains($0.id) }.map {
            (active: $0.active, outcome: outcomeCode($0.outcome),
             awaitingAnswer: $0.awaitingAnswer, awaitingApproval: $0.awaitingApproval)
        }
        guard auditWorkSucceeded(states) else { throw Failure.unavailable }
    }

    private struct BrowserFixtureState {
        let windowID: Int
        let primaryValue: String?
        let decoyValue: String?
        let echo: String?
        let primaryFocused: Bool
    }

    private static func browserFixtureState(file: URL) -> BrowserFixtureState? {
        guard let windowID = foreground("com.google.Chrome"),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let rawWindow = attribute(root, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = rawWindow as! AXUIElement
        guard (attribute(window, kAXTitleAttribute as CFString) as? String)?
            .contains("P3 Owned Field Probe C03") == true else { return nil }
        var queue = [window], visited = 0, ownedPage = false
        var primary: AXUIElement?, primaryValue: String?, decoyValue: String?, echo: String?
        while !queue.isEmpty, visited < 650 {
            let element = queue.removeFirst(); visited += 1
            let role = attribute(element, kAXRoleAttribute as CFString) as? String
            if role == "AXWebArea", let rawURL = attribute(element, "AXURL" as CFString) {
                let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
                if url?.standardizedFileURL == file.standardizedFileURL { ownedPage = true }
            }
            if role == "AXTextField" {
                let label = (attribute(element, kAXTitleAttribute as CFString) as? String)
                    ?? (attribute(element, kAXDescriptionAttribute as CFString) as? String) ?? ""
                if label == "P3 C03 primary field" {
                    primary = element
                    primaryValue = attribute(element, kAXValueAttribute as CFString) as? String
                } else if label == "P3 C03 decoy field" {
                    decoyValue = attribute(element, kAXValueAttribute as CFString) as? String
                }
            } else if role == "AXStaticText",
                      let value = attribute(element, kAXValueAttribute as CFString) as? String,
                      value.hasPrefix("P3 C03 echo:") { echo = value }
            queue += attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        }
        guard ownedPage, let primary, decoyValue != nil,
              let rawFocus = attribute(root, kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(rawFocus) == AXUIElementGetTypeID() else { return nil }
        return BrowserFixtureState(windowID: windowID, primaryValue: primaryValue,
                                   decoyValue: decoyValue, echo: echo,
                                   primaryFocused: CFEqual(rawFocus, primary))
    }

    private static func runOwnedBrowserTyping(_ controller: VoiceController, directory: URL) async throws {
        let fixture = directory.deletingLastPathComponent()
            .appendingPathComponent("closeout03/field-fixture.html")
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              FileManager.default.fileExists(atPath: fixture.path),
              controller.auditDocumentBinding == nil else { throw Failure.unavailable }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([fixture], withApplicationAt: chrome, configuration: config) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try await wait {
            guard let state = browserFixtureState(file: fixture) else { return false }
            return state.primaryFocused && state.primaryValue == ""
                && state.decoyValue == "P3 C03 untouched" && controller.canSubmitCommand
        }
        guard let before = browserFixtureState(file: fixture) else { throw Failure.wrongDocument }
        let payload = "P3 focused literal"
        let previous = Set(controller.cuaTasks.map(\.id))
        let start = ProcessInfo.processInfo.systemUptime
        submit("type \"\(payload)\"", to: controller)
        try await wait(15) {
            let fresh = controller.cuaTasks.filter { !previous.contains($0.id) }
            guard fresh.count == 1, fresh.allSatisfy({ !$0.active }),
                  let state = browserFixtureState(file: fixture) else { return false }
            return state.windowID == before.windowID && state.primaryValue == payload
                && state.decoyValue == "P3 C03 untouched"
                && state.echo == "P3 C03 echo: " + payload
        }
        let fresh = controller.cuaTasks.filter { !previous.contains($0.id) }
        guard let work = fresh.first else { throw Failure.unavailable }
        let mutations = controller.commandTrace.events.filter {
            $0.monotonic >= start && $0.stage == .driverBegin && $0.tool == .typeText
        }.count
        let pass = fresh.count == 1 && mutations == 1 && !work.awaitingApproval && !work.awaitingAnswer
            && work.spec.windowID == before.windowID && work.spec.application == "com.google.Chrome"
            && work.outcome != .done && !work.dispatchedEffect
        try save([
            "status": pass ? "passed" : "blocked_or_failed",
            "physical_input": false, "human_confirmed": false,
            "desktop_ownership_release_safe": fresh.allSatisfy { !$0.active },
            "rows": [["case": "owned_browser_focused_literal", "passed": pass,
                      "renderer_input_echo_verified": true, "primary_value_verified": true,
                      "decoy_unchanged": true, "work_count": fresh.count, "mutation_count": mutations,
                      "captured_window_preserved": work.spec.windowID == before.windowID,
                      "outcome": outcomeCode(work.outcome), "false_done": work.outcome == .done,
                      "verification_limited": true]],
            "trace": controller.commandTrace.snapshot(since: start)
        ], directory.appendingPathComponent("result.json"))
        guard pass else { throw Failure.unavailable }
    }

    private static func activate(_ bundle: String, file: URL? = nil) async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw Failure.unavailable }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            if let file {
                NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config, completionHandler: completion)
            } else {
                NSWorkspace.shared.openApplication(at: app, configuration: config, completionHandler: completion)
            }
        }
        try await wait {
            guard let window = foreground(bundle) else { return false }
            if let file { return focusedOwnedDocument(file, windowID: window) }
            return true
        }
    }

    private static func foreground(_ bundle: String) -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundle,
              let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]],
              let row = rows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
                      && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                      && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
              }) else { return nil }
        return (row[kCGWindowNumber as String] as? NSNumber)?.intValue
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        guard status == .success else {
            focusDiagnostics["last_ax_error"] = status.rawValue
            return nil
        }
        return value
    }

    private static func ownedTextArea(_ file: URL, requireFocused: Bool = true) -> AXUIElement? {
        focusDiagnostics = ["stage": "frontmost", "accessibility_trusted": AXIsProcessTrusted()]
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == textEdit else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        focusDiagnostics["stage"] = "focused_window"
        guard let rawWindow = attribute(root, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        let rawDocument = attribute(window, kAXDocumentAttribute as CFString)
        let document = (rawDocument as? URL) ?? (rawDocument as? String).flatMap(URL.init(string:))
        focusDiagnostics["stage"] = "document_identity"
        focusDiagnostics["has_document"] = rawDocument != nil
        focusDiagnostics["document_matches"] = document?.standardizedFileURL == file.standardizedFileURL
        guard document?.standardizedFileURL == file.standardizedFileURL else { return nil }
        var queue = [window], count = 0
        while !queue.isEmpty, count < 200 {
            let element = queue.removeFirst(); count += 1
            if attribute(element, kAXRoleAttribute as CFString) as? String == kAXTextAreaRole {
                focusDiagnostics["stage"] = "focused_editable"
                if requireFocused {
                    guard let focused = attribute(root, kAXFocusedUIElementAttribute as CFString),
                          CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
                    let editable = unsafeBitCast(focused, to: AXUIElement.self)
                    focusDiagnostics["focused_role"] = attribute(editable, kAXRoleAttribute as CFString) as? String ?? ""
                    focusDiagnostics["focused_element_matches"] = CFEqual(focused, element)
                    guard CFEqual(focused, element) else { return nil }
                }
                focusDiagnostics["stage"] = "matched"
                return element
            }
            queue += attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        }
        return nil
    }

    static func focusedOwnedDocument(_ file: URL, windowID: Int) -> Bool {
        foreground(textEdit) == windowID && ownedTextArea(file) != nil
    }

    private static func submit(_ command: String, to controller: VoiceController) {
        submitted = true
        submittedAt = ProcessInfo.processInfo.systemUptime
        controller.submitTypedCommand(command)
    }

    private static func runTypingRepair(_ controller: VoiceController, fixture: URL,
                                         decoy: URL, directory: URL) async throws {
        guard controller.auditDocumentBinding == nil else { throw Failure.wrongDocument }
        try await activate(textEdit, file: decoy)
        guard let decoyArea = ownedTextArea(decoy),
              let decoyBefore = attribute(decoyArea, kAXValueAttribute as CFString) as? String else {
            throw Failure.wrongDocument
        }
        try await activate(textEdit, file: fixture)
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == textEdit,
              let window = FocusedTextBinding.capturedWindowID(pid: Int(app.processIdentifier)),
              let area = ownedTextArea(fixture),
              let before = attribute(area, kAXValueAttribute as CFString) as? String,
              let raw = attribute(area, kAXSelectedTextRangeAttribute as CFString),
              CFGetTypeID(raw) == AXValueGetTypeID() else { throw Failure.wrongDocument }
        var selection = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0,
              selection.location <= before.utf16.count,
              selection.length <= before.utf16.count - selection.location else { throw Failure.wrongDocument }
        let literal = "hello Jarvis"
        let expected = (before as NSString).replacingCharacters(
            in: NSRange(location: selection.location, length: selection.length), with: literal)
        try save(["cg_front_window": foreground(textEdit).map { $0 as Any } ?? NSNull(),
                  "native_focused_window": window],
                 directory.appendingPathComponent("window-preflight.json"))
        try await wait { controller.canSubmitCommand }
        let previous = Set(controller.cuaTasks.map(\.id))
        let start = ProcessInfo.processInfo.systemUptime
        submit("type hello Jarvis", to: controller)
        var settled = false
        do {
            try await settleSubmittedWork(controller, previous: previous, started: start)
            settled = true
        } catch {}
        let works = controller.cuaTasks.filter { !previous.contains($0.id) }
        let after = attribute(area, kAXValueAttribute as CFString) as? String
        let decoyAfter = attribute(decoyArea, kAXValueAttribute as CFString) as? String
        let trace = controller.commandTrace.snapshot(since: start)
        let types = trace.filter {
            ($0["stage"] as? String == "driverBegin" && $0["tool"] as? String == "typeText")
                || $0["stage"] as? String == "nativeTextInsertionBegin"
        }.count
        let bindingMatches = works.count == 1 && works[0].spec.application == textEdit
            && works[0].spec.windowID == window && works[0].spec.values["text"] == literal
        let noRounds = works.allSatisfy { !$0.history.contains(where: { $0.hasPrefix("round ") }) }
        let pass = settled && bindingMatches && noRounds && types == 1
            && after == expected && decoyAfter == decoyBefore && controller.auditDocumentBinding == nil
        try save([
            "status": pass ? "passed" : "failed", "physical_input": false,
            "human_confirmed": false, "normal_controller_no_audit_binding": true,
            "captured_binding_matches": bindingMatches, "exact_insertion": after == expected,
            "observed_window": window,
            "task_window": works.first?.spec.windowID.map { $0 as Any } ?? NSNull(),
            "task_literal_matches": works.first?.spec.values["text"] == literal,
            "decoy_unchanged": decoyAfter == decoyBefore, "type_dispatches": types,
            "no_model_rounds": noRounds, "work_count": works.count,
            "outcomes": works.map { outcomeCode($0.outcome) },
            "typing_proof": works.flatMap(\.history).filter {
                $0.hasPrefix("Focused typing proof:") || $0.hasPrefix("Native focused typing proof:")
            },
            "tracker_startup_state": trackerStartupState,
            "tracker_startup_wait_ms": trackerStartupWaitMS,
            "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
            "executable_sha256": SemanticRequestBudget.digest(
                try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "trace": trace, "desktop_ownership_release_safe": works.allSatisfy { !$0.active },
            "driver_inventory_prewarm": controller.cua.inventoryWarmupMetrics
        ], directory.appendingPathComponent("result.json"))
        guard pass else { throw Failure.unavailable }
    }

    private static func run(_ controller: VoiceController) async throws {
        let directory = results()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard controller.config.autoExecute else { throw Failure.unavailable }
        let marker = directory.appendingPathComponent("started.json")
        let fd = Darwin.open(marker.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unavailable }
        let markerFile = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let executable = Bundle.main.executableURL else { throw Failure.unavailable }
        try markerFile.write(contentsOf: JSONSerialization.data(withJSONObject: [
                  "artifact_sha256": SemanticRequestBudget.digest(Data(contentsOf: executable)),
                  "mode": "scripted-normal-controller", "physical_input": false,
                  "human_confirmed": false], options: [.sortedKeys]))
        try markerFile.synchronize(); try markerFile.close()
        initialWorkIDs = Set(controller.cuaTasks.map(\.id))
        try await awaitTrackerStartup(controller)
        if ProcessInfo.processInfo.environment["JARVIS_P3_GUI_AUDIT_BROWSER_TYPING_ONLY"] == "1" {
            try await runOwnedBrowserTyping(controller, directory: directory)
            return
        }
        let typingOnly = ProcessInfo.processInfo.environment["JARVIS_P3_GUI_AUDIT_TYPING_ONLY"] == "1"
        let shortcutsOnly = ProcessInfo.processInfo.environment["JARVIS_P3_GUI_AUDIT_SHORTCUTS_ONLY"] == "1"
        let routingOnly = ProcessInfo.processInfo.environment["JARVIS_P3_GUI_AUDIT_ROUTING_ONLY"] == "1"
        let traceOnly = networkFreeTrace && !typingOnly
        guard !routingOnly || (!typingOnly && !shortcutsOnly && !traceOnly) else { throw Failure.unavailable }
        if !networkFreeTrace {
            let batch = ProcessInfo.processInfo.environment["JARVIS_P3_SEMANTIC_BATCH"] ?? "semantic-live"
            guard batch.hasPrefix("semantic-"), validRunID(batch) else { throw Failure.unavailable }
            let budgetDirectory = directory.deletingLastPathComponent().appendingPathComponent(batch)
            let auth = try JSONDecoder().decode(SemanticRequestBudget.Authorization.self,
                from: Data(contentsOf: budgetDirectory.appendingPathComponent("authorization.json")))
            let corpusSHA = routingOnly ? try VoiceTrialReport.routingCorpusSHA() : auth.corpusSHA256
            guard !routingOnly || auth.maximumRequests == 1 else { throw Failure.unavailable }
            controller.semanticAuditBudget = try SemanticRequestBudget(directory: budgetDirectory, corpusSHA256: corpusSHA)
        }
        let fixture = directory.appendingPathComponent("owned-\(UUID().uuidString).txt")
        try "Jev owned fixture\n".write(to: fixture, atomically: true, encoding: .utf8)
        var rows: [[String: Any]] = []
        let decoy = directory.appendingPathComponent("owned-decoy-\(UUID().uuidString).txt")
        try "Jev owned decoy\n".write(to: decoy, atomically: true, encoding: .utf8)
        if typingOnly, ProcessInfo.processInfo.environment["JARVIS_P3_GUI_AUDIT_TYPING_REPAIR"] == "1" {
            try await runTypingRepair(controller, fixture: fixture, decoy: decoy, directory: directory)
            return
        }
        var commands: [(String, String, Bool)] = [
            ("open Calculator", calculator, false), ("show TextEdit", textEdit, false),
            ("bring Calculator to the front", calculator, false), ("switch to TextEdit", textEdit, false),
            ("focus Calculator", calculator, false), ("show TextEdit", textEdit, false),
            ("launch Calculator", calculator, false), ("bring TextEdit to the front", textEdit, false),
            ("open Calculator", calculator, false), ("switch back to TextEdit", textEdit, false),
            ("I need Calculator over here", calculator, true), ("I want TextEdit up here", textEdit, true),
            ("Put Calculator ahead of my windows", calculator, true),
            ("I need the TextEdit app on screen", textEdit, true),
            ("I'd like Calculator in the foreground", calculator, true)
        ]
        if routingOnly {
            commands = VoiceTrialReport.routingCases.map { ($0.command, $0.target, $0.semantic) }
        } else if shortcutsOnly {
            let apps = VoiceAdmissionContext.observedAppEntities()
            let roles = VoiceAdmissionContext.observedAppRoles()
            guard let browser = roles["https"],
                  ["com.google.Chrome", calculator, textEdit, browser].allSatisfy({ id in
                      apps.contains { $0.id == id && $0.canOpenLocally }
                  }) else { throw Failure.unavailable }
            commands = [
                ("Google", "com.google.Chrome", true), ("open my browser", browser, true),
                ("open calc", calculator, true), ("show Apple's plain-text editor", textEdit, true),
                ("show Google", "com.google.Chrome", true)
            ]
        }
        for (index, entry) in commands.prefix(typingOnly ? 0 : (traceOnly ? 1 : commands.count)).enumerated() {
            let (command, target, semantic) = entry
            let baseline = target == calculator ? textEdit : calculator
            try await activate(baseline, file: baseline == textEdit ? fixture : nil)
            try await wait { controller.canSubmitCommand }
            let existing = Set(controller.cuaTasks.map(\.id))
            controller.semanticAuditSubject = semantic ? "gui-\(index)" : nil
            let start = ProcessInfo.processInfo.systemUptime
            submit(command, to: controller)
            var effect: Double?, observedWindow: Int?, confirmation = false, wrongProposal = false
            let deadline = start + 20
            while ProcessInfo.processInfo.systemUptime < deadline {
                if effect == nil, let window = foreground(target) {
                    effect = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    observedWindow = window
                }
                let works = controller.cuaTasks.filter { !existing.contains($0.id) }
                if let ask = works.first(where: \.awaitingApproval), !confirmation {
                    confirmation = true
                    wrongProposal = ask.semanticFocus.map { $0.target.id != target } ?? true
                    break
                }
                if !works.isEmpty, works.allSatisfy({ !$0.active }) {
                    let succeeded = works.contains { $0.outcome == .done || $0.outcome == .alreadyDone }
                    if !succeeded || effect != nil { break }
                }
                if case .error = controller.status { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let works = controller.cuaTasks.filter { !existing.contains($0.id) }
            let done = works.contains { $0.outcome == .done || $0.outcome == .alreadyDone }
            let trace = controller.commandTrace.snapshot(since: start)
            let semanticWork = works.count == 1 && works[0].semanticFocus != nil
            let localObserved = trace.contains { $0["stage"] as? String == "admissionLocal" }
            let normalRoute = semanticWork ? "semantic" : (localObserved ? "local" : "unobserved")
            let laneMatches = !routingOnly || normalRoute == (semantic ? "semantic" : "local")
            let identityMatches = works.count == 1 && works[0].spec.application == target
                && works[0].captureID.map { capture in trace.contains { $0["turn"] as? String == capture.uuidString } } == true
            let pass = effect != nil && done && works.count == 1 && !wrongProposal && !confirmation
                && laneMatches && (!routingOnly || identityMatches)
            rows.append(["case": index, "command": command, "passed": pass,
                         "submit_to_visible_effect_ms": effect as Any? ?? NSNull(),
                         "observed_bundle_id": target, "observed_window_id": observedWindow as Any? ?? NSNull(),
                         "scripted_confirmation": confirmation, "wrong_proposal": wrongProposal,
                         "controller_status": statusCode(controller.status),
                         "controller_detail_sha256": SemanticRequestBudget.digest(Data(controller.detail.utf8)),
                         "controller_detail_bytes": controller.detail.utf8.count,
                         "work_count": works.count,
                         "normal_route": normalRoute,
                         "semantic_focus": semanticWork,
                         "works": works.map { ["id": $0.id.uuidString, "active": $0.active,
                             "outcome": outcomeCode($0.outcome), "history_count": $0.history.count,
                             "application": $0.spec.application as Any? ?? NSNull(),
                             "capture_id": $0.captureID?.uuidString as Any? ?? NSNull()] as [String: Any] },
                         "trace": trace,
                         "trace_dropped": controller.commandTrace.dropped,
                         "false_done": done && effect == nil])
            var running: [String: Any] = ["status": "running", "rows": rows, "physical_input": false]
            if routingOnly {
                running.merge(try VoiceTrialReport.normalRoutingCoverage(rows: rows,
                    artifactSHA: SemanticRequestBudget.digest(Data(contentsOf: executable)))) { _, value in value }
            }
            try save(running, directory.appendingPathComponent("result.json"))
            controller.semanticAuditSubject = nil
            guard pass else { throw Failure.unavailable }
        }
        if traceOnly || shortcutsOnly || routingOnly {
            var report: [String: Any] = ["status": shortcutsOnly || routingOnly ? "passed" : "reproduction_observed",
                      "rows": rows, "human_confirmed": false,
                      "tracker_startup_wait_ms": trackerStartupWaitMS,
                      "tracker_startup_state": trackerStartupState,
                      "physical_input": false, "desktop_ownership_release_safe": true]
            if routingOnly {
                report.merge(try VoiceTrialReport.normalRoutingCoverage(rows: rows,
                    artifactSHA: SemanticRequestBudget.digest(Data(contentsOf: executable)))) { _, value in value }
                report["semantic_budget"] = ProcessInfo.processInfo.environment["JARVIS_P3_SEMANTIC_BATCH"] ?? "semantic-live"
                guard report["normal_typed_routing_gate"] as? String == "passed" else { throw Failure.unavailable }
            }
            report["driver_inventory_prewarm"] = controller.cua.inventoryWarmupMetrics
            try save(report, directory.appendingPathComponent("result.json"))
            return
        }
        try await activate(textEdit, file: fixture)
        try await wait { ownedTextArea(fixture, requireFocused: false) != nil }
        guard let fixtureWindow = foreground(textEdit) else { throw Failure.wrongDocument }
        try await activate(textEdit, file: decoy)
        try await wait { ownedTextArea(decoy) != nil }
        guard let decoyWindow = foreground(textEdit),
              !focusedOwnedDocument(fixture, windowID: decoyWindow),
              let decoyArea = ownedTextArea(decoy),
              let decoyBefore = attribute(decoyArea, kAXValueAttribute as CFString) as? String else {
            throw Failure.wrongDocument
        }
        controller.auditDocumentBinding = (fixture, fixtureWindow)
        try await wait { controller.canSubmitCommand }
        let beforeMismatch = Set(controller.cuaTasks.map(\.id))
        submit("type \"must not enter the decoy\"", to: controller)
        try await wait {
            if case .error = controller.status { return true }
            return controller.status == .done
        }
        guard let afterMismatch = ownedTextArea(decoy),
              attribute(afterMismatch, kAXValueAttribute as CFString) as? String == decoyBefore,
              controller.cuaTasks.allSatisfy({ beforeMismatch.contains($0.id) }) else { throw Failure.wrongDocument }
        controller.auditDocumentBinding = nil
        rows.append(["case": "wrong_focused_document_negative_control", "passed": true,
                     "no_new_work": true, "owned_decoy_unchanged": true])
        try save(["status": "running", "rows": rows, "physical_input": false],
                 directory.appendingPathComponent("result.json"))
        // Literal typing is permitted only after matching the exact owned
        // document, not whichever TextEdit window happens to be first.
        for (index, text) in ["Jev audit alpha", " do not open Calculator", " type the word stop"].enumerated() {
            try await activate(textEdit, file: fixture)
            guard let area = ownedTextArea(fixture, requireFocused: false) else { throw Failure.wrongDocument }
            guard AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw Failure.wrongDocument
            }
            guard let id = foreground(textEdit), focusedOwnedDocument(fixture, windowID: id) else {
                throw Failure.wrongDocument
            }
            controller.auditDocumentBinding = (fixture, id)
            try await wait { controller.canSubmitCommand }
            let start = ProcessInfo.processInfo.systemUptime
            let existing = Set(controller.cuaTasks.map(\.id))
            submit("type \"\(text)\"", to: controller)
            do {
                try await wait {
                    guard let own = ownedTextArea(fixture) else { return false }
                    return (attribute(own, kAXValueAttribute as CFString) as? String)?.contains(text) == true
                }
                try await settleSubmittedWork(controller, previous: existing, started: start)
            } catch {
                let works = controller.cuaTasks.filter { !existing.contains($0.id) }
                rows.append(["case": "literal-\(index)", "passed": false,
                             "controller_status": statusCode(controller.status),
                             "work_count": works.count,
                             "works": works.prefix(16).map { ["id": $0.id.uuidString, "active": $0.active,
                                 "outcome": outcomeCode($0.outcome), "awaiting_answer": $0.awaitingAnswer,
                                 "awaiting_approval": $0.awaitingApproval,
                                 "application_matches_fixture": $0.spec.application == "com.apple.TextEdit",
                                 "literal_payload_matches_fixture": $0.spec.values["text"] == text,
                                 "pinned_window_matches_fixture": $0.spec.windowID == controller.auditDocumentBinding?.windowID] as [String: Any] },
                             "trace": controller.commandTrace.snapshot(since: start),
                             "trace_dropped": controller.commandTrace.dropped])
                try save(["status": "running", "rows": rows, "physical_input": false],
                         directory.appendingPathComponent("result.json"))
                throw error
            }
            rows.append(["case": "literal-\(index)", "passed": true, "owned_document_verified": true,
                         "work_count": 1, "work_done": true])
            try save(["status": "running", "rows": rows, "physical_input": false],
                     directory.appendingPathComponent("result.json"))
        }
        guard let area = ownedTextArea(fixture),
              let beforeUndo = attribute(area, kAXValueAttribute as CFString) as? String else {
            throw Failure.wrongDocument
        }
        for command in ["undo", "redo", "select all"] {
            guard let id = foreground(textEdit), focusedOwnedDocument(fixture, windowID: id) else {
                throw Failure.wrongDocument
            }
            controller.auditDocumentBinding = (fixture, id)
            try await wait { controller.canSubmitCommand }
            let previous = Set(controller.cuaTasks.map(\.id))
            let start = ProcessInfo.processInfo.systemUptime
            submit(command, to: controller)
            try await wait {
                guard let owned = ownedTextArea(fixture),
                      let value = attribute(owned, kAXValueAttribute as CFString) as? String else { return false }
                if command == "undo" { return value != beforeUndo }
                if command == "redo" { return value == beforeUndo }
                return (attribute(owned, kAXSelectedTextAttribute as CFString) as? String) == value
            }
            try await settleSubmittedWork(controller, previous: previous, started: start)
            rows.append(["command": command, "passed": true, "owned_document_verified": true,
                         "work_count": 1, "work_done": true])
            try save(["status": "running", "rows": rows, "physical_input": false],
                     directory.appendingPathComponent("result.json"))
        }
        controller.auditDocumentBinding = nil
        for command in ["don't open Calculator", "never launch Calculator"] {
            try await activate(textEdit, file: fixture)
            try await wait { controller.canSubmitCommand }
            let existing = Set(controller.cuaTasks.map(\.id))
            submit(command, to: controller)
            try await wait {
                if case .error = controller.status { return true }
                return controller.status == .done
            }
            let noWork = controller.cuaTasks.allSatisfy { existing.contains($0.id) }
            let pass = foreground(textEdit) != nil && noWork
            rows.append(["command": command, "passed": pass, "no_new_work": noWork])
            try save(["status": "running", "rows": rows, "physical_input": false],
                     directory.appendingPathComponent("result.json"))
            guard pass else { throw Failure.unavailable }
        }
        guard let owned = ownedTextArea(fixture),
              let beforeCancel = attribute(owned, kAXValueAttribute as CFString) as? String else {
            throw Failure.wrongDocument
        }
        let oldTasks = Set(controller.cuaTasks.map(\.id))
        guard let id = foreground(textEdit), focusedOwnedDocument(fixture, windowID: id) else {
            throw Failure.wrongDocument
        }
        controller.auditDocumentBinding = (fixture, id)
        submit("type \"cancelled insertion must not appear\"", to: controller)
        controller.cancelCaptureAttempt()
        try await wait { controller.canSubmitCommand }
        guard let afterCancel = ownedTextArea(fixture),
              attribute(afterCancel, kAXValueAttribute as CFString) as? String == beforeCancel,
              controller.cuaTasks.allSatisfy({ oldTasks.contains($0.id) }) else { throw Failure.unavailable }
        rows.append(["command": "cancel_before_dispatch", "passed": true, "owned_document_verified": true])
        controller.auditDocumentBinding = nil
        try save(["status": "passed", "rows": rows, "human_confirmed": false, "physical_input": false,
                  "microphone_exercised": false, "fixture": fixture.path, "desktop_ownership_release_safe": true,
                  "driver_inventory_prewarm": controller.cua.inventoryWarmupMetrics],
                 directory.appendingPathComponent("result.json"))
    }
}
