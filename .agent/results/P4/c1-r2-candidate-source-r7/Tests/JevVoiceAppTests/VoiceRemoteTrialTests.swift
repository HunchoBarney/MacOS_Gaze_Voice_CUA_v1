import Foundation
import JevVoiceCore
import XCTest
@testable import JevVoice

@MainActor
final class VoiceRemoteTrialTests: XCTestCase {
    private func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testLivePolicyRejectsAudioImagesAndNonDiagnosticText() {
        for frame in [
            #"{"type":"input_audio_buffer.append","audio":"forbidden"}"#,
            #"{"type":"input_audio_buffer.commit"}"#,
            #"{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_image","image_url":"forbidden"}]}}"#,
            #"{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_text","text":"not an authorized diagnostic"}]}}"#
        ] {
            XCTAssertThrowsError(try VoiceRemoteLivePolicy.prepare(frame))
        }
    }

    func testLivePolicyPreservesToolsAndForcesOnlyTextOutput() throws {
        let frame = #"{"type":"session.update","session":{"output_modalities":["audio"],"tools":[{"name":"answer"}],"instructions":"unchanged","audio":{"output":{"voice":"marin"}}}}"#
        let value = try decode(VoiceRemoteLivePolicy.prepare(frame))
        XCTAssertEqual(value["session"]?["output_modalities"]?.array, [.string("text")])
        XCTAssertEqual(value["session"]?["tools"], try decode(frame)["session"]?["tools"])
        XCTAssertEqual(value["session"]?["audio"], try decode(frame)["session"]?["audio"])
        XCTAssertEqual(value["session"]?["instructions"]?.string, "unchanged")
    }

    func testLivePolicyRequiresReservedRequestAndNeverOverridesDisabledTools() throws {
        XCTAssertThrowsError(try VoiceRemoteLivePolicy.prepare(#"{"type":"response.create"}"#))
        let frame = #"{"type":"response.create","response":{"tool_choice":"none"}}"#
        let value = try decode(VoiceRemoteLivePolicy.prepare(frame, requestID: "reserved-1", forceAnswer: true))
        XCTAssertEqual(value["event_id"]?.string, "reserved-1")
        XCTAssertEqual(value["response"]?["output_modalities"]?.array, [.string("text")])
        XCTAssertEqual(value["response"]?["max_output_tokens"]?.integer, 256)
        XCTAssertEqual(value["response"]?["tool_choice"]?.string, "none")
    }

    func testPersistentResponseBudgetCannotResetAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("authorization.json")
        let auth: [String: Any] = [
            "schema_version": 1, "id": "test-authorization",
            "scope": "p3-openai-realtime-fixed-text-no-desktop",
            "maximum_responses": 1, "reserved_responses": 0,
            "approved_at": Date().timeIntervalSince1970,
            "expires_at": Date().timeIntervalSince1970 + 60,
            "user_selection": "Authorize capped tests", "requests": []
        ]
        try JSONSerialization.data(withJSONObject: auth).write(to: url)
        let first = try VoiceRemoteResponseBudget(url: url, authorizationID: "test-authorization")
        let request = try await first.reserveResponse(caseID: "safe-miss")
        XCTAssertFalse(request.isEmpty)
        let second = try VoiceRemoteResponseBudget(url: url, authorizationID: "test-authorization")
        do {
            _ = try await second.reserveResponse(caseID: "cancel")
            XCTFail("a second instance must not reset the authorization")
        } catch {}
        let saved = try decode(String(decoding: Data(contentsOf: url), as: UTF8.self))
        XCTAssertEqual(saved["reserved_responses"]?.integer, 1)
        XCTAssertEqual(saved["requests"]?.array?.first?["request_id"]?.string, request)
    }

    func testWireMetadataIsBoundedAndDoesNotRetainPayloads() {
        let recorder = VoiceRemoteMetadata(frameLimit: 1, byteLimit: 4096)
        let envelope = RealtimeVoiceClient.WireEnvelope(
            connectionID: UUID(), kind: "response.done", responseID: "resp-1", inputItemID: nil,
            events: [.failure("private-marker"), .assistantDone("private-marker")])
        recorder.record(envelope)
        XCTAssertFalse(recorder.snapshot["overflow"]?.bool ?? true)
        XCTAssertFalse(String(describing: recorder.snapshot).contains("private-marker"))
        recorder.record(envelope)
        XCTAssertEqual(recorder.snapshot["overflow"]?.bool, true)
        XCTAssertEqual(recorder.snapshot["frames"]?.array?.count, 1)
    }

    func testOversizedIdentityFailsInsteadOfTruncatingEvidence() {
        let recorder = VoiceRemoteMetadata()
        recorder.record(.init(connectionID: UUID(), kind: "response.created",
                              responseID: String(repeating: "x", count: 201), inputItemID: nil, events: []))
        XCTAssertEqual(recorder.snapshot["overflow"]?.bool, true)
        XCTAssertEqual(recorder.snapshot["frames"]?.array?.count, 0)
    }

    func testIncomingNestedMediaIsRejectedButAudioConfigurationIsNotPayload() throws {
        for frame in [
            #"{"type":"response.output_item.done","item":{"content":[{"type":"audio","audio":"forbidden"}]}}"#,
            #"{"type":"response.output_item.done","item":{"content":[{"type":"output_image","image_url":"forbidden"}]}}"#,
            #"{"type":"response.audio.delta","delta":"forbidden"}"#
        ] {
            XCTAssertThrowsError(try VoiceRemoteLivePolicy.validateInbound(decode(frame)))
        }
        try VoiceRemoteLivePolicy.validateInbound(decode(
            #"{"type":"session.updated","session":{"audio":{"output":{"format":{"type":"audio/pcm","rate":24000}}}}}"#))
    }

    func testRetainedLiveCallCanOnlyContainFixedNumericAnswer() throws {
        try VoiceRemoteLivePolicy.validateHeldAnswer(decode(
            #"{"type":"response.function_call_arguments.done","name":"answer","arguments":"{\"text\":\"10\"}"}"#))
        XCTAssertThrowsError(try VoiceRemoteLivePolicy.validateHeldAnswer(decode(
            #"{"type":"response.function_call_arguments.done","name":"answer","arguments":"{\"text\":\"private-marker\"}"}"#)))
        XCTAssertThrowsError(try VoiceRemoteLivePolicy.validateHeldAnswer(decode(
            #"{"type":"response.function_call_arguments.done","name":"computer_task","arguments":"{}"}"#)))
    }
}
