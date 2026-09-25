import Foundation
import Combine
import AppKit
import JevVoiceCore

protocol CuaPermissionStatusClient {
    func checkPermissions(prompt: Bool) async throws -> JSONValue
}

extension CuaConnection: CuaPermissionStatusClient {
    func checkPermissions(prompt: Bool) async throws -> JSONValue {
        try await call("check_permissions", arguments: ["prompt": .bool(prompt)])
    }
}

enum CuaPermissionProbe {
    static func read(using client: CuaPermissionStatusClient) async throws -> JSONValue {
        try await client.checkPermissions(prompt: false)
    }
}

enum CuaSetupFixture {
    static func documentURL(in directory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory.appendingPathComponent("Jarvis-Check-\(UUID().uuidString).txt")
    }
}

/// Visible setup proof uses only its own disposable document, never the user's open document.
@MainActor
final class CuaSetup: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = "The pinned Cua Driver Local build must be installed and have Accessibility and Screen Recording access."
    @Published private(set) var verified = false
    private var task: Task<Void, Never>?

    func verify(apiKey: String, browser: Bool = false) {
        guard !busy else { return }
        guard !apiKey.isEmpty else { message = "Save your Jev API key first."; return }
        busy = true
        verified = false
        message = "Connecting to Cua…"
        task = Task {
            let connection = CuaConnection()
            let label = "Jarvis setup \(UUID().uuidString.prefix(6))"
            do {
                try await connection.connect()
                let permissions = try await CuaPermissionProbe.read(using: connection)
                guard permissions["accessibility"] == .bool(true), permissions["screen_recording"] == .bool(true) else {
                    throw DriverConnectionError.refused("Enable CuaDriverLocal in macOS Accessibility and Screen Recording settings.")
                }
                _ = try await connection.call("start_session", arguments: ["session": .string(label)])
                try Task.checkCancellation()
                if browser { try await verifyBrowser(connection, label: label, apiKey: apiKey) }
                else { try await verifyDocument(connection, label: label, apiKey: apiKey) }
            } catch is CancellationError {
                message = "Setup check cancelled. Already dispatched effects may have finished."
            } catch {
                message = error.localizedDescription
            }
            // Cleanup must not inherit cancellation of the requesting task.
            await Task.detached {
                _ = try? await connection.call("end_session", arguments: ["session": .string(label)], timeout: 5)
                await connection.close()
            }.value
            busy = false
            task = nil
        }
    }
    private func verifyDocument(_ connection: CuaConnection, label: String, apiKey: String) async throws {
        let fixture = CuaSetupFixture.documentURL()
        let requestingForegroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try "".write(to: fixture, atomically: true, encoding: .utf8)
        message = "Opening a disposable TextEdit document…"
        // `launch_app` has no session field in the installed schema. Keep the
        // lifecycle label on later calls that actually accept it.
        let opened = try await connection.call("launch_app", arguments: [
            "bundle_id": .string("com.apple.TextEdit"), "urls": .array([.string(fixture.path)])
        ])
        guard let pid = opened["pid"]?.integer else { throw DriverConnectionError.malformed }
        var matches: [JSONValue] = []
        for _ in 0..<50 {
            let windows = try await connection.call("list_windows", arguments: ["pid": .number(Double(pid)), "session": .string(label)])
            matches = (windows["windows"]?.array ?? []).filter { $0["title"]?.string?.contains(fixture.lastPathComponent) == true }
            if !matches.isEmpty { break }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        guard matches.count == 1, let wid = matches[0]["window_id"]?.integer else {
            throw DriverConnectionError.refused("Cua could not identify the disposable document. Nothing was typed.")
        }
        // The installed Driver restores the previous foreground for eight seconds
        // after launch_app opens a URL. Let that launch watchdog finish before the
        // first explicit foreground request; an uncertain activation cannot be
        // safely repeated. Recheck the exact window after the wait.
        try await Task.sleep(for: .seconds(9))
        try Task.checkCancellation()
        guard let requestingForegroundPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == requestingForegroundPID else {
            throw DriverConnectionError.refused("Another app took focus while the disposable document opened. Nothing was typed.")
        }
        let settled = try await connection.call("list_windows", arguments: [
            "pid": .number(Double(pid)), "session": .string(label)
        ])
        guard (settled["windows"]?.array ?? []).filter({ $0["window_id"]?.integer == wid &&
            $0["title"]?.string?.contains(fixture.lastPathComponent) == true }).count == 1 else {
            throw DriverConnectionError.refused("The disposable document changed during launch. Nothing was typed.")
        }
        let target: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "session": .string(label), "include_screenshot": .bool(false), "max_elements": .number(150)]
        let foreground = try await connection.call("bring_to_front", arguments: [
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)), "session": .string(label)
        ])
        guard foreground["activated"] == .bool(true), foreground["exact_window_effect"]?["verified"] == .bool(true) else {
            throw DriverConnectionError.refused("Cua could not verify the disposable document in front. Nothing was typed.")
        }
        var fields: [JSONValue] = []
        // TextEdit may create the URL-backed window before its editable AX body
        // is ready. Reobserve for a bounded settling window; never infer a target.
        for _ in 0..<150 {
            let snapshot = try await connection.call("get_window_state", arguments: target)
            fields = (snapshot["elements"]?.array ?? []).filter { ["AXTextArea", "AXTextField"].contains($0["role"]?.string ?? "") }
            if !fields.isEmpty { break }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !fields.isEmpty else {
            throw DriverConnectionError.refused("Cua did not expose an editable document body. Nothing was typed.")
        }
        var candidates: [String: JSONValue] = [:]
        var criteria: [String: String?] = ["abstain": "No editable document body is observed."]
        for (index, field) in fields.enumerated() {
            let id = "field_\(index)"
            candidates[id] = field
            criteria[id] = String(data: try JSONEncoder().encode(field), encoding: .utf8)
        }
        message = "Jev is choosing the observed document field…"
        let started = ContinuousClock.now
        let state: JSONValue = .object([
            "goal": .string("Insert setup text into the newly created document body."),
            "document_is_new_empty_fixture": .bool(true), "observed_fields": .array(fields)
        ])
        let chosen = try await JevClient(apiKey: apiKey).systemOne(state: state, questions: [
            "field": .choice(instructions: "Select the editable document body for the requested insertion. Abstain if absent or ambiguous.", criteria: criteria)
        ])
        guard case let .choice(id, confidence, probabilities) = chosen.response.answers["field"],
              confidence.isFinite, (0...1).contains(confidence),
              probabilities.keys.allSatisfy({ criteria.keys.contains($0) }),
              probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw DriverConnectionError.malformed
        }
        guard id != "abstain" else {
            throw DriverConnectionError.refused("Jev abstained from choosing among \(candidates.count) observed text fields. Nothing was typed.")
        }
        guard let field = candidates[id], field["element_token"]?.string != nil else {
            throw DriverConnectionError.malformed
        }
        guard (field["value"]?.string ?? "").isEmpty else {
            throw DriverConnectionError.refused("The selected field is not blank. Nothing was typed.")
        }
        try Task.checkCancellation()
        // A model request creates a race with user edits. Reobserve before insertion.
        let fresh = try await connection.call("get_window_state", arguments: target)
        let freshFields = (fresh["elements"]?.array ?? []).filter {
            $0["role"] == field["role"] && $0["label"] == field["label"] &&
            ($0["value"]?.string ?? "").isEmpty
        }
        guard freshFields.count == 1, let freshToken = freshFields[0]["element_token"]?.string else {
            throw DriverConnectionError.refused("The disposable field changed while Jev was deciding. Nothing was typed.")
        }
        try Task.checkCancellation()
        let text = "Jarvis connected through Cua and Jev."
        message = "Writing and checking the disposable document…"
        _ = try await connection.call("type_text", arguments: ["pid": .number(Double(pid)),
            "window_id": .number(Double(wid)), "element_token": .string(freshToken), "text": .string(text),
            "delivery_mode": .string("background"), "session": .string(label)])
        let result = try await connection.call("get_window_state", arguments: target)
        guard (result["elements"]?.array ?? []).contains(where: { $0["value"]?.string == text }) else {
            throw DriverConnectionError.refused("The document did not match the expected text. The action will not be repeated.")
        }
        try Task.checkCancellation()
        verified = true
        let elapsed = started.duration(to: .now)
        message = "Verified: Jev selected a field, Cua wrote the setup text, and fresh readback matched. Decision + write + readback: \(elapsed)."
    }

    private func verifyBrowser(_ connection: CuaConnection, label: String, apiKey: String) async throws {
        message = "Opening an isolated browser for the public example-domain check…"
        let prepared = try await connection.call("browser_prepare", arguments: [
            "allow_launch": .bool(true), "profile": .object(["mode": .string("isolated_new")]), "session": .string(label)
        ], timeout: 60)
        guard let pid = prepared["prepared_pid"]?.integer else { throw DriverConnectionError.malformed }
        let windows = try await connection.call("list_windows", arguments: ["pid": .number(Double(pid)), "session": .string(label)])
        let visible = (windows["windows"]?.array ?? []).filter { $0["is_on_screen"] == .bool(true) }
        guard visible.count == 1, let window = visible.first?["window_id"] else {
            throw DriverConnectionError.refused("The isolated browser window is unavailable or ambiguous.")
        }
        let bound = try await connection.call("get_browser_state", arguments: [
            "pid": .number(Double(pid)), "window_id": window, "session": .string(label)
        ])
        guard let target = bound["target_id"], let tabs = bound["tabs"]?.array, tabs.count == 1,
              let tab = tabs[0]["tab_id"] else { throw DriverConnectionError.malformed }
        var args: [String: JSONValue] = ["target_id": target, "tab_id": tab, "session": .string(label)]
        var navigate = args; navigate["url"] = .string("https://example.com")
        _ = try await connection.call("browser_navigate", arguments: navigate)
        args["snapshot_format"] = .string("semantic_v2")
        let before = try await connection.call("get_browser_state", arguments: args)
        let links = (before["refs"]?.array ?? []).filter { $0["role"] == .string("link") }
        var candidates: [String: JSONValue] = [:]
        var criteria: [String: String?] = ["abstain": "No suitable link is observed."]
        for (index, link) in links.enumerated() {
            let id = "link_\(index)"; candidates[id] = link
            criteria[id] = String(data: try JSONEncoder().encode(link), encoding: .utf8)
        }
        message = "Jev is selecting the link to learn about example domains…"
        let chosen = try await JevClient(apiKey: apiKey).systemOne(state: before, questions: [
            "link": .choice(instructions: "Select the observed link to learn more about example domains. Abstain if no suitable link exists.", criteria: criteria)
        ])
        guard case let .choice(id, confidence, _) = chosen.response.answers["link"], confidence.isFinite,
              (0...1).contains(confidence), let selected = candidates[id], let ref = selected["ref"] else {
            throw DriverConnectionError.refused("Jev did not select an observed link. Nothing was clicked.")
        }
        try Task.checkCancellation()
        _ = try await connection.call("browser_click", arguments: ["target_id": target, "tab_id": tab,
            "session": .string(label), "ref": ref, "input_route": .string("dom_event")])
        let after = try await connection.call("get_browser_state", arguments: args)
        guard let urlText = after["page"]?["url"]?.string, let url = URL(string: urlText),
              ["iana.org", "www.iana.org"].contains(url.host ?? ""), url.path.contains("domains") else {
            throw DriverConnectionError.refused("Navigation was not independently observed at the expected example-domain information page. No replay.")
        }
        try Task.checkCancellation()
        verified = true
        message = "Verified: Jev selected a browser link, Cua clicked it, and a fresh browser observation confirmed the IANA domain-information page."
    }

    func cancel() { task?.cancel() }
}
