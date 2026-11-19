import CoreFoundation
import Foundation

struct ControlReplyEnvelope: Sendable {
    enum Step: Sendable, Equatable {
        case pending, created(String), completed(pcm: Data, itemID: String), rejected
    }

    struct Frame: Sendable {
        let responseID: String?
        let nonce: String?
        fileprivate let eventID: String?
        fileprivate let itemID: String?
        fileprivate let payload: Payload
    }

    fileprivate enum Payload: Sendable {
        case invalid, created, itemAdded, partAdded, audio(Data), audioDone
        case transcript(String), transcriptDone(String)
        case partDone(Snapshot), itemDone(Snapshot), done(Snapshot)
    }

    fileprivate struct Snapshot: Sendable {
        let transcript: String?
        let audio: Data?
    }

    private enum Phase { case start, created, item, streaming, partDone, itemDone, ended }
    private static let byteLimit = 384_000
    private static let transcriptLimit = 512
    private let nonce: String
    private let expectedAnswer: String
    private var phase = Phase.start
    private var responseID: String?
    private var itemID: String?
    private var seen = Set<String>()
    private var pcm = Data()
    private var transcriptBytes = 0
    private var audioDone = false
    private var transcriptDone = false

    init(nonce: String, expectedAnswer: String) {
        self.nonce = nonce
        self.expectedAnswer = expectedAnswer
        if Self.identifier(nonce) == nil || expectedAnswer.isEmpty || expectedAnswer.utf8.count > Self.transcriptLimit {
            phase = .ended
        }
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.utf8.count <= 128,
              s.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return s
    }

    private static func number(_ value: Any?, is expected: Int) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n == NSNumber(value: expected)
    }

    private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }

    private static func audioBytes(_ value: Any?) -> Data? {
        guard let s = value as? String, !s.isEmpty, s.utf8.count <= ((byteLimit + 2) / 3) * 4,
              let bytes = Data(base64Encoded: s), !bytes.isEmpty, bytes.count.isMultiple(of: 2),
              bytes.count <= byteLimit, bytes.base64EncodedString() == s else { return nil }
        return bytes
    }

    private static func snapshot(_ value: Any?, inMessage: Bool) -> Snapshot? {
        guard let part = value as? [String: Any], let kind = part["type"] as? String,
              kind == "output_audio" || (!inMessage && kind == "audio"),
              absent(part["text"]) else { return nil }
        let transcript = part["transcript"] as? String
        guard absent(part["transcript"]) || (transcript.map { $0.utf8.count <= transcriptLimit } == true) else {
            return nil
        }
        if absent(part["audio"]) || part["audio"] as? String == "" {
            return Snapshot(transcript: transcript, audio: nil)
        }
        guard let bytes = audioBytes(part["audio"]) else { return nil }
        return Snapshot(transcript: transcript, audio: bytes)
    }

    private static func responseSettingsOK(_ response: [String: Any]) -> Bool {
        guard absent(response["conversation_id"]) else { return false }
        if !absent(response["output_modalities"]) {
            guard let modalities = response["output_modalities"] as? [Any], modalities.count == 1,
                  modalities[0] as? String == "audio" else { return false }
        }
        guard !absent(response["audio"]) else { return true }
        guard let audio = response["audio"] as? [String: Any] else { return false }
        guard !absent(audio["output"]) else { return true }
        guard let output = audio["output"] as? [String: Any] else { return false }
        guard !absent(output["format"]) else { return true }
        guard let format = output["format"] as? [String: Any] else { return false }
        return format["type"] as? String == "audio/pcm" && (absent(format["rate"]) || number(format["rate"], is: 24_000))
    }

    static func decode(_ object: [String: Any]) -> Frame? {
        guard let type = object["type"] as? String,
              type.hasPrefix("response.") || object["response_id"] != nil || type == "error"
                || type == "invalid_request_error" else { return nil }
        let response = object["response"] as? [String: Any]
        let boundary = type == "response.created" || type == "response.done"
        let responseID = identifier(boundary ? response?["id"] : object["response_id"])
        let nonce = identifier((response?["metadata"] as? [String: Any])?["control_nonce"])
        let eventID = identifier(object["event_id"])
        let outerItem = identifier(object["item_id"])
        func frame(_ payload: Payload, item: String? = nil) -> Frame {
            Frame(responseID: responseID, nonce: nonce, eventID: eventID, itemID: item ?? outerItem, payload: payload)
        }
        guard eventID != nil, let id = responseID else { return frame(.invalid) }
        let isItem = type == "response.output_item.added" || type == "response.output_item.done"
        if boundary {
            guard let response, nonce != nil, responseSettingsOK(response),
                  object["output_index"] == nil, object["content_index"] == nil,
                  object["response_id"] == nil || identifier(object["response_id"]) == id else { return frame(.invalid) }
            if type == "response.created" {
                guard object["item_id"] == nil, absent(response["status"]) || response["status"] as? String == "in_progress",
                      absent(response["output"]) || (response["output"] as? [Any])?.isEmpty == true,
                      absent(response["status_details"]) else { return frame(.invalid) }
                return frame(.created)
            }
            guard response["status"] as? String == "completed" else { return frame(.invalid) }
            if !absent(response["status_details"]) {
                guard let details = response["status_details"] as? [String: Any], details["type"] as? String == "completed",
                      absent(details["reason"]), absent(details["error"]) else { return frame(.invalid) }
            }
        } else {
            guard object["response"] == nil, number(object["output_index"], is: 0),
                  isItem ? object["content_index"] == nil : (outerItem != nil && number(object["content_index"], is: 0))
            else { return frame(.invalid) }
        }

        if isItem || type == "response.done" {
            let rawItem: Any?
            if type == "response.done" {
                guard let output = response?["output"] as? [Any], output.count == 1 else { return frame(.invalid) }
                rawItem = output[0]
            } else {
                rawItem = object["item"]
            }
            guard let item = rawItem as? [String: Any], let id = identifier(item["id"]),
                  object["item_id"] == nil || outerItem == id,
                  item["type"] as? String == "message", item["role"] as? String == "assistant",
                  let content = item["content"] as? [Any] else { return frame(.invalid) }
            if type == "response.output_item.added" {
                guard content.isEmpty, absent(item["status"]) || item["status"] as? String == "in_progress" else {
                    return frame(.invalid)
                }
                return frame(.itemAdded, item: id)
            }
            guard item["status"] as? String == "completed", content.count == 1,
                  let part = snapshot(content[0], inMessage: true), part.transcript != nil else { return frame(.invalid) }
            return frame(isItem ? .itemDone(part) : .done(part), item: id)
        }

        switch type {
        case "response.content_part.added", "response.content_part.done":
            guard let part = snapshot(object["part"], inMessage: false) else { return frame(.invalid) }
            if type == "response.content_part.added" {
                guard part.audio == nil, (part.transcript ?? "").isEmpty else { return frame(.invalid) }
                return frame(.partAdded)
            }
            return frame(.partDone(part))
        case "response.output_audio.delta":
            guard let bytes = audioBytes(object["delta"]) else { return frame(.invalid) }
            return frame(.audio(bytes))
        case "response.output_audio.done":
            return frame(.audioDone)
        case "response.output_audio_transcript.delta", "response.output_audio_transcript.done":
            let delta = type == "response.output_audio_transcript.delta"
            guard let s = object[delta ? "delta" : "transcript"] as? String,
                  !s.isEmpty, s.utf8.count <= transcriptLimit else { return frame(.invalid) }
            return frame(delta ? .transcript(s) : .transcriptDone(s))
        default:
            return frame(.invalid)
        }
    }

    private func matches(_ part: Snapshot) -> Bool {
        (part.transcript.map { expectedAnswer.utf8.elementsEqual($0.utf8) } ?? true)
            && (part.audio.map { $0 == pcm } ?? true)
    }

    private mutating func reject() -> Step {
        phase = .ended
        pcm = Data()
        seen.removeAll()
        return .rejected
    }

    mutating func accept(_ frame: Frame) -> Step {
        guard phase != .ended, seen.count < 1_024, let eventID = frame.eventID, seen.insert(eventID).inserted,
              let response = frame.responseID, responseID == nil || responseID == response,
              itemID == nil || frame.itemID == itemID else { return reject() }
        switch (phase, frame.payload) {
        case (.start, .created) where frame.nonce == nonce:
            responseID = response
            phase = .created
            return .created(response)
        case (.created, .itemAdded):
            itemID = frame.itemID
            phase = .item
        case (.item, .partAdded):
            phase = .streaming
        case (.streaming, .audio(let bytes)) where !audioDone && bytes.count <= Self.byteLimit - pcm.count:
            pcm.append(bytes)
        case (.streaming, .transcript(let text)) where !transcriptDone:
            guard expectedAnswer.utf8.dropFirst(transcriptBytes).starts(with: text.utf8) else { return reject() }
            transcriptBytes += text.utf8.count
        case (.streaming, .audioDone) where !audioDone && !pcm.isEmpty:
            audioDone = true
        case (.streaming, .transcriptDone(let text)) where !transcriptDone:
            guard expectedAnswer.utf8.elementsEqual(text.utf8),
                  transcriptBytes == 0 || transcriptBytes == expectedAnswer.utf8.count else { return reject() }
            transcriptDone = true
        case (.streaming, .partDone(let part)) where audioDone && transcriptDone && matches(part):
            phase = .partDone
        case (.partDone, .itemDone(let part)) where matches(part):
            phase = .itemDone
        case (.itemDone, .done(let part)) where frame.nonce == nonce && matches(part):
            guard let itemID else { return reject() }
            phase = .ended
            let result = Step.completed(pcm: pcm, itemID: itemID)
            pcm = Data()
            seen.removeAll()
            return result
        default:
            return reject()
        }
        return .pending
    }
}
