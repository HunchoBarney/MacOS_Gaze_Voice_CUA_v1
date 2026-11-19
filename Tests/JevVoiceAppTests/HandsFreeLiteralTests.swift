import ApplicationServices
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class LiteralFixtureField {
    var value = ""
    var writes = 0
    func bind(_ session: ConversationSession, app: String, window: Int) {
        session.readPendingAsks = { [] }
        session.literalInputPermitted = { _ in true }
        session.captureLiteralTarget = { target, id in
            guard target == app, id == window else { return nil }
            return SpokenLiteralTarget(state: { (self.value, NSRange(location: self.value.utf16.count, length: 0)) },
                write: { text, _, _, permitted in
                    guard permitted() else { return nil }
                    self.writes += 1; self.value += text
                    return .init(succeeded: true, issuedAt: 1, returnedAt: 2)
                })
        }
    }
}

@MainActor
final class HandsFreeLiteralTests: XCTestCase {
    func testIndeterminateOrSecureAncestryNeverReadsValue() {
        for (status, subrole, node): (AXError, String?, Int) in [
            (.cannotComplete, nil, 0), (.cannotComplete, nil, 1), (.success, nil, 0),
            (.noValue, nil, 1), (.success, kAXSecureTextFieldSubrole, 0), (.success, kAXSecureTextFieldSubrole, 1)
        ] {
            var reads = 0, writes = 0
            let target = SpokenLiteralTarget(eligible: {
                SpokenLiteralTarget.nativeTree(from: 0, isWindow: { $0 == 2 }, safeNode: {
                    SpokenLiteralTarget.nonsecureSubrole($0 == node ? status : .attributeUnsupported, $0 == node ? subrole : nil)
                }, parent: { $0 + 1 })
            }, state: { reads += 1; return ("", .init(location: 0, length: 0)) },
            write: { _, _, _, _ in writes += 1; return nil })
            XCTAssertNil(target)
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(writes, 0)
        }
        XCTAssertTrue(SpokenLiteralTarget.nonsecureSubrole(.attributeUnsupported, nil))
        XCTAssertTrue(SpokenLiteralTarget.nonsecureSubrole(.success, "AXStandardWindow"))
    }

    func testOwnedWireLiteralUsesOnlyOnsetField() async throws {
        for scenario in ["exact", "polite", "politeNoWindow", "quoted", "quotedCompound", "swap", "selection", "edit", "unicode", "missing",
                         "permission", "revokedAtWrite", "revokedAfterWrite", "newAsk", "scope", "cancel", "late",
                         "falseAck", "wrongReadback", "compound", "comma", "qualified", "denied"] {
            let wire = RecordedVoiceWire()
            let client = RealtimeVoiceClient(wireFactory: { _ in wire })
            let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client)
            let session = lane.conversation
            var context = VoiceAdmissionContext(targetAppID: "fixture.editor", windowID: 7)
            context.targetID = "window:42:7"
            context.editableTarget = true
            if scenario == "politeNoWindow" { context = VoiceAdmissionContext() }
            let original = "café old"
            var value = original, selected = NSRange(location: 5, length: 3)
            var decoy = original
            var sameField = true, permitted = true, writes = 0, captures = 0, starts = 0, sealed = 0
            var messages = [String](), interpreted = 0, executed = 0
            let payload = scenario == "quoted" ? "scratch that" : scenario == "quotedCompound" ? "blue, click Save" : "the blue kite landed by the fence"
            let phrase = ["compound":"Type blue then click Save", "qualified":"Type blue in Safari",
                          "comma":"Type blue, click Save", "quotedCompound":"Type “blue, click Save”",
                          "polite":"Go ahead and type " + payload, "politeNoWindow":"Go ahead and type " + payload,
                          "denied":"Type sudo rm -rf /", "quoted":"Type “scratch that”"][scenario] ?? "Type " + payload
            session.readContext = { context }
            session.readPendingAsks = { context.currentAsks }
            session.literalInputPermitted = { permitted && lane.ownsConversationInput($0) }
            session.captureLiteralTarget = { _, _ in
                captures += 1
                guard scenario != "missing" else { return nil }
                let boundToOriginal = sameField
                return SpokenLiteralTarget(state: {
                    sameField == boundToOriginal ? (boundToOriginal ? value : decoy, selected) : nil
                }, write: { text, before, range, allowed in
                    if scenario == "revokedAtWrite" { permitted = false }
                    guard allowed(), sameField == boundToOriginal,
                          (boundToOriginal ? value : decoy).utf8.elementsEqual(before.utf8), selected == range else { return nil }
                    writes += 1
                    let after = (before as NSString).replacingCharacters(in: range, with: text)
                    if !boundToOriginal { decoy = after }
                    else if scenario != "wrongReadback" { value = after }
                    if scenario == "revokedAfterWrite" { permitted = false }
                    return .init(succeeded: scenario != "falseAck", issuedAt: 1, returnedAt: 2)
                })
            }
            session.onEvent = {
                switch $0 {
                case .began: starts += 1
                case .sealed: sealed += 1
                case .feedback(_, let message): messages.append(message)
                default: break
                }
            }
            session.interpret = { _, _, _ in interpreted += 1; throw VoiceError("No optional key") }
            session.execute = { _ in executed += 1; throw CancellationError() }
            session.onControl = { _ in XCTFail(scenario) }
            try await lane.prepareRealtimeTransport(.conversation)
            try lane.beginRealtimeConversation(session: UUID())
            try await wire.push(["type": .string("input_audio_buffer.speech_started"), "item_id": .string("one")])
            for _ in 0..<100 where starts == 0 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(starts, 1, scenario)
            switch scenario {
            case "swap": sameField = false
            case "selection": selected = NSRange(location: 0, length: 0)
            case "unicode": value = "cafe\u{301} old"
            case "edit": value = "BLUE old"
            case "permission": permitted = false
            case "newAsk": context.currentAsks = [.init(taskID: UUID(), askID: UUID())]
            case "scope": context.targetID = "window:42:8"; context.windowID = 8
            case "cancel": session.cancelExternalWork()
            case "late":
                try await wire.push(["type": .string("input_audio_buffer.speech_started"), "item_id": .string("two")])
                for _ in 0..<100 where starts < 2 { try await Task.sleep(for: .milliseconds(5)) }
            default: break
            }
            let commit: [String:JSONValue] = ["type": .string("input_audio_buffer.committed"), "item_id": .string("one")]
            let final: [String:JSONValue] = ["type": .string("conversation.item.input_audio_transcription.completed"),
                                             "item_id": .string("one"), "transcript": .string(phrase)]
            try await wire.push(final)
            try await wire.push(commit)
            try await wire.push(commit)
            try await wire.push(final)
            if scenario == "late" || scenario == "cancel" { try await Task.sleep(for: .milliseconds(50)) }
            else { for _ in 0..<200 where messages.isEmpty { try await Task.sleep(for: .milliseconds(5)) } }
            let success = ["exact", "polite", "quoted", "quotedCompound"].contains(scenario)
            let uncertain = ["falseAck", "wrongReadback", "revokedAfterWrite"].contains(scenario)
            XCTAssertEqual(decoy, original, scenario)
            XCTAssertEqual(writes, success || uncertain ? 1 : 0, scenario)
            XCTAssertEqual(captures, scenario == "late" ? 2 : scenario == "politeNoWindow" ? 0 : 1, scenario)
            XCTAssertEqual(interpreted, 0, scenario)
            XCTAssertEqual(executed, 0, scenario)
            if success {
                XCTAssertEqual(value, "café " + payload, scenario)
                XCTAssertEqual(messages, ["Typed the text."], scenario)
            } else if uncertain {
                XCTAssertEqual(messages.count, 1, scenario)
                XCTAssertTrue(messages.first?.contains("couldn’t verify") == true, scenario)
            } else {
                XCTAssertFalse(messages.contains("Typed the text."), scenario)
            }
            if scenario != "cancel" { XCTAssertEqual(sealed, 1, scenario) }
            lane.stopConversation()
            client.teardown()
        }
    }
}
