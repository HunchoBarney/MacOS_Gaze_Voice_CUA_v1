import CryptoKit
import Darwin
import Foundation
import JevVoiceCore
import os

actor VoiceRemoteResponseBudget {
    private let url: URL
    private let authorizationID: String

    init(url: URL, authorizationID: String) throws {
        _ = try Self.load(url, authorizationID: authorizationID)
        self.url = url
        self.authorizationID = authorizationID
    }

    private static func load(_ url: URL, authorizationID: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard let object = value.object,
              value["schema_version"]?.integer == 1,
              value["id"]?.string == authorizationID,
              value["scope"]?.string == "p3-openai-realtime-fixed-text-no-desktop",
              value["user_selection"]?.string == "Authorize capped tests",
              let limit = value["maximum_responses"]?.integer, (1...8).contains(limit),
              let reserved = value["reserved_responses"]?.integer, (0...limit).contains(reserved),
              let requests = value["requests"]?.array, requests.count == reserved,
              case .number(let expiry)? = value["expires_at"],
              expiry.isFinite, expiry > Date().timeIntervalSince1970 else {
            throw VoiceError("remote_authorization_invalid_or_expired")
        }
        return object
    }

    func reserveResponse(caseID: String) throws -> String {
        guard ["safe-miss", "cancel", "stale-response", "outcome-only"].contains(caseID) else {
            throw VoiceError("remote_case_not_authorized")
        }
        let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VoiceError("remote_budget_lock_unavailable") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw VoiceError("remote_budget_in_use")
        }
        defer { flock(descriptor, LOCK_UN) }
        var object = try Self.load(url, authorizationID: authorizationID)
        guard let reserved = object["reserved_responses"]?.integer,
              let limit = object["maximum_responses"]?.integer, reserved < limit,
              var requests = object["requests"]?.array else {
            throw VoiceError("remote_response_budget_exhausted")
        }
        let id = UUID().uuidString
        requests.append(.object([
            "request_id": .string(id), "case_id": .string(caseID),
            "reserved_at": .number(Date().timeIntervalSince1970)
        ]))
        object["reserved_responses"] = .number(Double(reserved + 1))
        object["requests"] = .array(requests)
        try JSONEncoder().encode(JSONValue.object(object)).write(to: url, options: .atomic)
        return id
    }
}

enum VoiceRemoteLivePolicy {
    static let safeQuestion = "What is two plus two? Use the answer tool with text 4."
    static let cancelQuestion = "What is three plus three? Use the answer tool with text 6."
    static let oldQuestion = "What is five plus five? Use the answer tool with text 10."
    static let newQuestion = "What is four plus five? Use the answer tool with text 9."
    static let outcome = "The diagnostic arithmetic answer was received. No desktop action occurred."
    static let inputs = Set([safeQuestion, cancelQuestion, oldQuestion, newQuestion, outcome])

    static func validateInbound(_ value: JSONValue) throws {
        switch value {
        case .object(let fields):
            let type = fields["type"]?.string ?? ""
            let media = ["audio", "input_audio", "output_audio", "image", "image_url", "input_image", "output_image"]
            guard !media.contains(type), !type.contains("output_audio"), !type.contains("audio.delta") else {
                throw VoiceError("remote_incoming_media_forbidden")
            }
            for (key, child) in fields {
                if ["audio", "image", "image_url"].contains(key), child.string != nil {
                    throw VoiceError("remote_incoming_media_forbidden")
                }
                try validateInbound(child)
            }
        case .array(let values):
            for child in values { try validateInbound(child) }
        default: break
        }
    }

    static func validateHeldAnswer(_ frame: JSONValue) throws {
        let keys: Set<String> = ["type", "event_id", "response_id", "item_id", "output_index", "call_id", "name", "arguments"]
        guard let fields = frame.object, Set(fields.keys).isSubset(of: keys),
              frame["type"]?.string == "response.function_call_arguments.done",
              frame["name"]?.string == "answer", let arguments = frame["arguments"]?.string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)),
              let object = value.object, Set(object.keys) == ["text"],
              let text = value["text"]?.string, ["4", "6", "9", "10"].contains(text) else {
            throw VoiceError("remote_retained_frame_not_fixed_answer")
        }
    }

    static func opaque(_ value: JSONValue?) throws -> JSONValue {
        guard let value, value != .null else { return .null }
        guard let string = value.string, string.utf8.count <= 200,
              string.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            throw VoiceError("remote_opaque_identity_invalid")
        }
        return .string(string)
    }

    static func prepare(_ text: String, requestID: String? = nil, forceAnswer: Bool = false) throws -> String {
        guard text.utf8.count <= 65_536,
              var object = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).object,
              let type = object["type"]?.string else { throw VoiceError("remote_outbound_invalid") }
        switch type {
        case "session.update":
            guard var session = object["session"]?.object else { throw VoiceError("remote_session_invalid") }
            session["output_modalities"] = .array([.string("text")])
            object["session"] = .object(session)
        case "response.create":
            guard let requestID, !requestID.isEmpty else { throw VoiceError("remote_request_not_reserved") }
            var response = object["response"]?.object ?? [:]
            response["output_modalities"] = .array([.string("text")])
            response["max_output_tokens"] = .number(256)
            if forceAnswer, response["tool_choice"]?.string != "none" {
                response["tool_choice"] = .object(["type": .string("function"), "name": .string("answer")])
            }
            object["response"] = .object(response)
            object["event_id"] = .string(requestID)
        case "conversation.item.create":
            guard let item = object["item"], let itemType = item["type"]?.string else {
                throw VoiceError("remote_item_invalid")
            }
            if itemType == "function_call_output" {
                guard let output = item["output"]?.string,
                      let result = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)),
                      VoiceToolCatalog.validResult(result), result["status"]?.string == "completed",
                      result["task_id"] == .null, result["agent_id"] == .null,
                      let summary = result["summary"]?.string,
                      ["4", "6", "9", "10"].contains(summary.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw VoiceError("remote_non_answer_output_forbidden")
                }
            } else {
                guard itemType == "message", item["role"]?.string == "user",
                      let content = item["content"]?.array, content.count == 1,
                      content[0]["type"]?.string == "input_text",
                      let input = content[0]["text"]?.string, inputs.contains(input) else {
                    throw VoiceError("remote_media_or_text_forbidden")
                }
            }
        case "response.cancel", "conversation.item.delete":
            break
        default:
            throw VoiceError("remote_event_forbidden")
        }
        return String(decoding: try JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)
    }
}

final class VoiceRemoteMetadata: Sendable {
    private struct State: Sendable {
        var frames: [JSONValue] = []
        var bytes = 0
        var overflow = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let frameLimit: Int
    private let byteLimit: Int

    init(frameLimit: Int = 2048, byteLimit: Int = 512 * 1024) {
        self.frameLimit = frameLimit
        self.byteLimit = byteLimit
    }

    func record(_ envelope: RealtimeVoiceClient.WireEnvelope) {
        let identities = [envelope.responseID, envelope.inputItemID].compactMap { $0 }
            + envelope.events.compactMap { event -> String? in
                if case .functionCall(let id, _, _) = event { return id }
                return nil
            }
        guard envelope.kind.utf8.count <= 128, identities.allSatisfy({ $0.utf8.count <= 200 }) else {
            state.withLock { $0.overflow = true }
            return
        }
        let calls = envelope.events.compactMap { event -> JSONValue? in
            guard case .functionCall(let id, _, _) = event else { return nil }
            return .string(id)
        }
        let frame = JSONValue.object([
            "kind": .string(envelope.kind),
            "connection_generation": .string(envelope.connectionID.uuidString),
            "response_id": envelope.responseID.map(JSONValue.string) ?? .null,
            "input_item_id": envelope.inputItemID.map(JSONValue.string) ?? .null,
            "call_ids": .array(calls)
        ])
        let size = (try? JSONEncoder().encode(frame).count) ?? byteLimit + 1
        state.withLock {
            guard !$0.overflow, $0.frames.count < frameLimit, $0.bytes + size <= byteLimit else {
                $0.overflow = true
                return
            }
            $0.frames.append(frame)
            $0.bytes += size
        }
    }

    var snapshot: JSONValue {
        state.withLock { .object(["overflow": .bool($0.overflow), "frames": .array($0.frames)]) }
    }
}

actor VoiceRemoteLiveControl {
    struct Mode: Sendable {
        var caseID = "safe-miss"
        var stage = "safe"
        var holdCalls = false
        var forceAnswer = false
    }

    private var mode = Mode()
    private var sent: [JSONValue] = []
    private var bytes = 0
    private var overflow = false

    func configure(_ mode: Mode) { self.mode = mode }
    func currentMode() -> Mode { mode }
    func frames() -> [JSONValue] { sent }
    func hasOverflow() -> Bool { overflow }

    func record(_ frame: JSONValue, mode: Mode) throws {
        let record = JSONValue.object([
            "case_id": .string(mode.caseID), "stage": .string(mode.stage),
            "wire_id": frame["wire_id"] ?? .null,
            "kind": frame["type"] ?? .null, "request_id": frame["event_id"] ?? .null,
            "tools_disabled": .bool(frame["response"]?["tool_choice"]?.string == "none"),
            "text_only": .bool(frame["response"]?["output_modalities"]?.array == [.string("text")]),
            "function_output_call_id": frame["item"]?["type"]?.string == "function_call_output"
                ? try VoiceRemoteLivePolicy.opaque(frame["item"]?["call_id"]) : .null
        ])
        let size = try JSONEncoder().encode(record).count
        guard sent.count < 1024, bytes + size <= 256 * 1024 else {
            overflow = true
            throw VoiceError("remote_outbound_metadata_overflow")
        }
        sent.append(record)
        bytes += size
    }

    func recordReceived(_ frame: JSONValue, raw: String) throws {
        let record = JSONValue.object([
            "direction": .string("inbound"), "kind": frame["type"] ?? .null,
            "case_id": .string(mode.caseID), "stage": .string(mode.stage),
            "server_event_id": try VoiceRemoteLivePolicy.opaque(frame["event_id"]),
            "server_item_id": try VoiceRemoteLivePolicy.opaque(frame["item"]?["id"] ?? frame["item_id"]),
            "server_response_id": try VoiceRemoteLivePolicy.opaque(frame["response"]?["id"] ?? frame["response_id"]),
            "server_call_id": try VoiceRemoteLivePolicy.opaque(frame["call_id"]),
            "raw_frame_sha256": .string(SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined())
        ])
        let size = try JSONEncoder().encode(record).count
        guard sent.count < 1024, bytes + size <= 256 * 1024 else {
            overflow = true
            throw VoiceError("remote_transport_metadata_overflow")
        }
        sent.append(record)
        bytes += size
    }

    func recordFailure(stage: String, cancelled: Bool) {
        guard sent.count < 1024, bytes + 512 <= 256 * 1024 else { overflow = true; return }
        sent.append(.object(["kind": .string("trial.failure"), "stage": .string(stage),
                             "cancelled": .bool(cancelled), "case_id": .string(mode.caseID)]))
        bytes += 512
    }

    func recordClosed(wireID: String, socketCancelled: Bool) {
        guard sent.count < 1024, bytes + 512 <= 256 * 1024 else { overflow = true; return }
        sent.append(.object([
            "kind": .string("transport.closed"), "wire_id": .string(wireID),
            "socket_cancel_requested": .bool(socketCancelled), "session_invalidated": .bool(true)
        ]))
        bytes += 512
    }
}

actor VoiceRemoteLiveWire: RealtimeVoiceWire {
    nonisolated let identity = UUID().uuidString
    private let session: URLSession
    private let socket: URLSessionWebSocketTask?
    private let budget: VoiceRemoteResponseBudget
    private let control: VoiceRemoteLiveControl
    private var closed = false
    private var closeRecorded = false
    private var heldOnce = false
    private var heldWaiter: CheckedContinuation<Void, Error>?
    private(set) var heldPayload: String?

    init(request: URLRequest, budget: VoiceRemoteResponseBudget, control: VoiceRemoteLiveControl) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        self.session = session
        self.budget = budget
        self.control = control
        if request.url?.scheme == "wss", request.url?.host == "api.openai.com",
           request.url?.path == "/v1/realtime" {
            let socket = session.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
        } else {
            self.socket = nil
        }
    }

    func send(_ text: String) async throws {
        var stage = "outbound-parse"
        do {
            guard !closed, let socket else { throw VoiceError("remote_wire_closed") }
            let mode = await control.currentMode()
            let input = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            stage = "response-budget"
            let requestID = input["type"]?.string == "response.create"
                ? try await budget.reserveResponse(caseID: mode.caseID) : nil
            stage = "outbound-policy"
            let output = try VoiceRemoteLivePolicy.prepare(text, requestID: requestID, forceAnswer: mode.forceAnswer)
            let frame = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
            stage = "outbound-metadata"
            var recorded = frame.object ?? [:]
            recorded["wire_id"] = .string(identity)
            try await control.record(.object(recorded), mode: mode)
            guard !closed else { throw CancellationError() }
            stage = "network-send"
            try await socket.send(.string(output))
        } catch {
            await control.recordFailure(stage: stage, cancelled: error is CancellationError)
            await close()
            throw VoiceError("remote_wire_send_failed")
        }
    }

    func receive() async throws -> String {
        var stage = "network-receive"
        do {
            guard !closed, let socket else { throw VoiceError("remote_wire_closed") }
            let payload: String
            switch try await socket.receive() {
            case .string(let text): payload = text
            case .data(let data):
                guard let text = String(data: data, encoding: .utf8) else {
                    throw VoiceError("remote_binary_frame_forbidden")
                }
                payload = text
            @unknown default: throw VoiceError("remote_unknown_frame")
            }
            stage = "inbound-byte-bound"
            guard payload.utf8.count <= 64 * 1024 else { throw VoiceError("remote_frame_overflow") }
            let frame = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
            stage = "inbound-media-policy"
            try VoiceRemoteLivePolicy.validateInbound(frame)
            guard let kind = frame["type"]?.string, kind.utf8.count <= 128 else {
                throw VoiceError("remote_event_kind_invalid")
            }
            stage = "inbound-metadata"
            try await control.recordReceived(frame, raw: payload)
            let mode = await control.currentMode()
            if mode.holdCalls, !heldOnce, kind == "response.function_call_arguments.done" {
                stage = "retained-answer-policy"
                try VoiceRemoteLivePolicy.validateHeldAnswer(frame)
                heldOnce = true
                heldPayload = payload
                stage = "held-receive"
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if closed { continuation.resume(throwing: CancellationError()) }
                    else { heldWaiter = continuation }
                }
            }
            guard !closed else { throw CancellationError() }
            return payload
        } catch {
            await control.recordFailure(stage: stage, cancelled: error is CancellationError)
            await close()
            throw VoiceError("remote_wire_receive_failed")
        }
    }

    func releaseHeld() {
        let waiter = heldWaiter
        heldWaiter = nil
        waiter?.resume()
    }

    func isClosed() -> Bool { closed && closeRecorded }

    func close() async {
        guard !closed else { return }
        closed = true
        let waiter = heldWaiter
        heldWaiter = nil
        waiter?.resume(throwing: CancellationError())
        socket?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        await control.recordClosed(wireID: identity, socketCancelled: socket != nil)
        closeRecorded = true
    }
}
