import Foundation
import XCTest
@testable import JevVoice

final class ControlReplyEnvelopeTests: XCTestCase {
    private typealias Wire = [String: Any]
    private typealias Step = ControlReplyEnvelope.Step
    private let nonce = "nonce_fixture_1"
    private let answer = "Close closes this window."
    private let bytes = Data([0, 1, 2, 3])
    private enum Slot: Int { case created, item, part, audio, words, audioDone, wordsDone, partDone, itemDone, done }

    private func fixture() -> [Wire] {
        Self.trace(nonce: nonce, answer: answer, bytes: bytes)
    }

    static func trace(nonce: String, answer: String, bytes: Data) -> [[String: Any]] {
        let message: Wire = ["id": "item_a", "type": "message", "object": "realtime.item",
                             "role": "assistant", "status": "in_progress", "content": []]
        let finished = message.merging(["status": "completed",
                                        "content": [["type": "output_audio", "transcript": answer]]]) { _, v in v }
        let response: Wire = ["id": "resp_a", "object": "realtime.response", "conversation_id": NSNull(),
                              "audio": ["output": ["voice": "marin", "format": ["type": "audio/pcm", "rate": 24000]]],
                              "metadata": ["control_nonce": nonce], "output_modalities": ["audio"],
                              "status_details": NSNull(), "status": "in_progress", "output": []]
        let done = response.merging(["output": [finished], "status": "completed",
                                     "usage": ["output_tokens": 12]]) { _, v in v }
        let item: Wire = ["response_id": "resp_a", "output_index": 0]
        let part = item.merging(["content_index": 0, "item_id": "item_a"]) { _, v in v }
        var wire: [Wire] = [
            ["type": "response.created", "response": response],
            item.merging(["type": "response.output_item.added", "item": message]) { _, v in v },
            part.merging(["type": "response.content_part.added",
                          "part": ["type": "audio", "transcript": "", "audio": NSNull()]]) { _, v in v },
            part.merging(["type": "response.output_audio.delta", "obfuscation": "pad",
                          "delta": bytes.base64EncodedString()]) { _, v in v },
            part.merging(["type": "response.output_audio_transcript.delta", "delta": answer]) { _, v in v },
            part.merging(["type": "response.output_audio.done"]) { _, v in v },
            part.merging(["type": "response.output_audio_transcript.done", "transcript": answer]) { _, v in v },
            part.merging(["type": "response.content_part.done", "part": ["type": "audio", "transcript": answer]]) { _, v in v },
            item.merging(["type": "response.output_item.done", "item": finished]) { _, v in v },
            ["type": "response.done", "response": done]
        ]
        for i in wire.indices { wire[i]["event_id"] = "event_\(i)" }
        return wire
    }

    private func steps(_ events: [Wire]) throws -> [Step] {
        var envelope = ControlReplyEnvelope(nonce: nonce, expectedAnswer: answer)
        return try events.map { event in
            let bytes = try JSONSerialization.data(withJSONObject: event)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? Wire)
            return envelope.accept(try XCTUnwrap(ControlReplyEnvelope.decode(object)))
        }
    }

    private func changed(_ slot: Slot, _ patch: (inout Wire) -> Void) -> [Wire] {
        var wire = fixture()
        patch(&wire[slot.rawValue])
        return wire
    }

    private func changing(_ slot: Slot, nested key: String, _ patch: (inout Wire) -> Void) -> [Wire] {
        changed(slot) { event in
            var object = event[key] as! Wire
            patch(&object)
            event[key] = object
        }
    }

    private func assertRejected(_ wire: [Wire], file: StaticString = #filePath, line: UInt = #line) throws {
        let results = try steps(wire)
        XCTAssertFalse(results.contains { if case .completed = $0 { return true }; return false }, file: file, line: line)
        let index = try XCTUnwrap(results.firstIndex(of: .rejected), file: file, line: line)
        XCTAssertTrue(results[index...].allSatisfy { $0 == .rejected }, file: file, line: line)
    }

    func testOnlyCanonicalDoneReleasesBufferedBytesOnce() throws {
        let frames = fixture()
        let late = [frames.last!, frames[Slot.audio.rawValue], frames.first!]
        XCTAssertEqual(try steps(frames + late), [.created("resp_a")] + Array(repeating: .pending, count: 8)
                       + [.completed(pcm: bytes, itemID: "item_a")] + Array(repeating: .rejected, count: 3))
        XCTAssertNil(ControlReplyEnvelope.decode(["type": "input_audio_buffer.speech_started"]))
        XCTAssertNil(ControlReplyEnvelope.decode(["type": "conversation.item.input_audio_transcription.completed"]))
    }

    func testIndependentStreamEndsAndOptionalSnapshots() throws {
        var wire = changing(.partDone, nested: "part") { $0["transcript"] = nil; $0["audio"] = bytes.base64EncodedString() }
        wire.swapAt(Slot.audioDone.rawValue, Slot.wordsDone.rawValue)
        wire.remove(at: Slot.words.rawValue)
        XCTAssertEqual(try steps(wire).last, .completed(pcm: bytes, itemID: "item_a"))
        wire = fixture()
        wire[Slot.words.rawValue]["delta"] = "Close "
        var rest = wire[Slot.words.rawValue]
        rest["delta"] = "closes this window."
        rest["event_id"] = "event_more"
        wire.insert(rest, at: Slot.wordsDone.rawValue)
        XCTAssertEqual(try steps(wire).last, .completed(pcm: bytes, itemID: "item_a"))
    }

    func testResponseNonceIdentityStatusAndFormatMustMatch() throws {
        for slot in [Slot.created, .done] {
            for metadata: Any? in [nil, NSNull(), [:], ["control_nonce": "stale_nonce"],
                                   ["control_nonce": String(repeating: "n", count: 129)]] {
                try assertRejected(changing(slot, nested: "response") { $0["metadata"] = metadata })
            }
            try assertRejected(changing(slot, nested: "response") { $0["id"] = nil })
            try assertRejected(changing(slot, nested: "response") { $0["conversation_id"] = "conv_not_isolated" })
            try assertRejected(changing(slot, nested: "response") { $0["output_modalities"] = ["text", "audio"] })
            try assertRejected(changing(slot, nested: "response") { $0["audio"] = ["output": ["format": ["type": "audio/pcmu"]]] })
            try assertRejected(changed(slot) { $0["response_id"] = "resp_other" })
        }
        for status: String? in [nil, "in_progress", "failed", "incomplete", "cancelled"] {
            try assertRejected(changing(.done, nested: "response") { $0["status"] = status })
        }
        try assertRejected(changing(.done, nested: "response") { $0["status_details"] = ["error": ["message": "fixture"]] })
        try assertRejected(changing(.done, nested: "response") { $0["id"] = "resp_other" })
    }

    func testOnlySingleAssistantAudioMessageMaySettle() throws {
        let finished = fixture()[Slot.itemDone.rawValue]["item"] as! Wire
        let canonical = finished["content"] as! [Wire]
        let tool: Wire = ["type": "function_call", "call_id": "call_a", "name": "not_permitted"]
        for output: [Wire] in [[], [tool], [finished, tool], [tool, finished], [finished, finished]] {
            try assertRejected(changing(.done, nested: "response") { $0["output"] = output })
        }
        let changes: [Wire] = [["id": "item_other"], ["role": "user"], ["type": "function_call"],
                               ["status": "incomplete"], ["status": NSNull()], ["content": []],
                               ["content": canonical + canonical], ["content": [["type": "output_text", "text": answer]]],
                               ["content": [["type": "output_audio"]]],
                               ["content": [["type": "output_audio", "transcript": answer, "text": "extra"]]],
                               ["content": [["type": "output_audio", "transcript": "Wrong."]]]]
        for updates in changes {
            let bad = finished.merging(updates) { _, v in v }
            try assertRejected(changed(.itemDone) { $0["item"] = bad })
            try assertRejected(changing(.done, nested: "response") { $0["output"] = [bad] })
        }
        try assertRejected(changed(.item) { $0["item"] = tool })
        try assertRejected(changing(.part, nested: "part") { $0["type"] = "input_audio" })
        try assertRejected(changing(.partDone, nested: "part") { $0["audio"] = "AAA=" })
        try assertRejected(changing(.partDone, nested: "part") { $0["transcript"] = "" })
        for kind in ["response.function_call_arguments.delta", "response.output_text.done", "response.unknown",
                     "error", "invalid_request_error"] {
            var wire = fixture()
            wire.insert(["type": kind, "event_id": "event_bad", "response_id": "resp_a",
                         "error": ["message": "must_not_escape"]], at: Slot.itemDone.rawValue)
            try assertRejected(wire)
        }
    }

    func testForeignOrMalformedCoordinatesAndDeltasFailClosed() throws {
        for slot in [Slot.part, .audio, .words, .audioDone, .wordsDone, .partDone] {
            for key in ["response_id", "item_id", "output_index", "content_index", "event_id"] {
                try assertRejected(changed(slot) { $0[key] = nil })
            }
            try assertRejected(changed(slot) { $0["response_id"] = "resp_other" })
            try assertRejected(changed(slot) { $0["item_id"] = "item_other" })
            for value: Any in [1, -1, false, "0", 0.4] {
                try assertRejected(changed(slot) { $0["output_index"] = value })
                try assertRejected(changed(slot) { $0["content_index"] = value })
            }
        }
        for slot in [Slot.item, .itemDone] {
            try assertRejected(changed(slot) { $0["output_index"] = 1 })
        }
        for invalid in ["", "invalid", "AAA=\n", "AAB=", "AA==", "AAECAw==\u{200B}"] {
            try assertRejected(changed(.audio) { $0["delta"] = invalid })
        }
        for invalid in ["", "Close", "Wrong.", String(repeating: "w", count: 513)] {
            try assertRejected(changed(.words) { $0["delta"] = invalid })
        }
        try assertRejected(changed(.wordsDone) { $0["transcript"] = answer + " " })
    }

    func testMissingDuplicateOrOutOfOrderEventsCannotRelease() throws {
        let valid = fixture()
        for i in valid.indices where i != Slot.words.rawValue {
            var wire = valid
            wire.remove(at: i)
            if i == Slot.done.rawValue {
                XCTAssertEqual(try steps(wire).last, .pending)
            } else {
                try assertRejected(wire)
            }
        }
        for i in valid.indices where i != Slot.done.rawValue {
            var wire = valid
            wire.insert(valid[i], at: i)
            try assertRejected(wire)
        }
        for slot in [Slot.created, .item, .part, .audioDone, .wordsDone, .partDone, .itemDone] {
            var wire = valid
            var repeated = valid[slot.rawValue]
            repeated["event_id"] = "fresh_id"
            wire.insert(repeated, at: slot.rawValue + 1)
            try assertRejected(wire)
        }
        for (a, b) in [(Slot.item, Slot.part), (.audio, .audioDone), (.words, .wordsDone),
                       (.audioDone, .partDone), (.partDone, .itemDone), (.itemDone, .done)] {
            var wire = valid
            wire.swapAt(a.rawValue, b.rawValue)
            try assertRejected(wire)
        }
    }

    func testCumulativeAudioAndFrameLimits() throws {
        let maximum = Data(repeating: 0, count: 384_000)
        var wire = changed(.audio) { $0["delta"] = maximum.base64EncodedString() }
        XCTAssertEqual(try steps(wire).last, .completed(pcm: maximum, itemID: "item_a"))
        var extra = fixture()[Slot.audio.rawValue]
        extra["event_id"] = "extra"
        wire.insert(extra, at: Slot.words.rawValue)
        try assertRejected(wire)
        try assertRejected(changed(.audio) { $0["delta"] = Data(repeating: 0, count: 384_002).base64EncodedString() })
        wire = fixture()
        let many: [Wire] = (0..<1024).map { i in
            extra.merging(["event_id": "extra_\(i)"]) { _, v in v }
        }
        wire.insert(contentsOf: many, at: Slot.words.rawValue)
        try assertRejected(wire)
    }
}
