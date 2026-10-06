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
                // The permission read and the session mint are independent
                // roundtrips on the same transport — issue them together; the
                // cleanup below ends the session even when a grant is missing.
                async let permissionProbe = CuaPermissionProbe.read(using: connection)
                async let session = connection.call("start_session", arguments: ["session": .string(label)])
                let permissions = try await permissionProbe
                _ = try await session
                guard permissions["accessibility"] == .bool(true), permissions["screen_recording"] == .bool(true) else {
                    throw DriverConnectionError.refused(Self.permissionSummary(permissions))
                }
                try Task.checkCancellation()
                if browser { try await verifyBrowser(connection, label: label, apiKey: apiKey) }
                else { try await verifyControlPlane(connection) }
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
    /// Names the missing grants and whose TCC identity answered — embedded
    /// transports report the HOST app's grant state, so a generic "driver
    /// failed" would send the user to the wrong Settings pane.
    nonisolated static func permissionSummary(_ permissions: JSONValue) -> String {
        var missing: [String] = []
        if permissions["accessibility"] != .bool(true) { missing.append("Accessibility") }
        if permissions["screen_recording"] != .bool(true) { missing.append("Screen Recording") }
        let owner: String
        switch permissions["source"]?["attribution"]?.string {
        case "driver-daemon": owner = "the CuaDriver app"
        case "caller": owner = "the app that launched the driver (its answer may not reflect the driver's own grants)"
        default: owner = "Jev Voice"
        }
        return "Missing \(missing.joined(separator: " and ")) access for \(owner). Enable it in System Settings › Privacy & Security, then retry."
    }

    /// The ~1s control-plane proof: the permission read and session mint
    /// already answered above; a list_apps round-trip proves the daemon
    /// serves real requests. No disposable app, no model call — the
    /// driver's own status is the report.
    private func verifyControlPlane(_ connection: CuaConnection) async throws {
        message = "Probing the driver control plane…"
        let started = ContinuousClock.now
        // list_apps takes no arguments — the empty input contract rejects
        // a session field.
        let inventory = try await connection.call("list_apps", arguments: [:])
        try Task.checkCancellation()
        let apps = inventory["apps"]?.array ?? []
        let running = apps.filter { ($0["pid"]?.integer ?? 0) > 0 }.count
        verified = true
        message = "Verified: Cua answered permissions, minted a session, and listed \(running) running app(s) out of \(apps.count) in \(started.duration(to: .now))."
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
