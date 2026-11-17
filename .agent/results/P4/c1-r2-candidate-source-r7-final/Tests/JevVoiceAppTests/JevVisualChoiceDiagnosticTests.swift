import AppKit
import CryptoKit
import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

final class JevVisualChoiceDiagnosticTests: XCTestCase {
    func testOwnedFixtureReadOnlyVisualDecisionCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_P4_REAL_APPS"] == "approved",
              let path = environment["JEV_VISUAL_CHOICE_INPUT"],
              let key = environment["JEV_NATIVE_CHOICE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Opt-in owned visual-fixture routing diagnostic")
        }
        let file = URL(fileURLWithPath: path)
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        let pid = try XCTUnwrap(input["window"]?["pid"]?.integer)
        let windowID = try XCTUnwrap(input["window"]?["window_id"]?.integer)
        let binary = try XCTUnwrap(input["fixture"]?["binary"]?.string)
        let expectedHash = try XCTUnwrap(input["fixture"]?["binary_sha256"]?.string)
        let identity = await MainActor.run { () -> (String?, String?) in
            let app = NSRunningApplication(processIdentifier: pid_t(pid))
            return (app?.bundleIdentifier, app?.executableURL?.resolvingSymlinksInPath().path)
        }
        let actualHash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: binary)))
            .map { String(format: "%02x", $0) }.joined()
        guard input["qualification"] == .bool(false),
              identity.0 == "dev.jevvoice.visual-fixture",
              identity.1 == URL(fileURLWithPath: binary).resolvingSymlinksInPath().path,
              actualHash == expectedHash,
              input["fixture"]?["source_sha256"]?.string
                == "27ba1284dbc3949bc1b738e8ca17e84d89351472bfaca17c16b22b745285bde1" else {
            return XCTFail("Unverified visual-fixture executable")
        }
        let journal = URL(fileURLWithPath: try XCTUnwrap(input["fixture_state"]?.string))
        func checkJournal() throws {
            let state = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: journal))
            guard state["pid"]?.integer == pid, state["window_id"]?.integer == windowID,
                  state["target_count"] == .number(0), state["other_count"] == .number(0),
                  state["status"] == .string("Nothing activated.") else {
                throw JevNativeChoiceDiagnosticTests.DiagnosticError.unexpectedRead("fixture changed")
            }
        }
        try checkJournal()
        let window = JevVoice.WindowRef(pid: pid, windowID: windowID)
        let observed = await NativeWindowObservation.live(window, .standard)
        let native = try XCTUnwrap(observed)
        guard native.window == window else { return XCTFail("Native fixture identity changed") }
        let driver = try XCTUnwrap(input["driver_reply"])
        guard driver["pid"]?.integer == pid, driver["window_id"]?.integer == windowID,
              driver["window_title"] == .string("Jev Visual Qualification") else {
            return XCTFail("Foreign driver window")
        }
        let session = try XCTUnwrap(input["session"]?.string)
        let origin = CuaResultOrigin(session: session,
            daemonSocket: try XCTUnwrap(input["daemon_socket"]?.string),
            transport: UUID(), sessionEpoch: UUID())
        let tools = CuaConnection.capturedElementTools(try XCTUnwrap(input["tools"]))
        let client = JevClient(apiKey: key, model: "jev-1.14.0")
        let capture = JevNativeChoiceDiagnosticTests.Capture(
            directory: file.deletingLastPathComponent(), client: client)
        let choose = JevChooser.make(model: client.model) { state, questions in
            try await capture.infer(state, questions)
        }
        let loop = DriveLoop(call: { tool, arguments in
            switch tool {
            case "list_apps": return try XCTUnwrap(input["apps"])
            case "list_windows": return try XCTUnwrap(input["windows"])
            case "get_window_state":
                guard arguments["pid"]?.integer == pid,
                      arguments["window_id"]?.integer == windowID else {
                    throw JevNativeChoiceDiagnosticTests.DiagnosticError.unexpectedRead("foreign window")
                }
                return .object(["structuredContent": driver])
            default:
                throw JevNativeChoiceDiagnosticTests.DiagnosticError.unexpectedRead(tool)
            }
        }, choose: { state, candidates in
            let choice = try await choose(state, candidates)
            try await capture.chosen(choice)
            return choice
        }, ask: nil, granted: { false }, explicitConsent: false,
           scopedCall: { tool, arguments, expectedOrigin in
            guard tool == "get_window_state", expectedOrigin == nil,
                  arguments["pid"]?.integer == pid,
                  arguments["window_id"]?.integer == windowID,
                  arguments["include_screenshot"] == .bool(true) else {
                throw JevNativeChoiceDiagnosticTests.DiagnosticError.unexpectedRead(tool)
            }
            return CuaToolResult(structured: driver,
                content: try XCTUnwrap(input["image_content"]?.array), origin: origin,
                capturedElementTools: tools)
        }, visualChoose: JevChooser.makeVisual(model: client.model) { state, questions, assets in
            try await capture.infer(state, questions, assets: assets)
        })
        let result = try await loop.preview(
            DriveTask(goal: "Activate the green triangle.",
                application: "dev.jevvoice.visual-fixture", pid: pid, windowID: windowID,
                deny: try XCTUnwrap(input["deny"]?.array).map { try XCTUnwrap($0.string) }),
            session: session)
        try checkJournal()
        let requests = await capture.requests
        XCTAssertGreaterThan(requests, 0)
        try await capture.write("diagnostic.json", data: JSONEncoder().encode(JSONValue.object([
            "qualification": .bool(false), "actuations": .number(0),
            "model_requests": .number(Double(requests)), "preview": .string(result),
            "native_complete": .bool(native.complete),
            "captured_native_tools": .array(tools.sorted().map(JSONValue.string)),
            "origin_kind": .string("read-only diagnostic replay, not input authority"),
            "history_kind": .string("production preview, not actuator-run history"),
        ])))
    }
}
