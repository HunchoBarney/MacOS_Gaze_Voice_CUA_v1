import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

/// Migrated from the removed FoundationModels chooser: voice schemas
/// and async results must stay bounded and must not invent completion.
final class IntelligenceChooserTests: XCTestCase {
    func testCatalogIsExactAndUnknownFieldsAreForbidden() {
        XCTAssertEqual(VoiceToolCatalog.schemas.compactMap { $0["name"] as? String }, VoiceToolCatalog.names)
        XCTAssertEqual(VoiceToolCatalog.names.count, 9)
        for schema in VoiceToolCatalog.schemas {
            let parameters = schema["parameters"] as? [String: Any]
            XCTAssertEqual(parameters?["additionalProperties"] as? Bool, false)
        }
    }

    func testAcceptedResultIsNotClaimedCompleted() throws {
        let text = VoiceToolCatalog.result(status: "accepted", summary: "Started.", taskID: UUID().uuidString)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertTrue(VoiceToolCatalog.validResult(value))
        XCTAssertEqual(value["status"]?.string, "accepted")
        XCTAssertNotEqual(value["status"]?.string, "completed")
    }

    func testMalformedResultCannotPassWithOnlyVersion() {
        XCTAssertFalse(VoiceToolCatalog.validResult(.object(["schema_version": .number(1)])))
    }

    @MainActor
    func testEveryCatalogEntryValidatesAndRejectsUnknownFields() async throws {
        func admission(_ text: String, context: VoiceAdmissionContext = .init()) async throws -> VoiceAdmission {
            let session = LocalSpeechSession { _ in XCTFail("catalog fixture should be a remote miss") }
            session.context = context
            let result = await session.submitTyped(text, now: 1)
            let value = try XCTUnwrap(result)
            XCTAssertEqual(value.route, .remote)
            return value
        }
        let goal = "organize these files by date"
        let base = try await admission(goal)
        let question = try await admission("what is two plus two")
        let delegated = "create an agent named Runner with role assistant"
        let agent = try await admission(delegated)
        var askContext = VoiceAdmissionContext()
        let ask = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID())
        askContext.capturedAsks = [ask]; askContext.currentAsks = [ask]
        let response = try await admission("yes please", context: askContext)
        let entries: [(String, [String: JSONValue], VoiceAdmission, VoiceAdmissionContext)] = [
            ("run_script", ["intent": .string("future-script"), "args": .object([:])], base, .init()),
            ("browser_task", ["goal": .string(goal), "browser": .string("frontmost")], base, .init()),
            ("computer_task", ["goal": .string(goal)], base, .init()),
            ("ask_about_screen", ["question": .string(goal), "scope": .string("window")], base, .init()),
            ("web_lookup", ["query": .string(goal)], base, .init()),
            ("inbox_brief", ["span": .string("unread")], base, .init()),
            ("delegate_to_agent", ["task": .string(delegated), "create": .object([
                "name": .string("Runner"), "role": .string("assistant")])], agent, .init()),
            ("respond_to_task", ["task_id": .string(ask.taskID.uuidString), "ask_id": .string(ask.askID.uuidString),
                                 "response": .string("yes please")], response, askContext),
            ("answer", ["text": .string("Four.")], question, .init())
        ]
        for (name, fields, value, context) in entries {
            let data = try JSONEncoder().encode(JSONValue.object(fields))
            let call = try VoiceToolCatalog.validate(name, arguments: String(decoding: data, as: UTF8.self),
                                                      admission: value, context: context)
            XCTAssertEqual(call.name, name)
            var invalid = fields; invalid["_unknown"] = .bool(true)
            let invalidData = try JSONEncoder().encode(JSONValue.object(invalid))
            XCTAssertThrowsError(try VoiceToolCatalog.validate(name, arguments: String(decoding: invalidData, as: UTF8.self),
                                                               admission: value, context: context), name)
        }
        let malformed = #"{"goal":"organize these files by date","gaze_target":{"x":10,"y":20}}"#
        XCTAssertThrowsError(try VoiceToolCatalog.validate("computer_task", arguments: malformed, admission: base, context: .init()))
        XCTAssertThrowsError(try VoiceToolCatalog.validate("computer_task",
            arguments: #"{"goal":"organize these files by date","app_hint":"Invented App"}"#, admission: base, context: .init()))
        var stale = askContext
        stale.currentAsks = [.init(taskID: ask.taskID, askID: UUID())]
        let args = try JSONEncoder().encode(JSONValue.object(entries[7].1))
        XCTAssertThrowsError(try VoiceToolCatalog.validate("respond_to_task", arguments: String(decoding: args, as: UTF8.self),
                                                          admission: response, context: stale))
    }
}
