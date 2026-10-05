import Foundation
import OSLog

/// Thin WebSocket client for the OpenAI Realtime API — the speech-to-speech
/// lane Clicky uses (theirs sits behind a session-minting proxy; we hold the
/// socket directly with the user's API key).
///
/// Contract (verified against the Realtime conversations guide):
///   connect  → wss://api.openai.com/v1/realtime?model=<model>, Bearer auth
///   config   → session.update { session: { type:"realtime", audio:{input…,output…} } }
///   talk     → input_audio_buffer.append {audio: base64 pcm16/24k}
///   turn end → input_audio_buffer.commit then response.create
///   barge-in → response.cancel + conversation.item.truncate + stop playback
///   tools    → response.done carries output[] function_call items; results go
///              back as conversation.item.create function_call_output + response.create
@MainActor
final class RealtimeVoiceClient {
    private nonisolated static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "realtime")

    enum Event {
        case sessionStarted(id: String)
        case sessionUpdated
        case inputCommitted(itemID: String)
        case transcriptDelta(String)
        case transcriptDone(String, languages: [String])
        case transcriptFailed(String)
        case speechStarted
        case speechStopped
        case outputAudio(Data, itemID: String)
        case outputAudioDone(itemID: String)
        case assistantDelta(String)
        case assistantDone(String)
        case functionCall(callID: String, name: String, arguments: String)
        case itemCreated(id: String, isImage: Bool)
        case responseDone
        case closed
        case failure(String)
        /// A request the server rejected but the session survived — bad
        /// item ids, deletes of gone items, shape nits. Log-worthy, never
        /// worth killing the turn over.
        case warning(String)
    }

    enum Phase { case connecting, ready, closed }

    private(set) var phase: Phase = .connecting
    /// Called off-actor from the detached receive loop — audio events
    /// must never queue behind MainActor. Written once before connect().
    nonisolated(unsafe) var onEvent: ((Event) -> Void)?

    private let urlSession: URLSession
    /// nonisolated so mic frames can send without a MainActor hop — any
    /// UI stall would otherwise land in the stream as an audible gap.
    /// Mutated only on the actor (connect/teardown); a stale read just
    /// fails its send.
    nonisolated(unsafe) private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private(set) var connectedAt: Date?

    init(urlSession: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3600
        self.urlSession = urlSession ?? URLSession(configuration: configuration)
    }

    /// Tools the realtime model may call. Each runs locally — the tool surface
    /// is our execution spine. computer_command returns the moment the task is
    /// accepted; the real outcome arrives later as a `[task outcome]` message.
    static var toolDefinitions: [[String: Any]] {
        [
            [
                "type": "function",
                "name": "computer_command",
                "description": "Control the user's Mac — open or quit apps, click, type, scroll, menus, multi-step tasks across apps. Call this for anything the user wants DONE on the machine. Pass the user's instruction verbatim, in the language they spoke. Returns JSON — your pre-call beat was the acknowledgement, so a \"started\" status means stay quiet; voice the \"say\" text verbatim for every other status. A '{\"kind\":\"task_outcome\"}' message with the verified result arrives later — never claim a task finished before it does.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "instruction": ["type": "string", "description": "The user's instruction, verbatim."],
                        "app": ["type": "string", "description": "The app to act in, when the user named one or the screenshot shows one clearly."],
                        "literal_text": ["type": "string", "description": "Exact text to type, when the user dictated what to write. Do not paraphrase it."]
                    ],
                    "required": ["instruction"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "respond_to_task",
                "description": "Answer a question a running task asked the user — a yes/no confirmation, which window to use, or text it needs. Call this whenever the user is replying to something you asked, not giving a new instruction. When more than one task is waiting for an answer, pass 'task' to say which one this answer is for.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "answer": ["type": "string", "description": "The user's answer, verbatim — 'yes', 'no', a window title, or the text to use."],
                        "task": ["type": "string", "description": "Which waiting task this answer is for, when several are parked — a word from the task's request, the app name, or an ordinal like 'first' or 'second'."]
                    ],
                    "required": ["answer"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "delegate_to_agent",
                "description": "Hand a task to a persistent background agent — for work that runs a while, spans tools, or the user wants delegated ('have an agent do X', 'ask my researcher to…'). Agents keep working after the task starts and can be messaged again later.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "task": ["type": "string", "description": "What the agent should do, verbatim or expanded into a clear brief."],
                        "agent": ["type": "string", "description": "Name of an existing agent the user referred to, if any."],
                        "name": ["type": "string", "description": "Name for a new agent, when the user wants a new one."],
                        "role": ["type": "string", "description": "Role for a new agent, e.g. 'researcher'."],
                        "description": ["type": "string", "description": "What a new agent is for."]
                    ],
                    "required": ["task"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "cancel_task",
                "description": "Stop a running task — 'cancel that', 'stop', 'never mind'. Call it even mid-task when the user wants the work stopped.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "hint": ["type": "string", "description": "Which task to stop, when several are running or the user named one."]
                    ],
                    "required": [],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "web_lookup",
                "description": "Look something up on the live internet — news, facts, prices, weather, scores, documentation, anything that may have changed recently or that you don't know. Use it whenever the answer needs the web rather than memory or the screen.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "question": ["type": "string", "description": "The question to look up, self-contained."]
                    ],
                    "required": ["question"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "send_to_higher_model",
                "description": "Ask a stronger model a question that needs more than the visible screen — documents whose content is scrolled off, longer reasoning, or anything you can't answer confidently from the screenshot. The screenshot is included for it.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "question": ["type": "string", "description": "The question to answer, with any needed context inline."]
                    ],
                    "required": ["question"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    static let instructions = """
        You are Jev, a fast voice interface for this Mac. The user holds a key, \
        speaks, and releases — each turn is one instruction, question, or answer. \
        A screenshot of their screen is attached to most turns; it shows only \
        what is visible right now. Answer questions about the screen directly \
        from it — no tool needed.

        You are terse — every word is heard aloud. Never narrate, recap, \
        greet, apologise, or add pleasantries. Whenever any tool result or \
        pushed message carries a "say" field, that text is your ENTIRE \
        spoken reply — nothing before it, nothing after it. When nothing \
        carries "say", answer in one sentence; two at most, and only when \
        the user asked for an explanation.

        To act on the Mac, speak one short beat — five words or fewer \
        ("On it,", "Opening it", "Doing that") — and call computer_command \
        in the same breath, with the user's instruction verbatim. That beat \
        IS the acknowledgement: when the tool returns status "started" you \
        say nothing more. Fill app when one is \
        named or obvious from the screenshot (for media pick the likely one — \
        Spotify, Music, the browser — don't spend a voice turn asking), and \
        literal_text with the content to type or search for — 'play Marvin's \
        Room by Drake' → literal_text "Marvin's Room Drake", not the whole \
        sentence. Repeat names, places, and titles exactly as the user said \
        them — never paraphrase (Yuba City stays Yuba City).

        Tool results are JSON and carry a "say" field: voice the say text \
        VERBATIM, word for word — it is the acknowledgement the task \
        computed for you, and it is the whole reply. If a tool result has \
        no "say" it carries content the user asked for — answer with it \
        plainly, one sentence preferred.

        Later messages can arrive between your turns: \
        {"kind":"task_outcome"} carries the verified result of work you \
        started — voice its "say" verbatim and nothing else; \
        {"kind":"task_question"} means a task is waiting on the user — ask \
        its "say" verbatim, and when they answer call respond_to_task with \
        what they said. Plain "yes"/"no" turns after you asked a \
        confirmation are answers, not new commands. Never claim a task \
        finished before its outcome arrives.

        Messages starting with [context] are injected system notes — local \
        time, the active app, what's waiting — they are facts about now, not \
        the user's words. Use them silently; never read them aloud.

        For background or long-running work use delegate_to_agent — the \
        result's "say" is the whole reply; never also answer the delegated \
        request yourself. For "cancel"/"stop"/"never mind" use cancel_task. \
        For anything that needs the live internet — news, facts, lookups — \
        call web_lookup; say a short beat first ("checking") since it takes \
        a moment. For questions deeper than the visible screen but answerable \
        from what you know, use send_to_higher_model.

        Keep replies to one sentence — two at most, this is voice. Answer \
        in whatever language the user speaks. If they ask how to do \
        something, explain briefly instead of acting. You may simply \
        converse — briefly.
        """

    /// Connect and configure. Resolves once the server confirms the session
    /// update — the socket is then warm for immediate audio streaming.
    func connect(apiKey: String, model: String = "gpt-realtime-2.1",
                 voice: String = "marin") async throws {
        teardown()
        phase = .connecting
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = urlSession.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        startReceiver(socket)
        let session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    // Push-to-talk: Fn is the gate, not server VAD — a release
                    // commits instantly instead of waiting on silence timeout.
                    "turn_detection": NSNull(),
                    "transcription": ["model": "gpt-4o-transcribe"]
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": voice
                ]
            ],
            "instructions": Self.instructions,
            "tools": Self.toolDefinitions,
            "tool_choice": "auto"
        ]
        // Readiness means the server CONFIRMED the session — a rejected
        // session.update used to leave phase=.ready while tools/turn-detection
        // silently ran server defaults. Resumed on .sessionUpdated; an error
        // or socket close while pending fails the connect instead.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            sessionReady = c
            Task { [weak self] in
                do { try await self?.send(["type": "session.update", "session": session]) }
                catch { self?.failSessionReady(error) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.failSessionReady(VoiceError("The realtime session was not confirmed."))
            }
        }
        connectedAt = Date()
        phase = .ready
        startKeepalive()
        Self.log.notice("realtime_connected model=\(model, privacy: .public)")
    }

    /// The socket has no application-level heartbeat: an idle hold-free
    /// stretch (the app open, Fn untouched) lets NATs and intermediaries
    /// drop the wire silently — the next press then commits audio into a
    /// dead session. A WS ping every 25s keeps the path alive; a pong
    /// failure surfaces through the ordinary receive loop's close.
    private var keepalive: Task<Void, Never>?
    private func startKeepalive() {
        keepalive?.cancel()
        keepalive = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                guard self != nil else { return }
                guard let socket = self?.socket, socket.state == .running else { continue }
                socket.sendPing { _ in }
            }
        }
    }

    private var sessionReady: CheckedContinuation<Void, Error>?

    private func confirmSessionReady() {
        let c = sessionReady; sessionReady = nil
        c?.resume()
    }

    private func failSessionReady(_ error: Error) {
        let c = sessionReady; sessionReady = nil
        c?.resume(throwing: error)
    }

    var isReady: Bool {
        phase == .ready && socket?.state == .running
    }

    /// Mic frames take the hottest path in the app — no MainActor hop,
    /// no JSONSerialization, just the base64 append straight onto the
    /// wire. The socket tolerates sends from any thread; a torn-down one
    /// fails the send, which the pump turns into a capture failure.
    nonisolated func sendAudio(_ pcm: Data) async throws {
        guard let socket else { throw VoiceError("The realtime session is not connected.") }
        let frame = "{\"type\":\"input_audio_buffer.append\",\"audio\":\""
            + pcm.base64EncodedString() + "\"}"
        try await socket.send(.string(frame))
    }

    func commitAudio() async throws { try await send(["type": "input_audio_buffer.commit"]) }
    func clearAudio() async throws { try await send(["type": "input_audio_buffer.clear"]) }
    func requestResponse() async throws { try await send(["type": "response.create"]) }
    func cancelResponse() async throws { try await send(["type": "response.cancel"]) }

    func truncate(itemID: String, audioEndMs: Int) async throws {
        try await send([
            "type": "conversation.item.truncate",
            "item_id": itemID,
            "content_index": 0,
            "audio_end_ms": audioEndMs
        ])
    }

    func sendFunctionOutput(callID: String, output: String) async throws {
        try await send([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": output]
        ])
    }

    func sendText(_ text: String) async throws {
        try await send([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user",
                     "content": [["type": "input_text", "text": text]]]
        ])
    }

    /// Attach a screen image the model can look at this turn — the Clicky
    /// "screenshot rides with every turn" mechanism.
    func sendImage(jpegBase64: String, caption: String? = nil) async throws {
        var content: [[String: Any]] = []
        if let caption {
            content.append(["type": "input_text", "text": caption])
        }
        content.append(["type": "input_image",
                        "image_url": "data:image/jpeg;base64,\(jpegBase64)"])
        try await send([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user", "content": content]
        ])
    }

    /// Remove a conversation item — used for keep-latest-1 screenshot hygiene
    /// so old images stop re-billing and diluting attention every turn.
    /// Per-turn context injection — Clicky's `submitContextNote`. A small
    /// user-role note carrying facts about right now (local time, active
    /// app, what's waiting); instructions tell the model to use it silently.
    /// The previous turn's note is deleted first so stale context can't
    /// accumulate into a contradictory stack. Returns the item id — keep it
    /// and pass it back as `replacing` on the next turn.
    @discardableResult
    func sendContextNote(_ text: String, replacing priorItemID: String? = nil) async throws -> String {
        if let priorItemID { try? await deleteItem(itemID: priorItemID) }
        let itemID = Self.contextItemID()
        try await send([
            "type": "conversation.item.create",
            "item": [
                "id": itemID,
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]]
            ]
        ])
        return itemID
    }

    /// item.id caps at 32 chars server-side — a full UUID string (36+4)
    /// got the whole session killed with a validation error. Keep it at
    /// exactly 32.
    nonisolated static func contextItemID() -> String {
        "ctx-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(28)
    }

    func deleteItem(itemID: String) async throws {
        try await send(["type": "conversation.item.delete", "item_id": itemID])
    }

    /// nonisolated so control sends don't occupy the main thread — the
    /// release→response.create window already spends its latency on the
    /// wire. Ordering still comes from each caller awaiting its own send.
    nonisolated private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw VoiceError("The realtime session is not connected.") }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Runs receive + JSON decode off-actor: every inbound frame used to
    /// resume on MainActor, so one busy main thread stalled the whole
    /// event stream — including the audio deltas feeding the speaker.
    private func startReceiver(_ socket: URLSessionWebSocketTask) {
        receiver = Task.detached { [weak self, socket] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, !Task.isCancelled else { return }
                    if case .string(let payload) = message {
                        for event in Self.decode(payload) {
                            if case .sessionUpdated = event { await self.confirmSessionReady() }
                            if case .closed = event { await self.failSessionReady(VoiceError("The realtime session closed.")) }
                            self.onEvent?(event)
                        }
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    // A failed upgrade carries the HTTP status; a closed data
                    // phase carries the WS close code — surface both.
                    let status = (socket.response as? HTTPURLResponse)?.statusCode
                    let close = socket.closeCode.rawValue
                    Self.log.notice("realtime_socket_ended error=\(error.localizedDescription, privacy: .public) http=\(status ?? 0, privacy: .public) close=\(close, privacy: .public)")
                    await self.failSessionReady(error)
                    await self.socketDidClose(httpStatus: status)
                    return
                }
            }
        }
    }

    private func socketDidClose(httpStatus status: Int?) {
        phase = .closed
        if let status, status != 101 {
            onEvent?(.failure("Realtime connection refused (HTTP \(status))."))
        }
        onEvent?(.closed)
    }

    /// Parse one JSON frame into zero or more events. Kept static and pure so
    /// the contract stays unit-testable without a socket — and nonisolated
    /// so the receive loop never hops onto MainActor to decode.
    nonisolated static func decode(_ payload: String) -> [Event] {
        guard let data = payload.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = frame["type"] as? String else { return [] }
        switch type {
        case "session.created":
            let id = (frame["session"] as? [String: Any])?["id"] as? String ?? ""
            return [.sessionStarted(id: id)]
        case "session.updated":
            return [.sessionUpdated]
        case "input_audio_buffer.committed":
            return [.inputCommitted(itemID: frame["item_id"] as? String ?? "")]
        case "input_audio_buffer.speech_started":
            return [.speechStarted]
        case "input_audio_buffer.speech_stopped":
            return [.speechStopped]
        case "conversation.item.input_audio_transcription.delta":
            return [.transcriptDelta(frame["delta"] as? String ?? "")]
        case "conversation.item.input_audio_transcription.completed":
            let languages = (frame["languages"] as? [[String: Any]])?.compactMap { $0["code"] as? String } ?? []
            return [.transcriptDone(frame["transcript"] as? String ?? "", languages: languages)]
        case "conversation.item.input_audio_transcription.failed":
            // The transcript died but the model still heard the audio — the
            // turn can succeed display-less. A distinct event, not .failure:
            // killing the capture over a lost caption is wrong.
            let detail = (frame["error"] as? [String: Any])?["message"] as? String ?? "Transcription failed."
            return [.transcriptFailed(detail)]
        case "response.output_audio.delta":
            guard let delta = frame["delta"] as? String,
                  let pcm = Data(base64Encoded: delta) else { return [] }
            return [.outputAudio(pcm, itemID: frame["item_id"] as? String ?? "")]
        case "response.output_audio.done":
            return [.outputAudioDone(itemID: frame["item_id"] as? String ?? "")]
        case "response.output_audio_transcript.delta":
            return [.assistantDelta(frame["delta"] as? String ?? "")]
        case "response.output_audio_transcript.done":
            return [.assistantDone(frame["transcript"] as? String ?? "")]
        case "conversation.item.created", "conversation.item.added":
            // GA canonical lifecycle is .added→.done; .created is the
            // backward-compat alias — decode both, the lane dedupes by id.
            let item = frame["item"] as? [String: Any]
            let hasImage = (item?["content"] as? [[String: Any]])?.contains {
                $0["type"] as? String == "input_image"
            } ?? false
            return [.itemCreated(id: item?["id"] as? String ?? "", isImage: hasImage)]
        case "response.function_call_arguments.done":
            return [.functionCall(callID: frame["call_id"] as? String ?? "",
                                  name: frame["name"] as? String ?? "",
                                  arguments: frame["arguments"] as? String ?? "")]
        case "response.done":
            // Function calls are authoritative in the output array; the
            // arguments.done event may arrive earlier — collect both and let
            // the lane dedupe by call_id. responseDone goes LAST so the lane's
            // pendingCalls is populated before it decides the turn ended.
            var events: [Event] = []
            let output = (frame["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? []
            for item in output where item["type"] as? String == "function_call" {
                events.append(.functionCall(callID: item["call_id"] as? String ?? "",
                                            name: item["name"] as? String ?? "",
                                            arguments: item["arguments"] as? String ?? ""))
            }
            // A failed/incomplete response carries the real reason in
            // status_details — swallowing it reads as a clean (silent) turn
            // end. `cancelled` stays silent: that's our own barge-in.
            if let status = (frame["response"] as? [String: Any])?["status"] as? String,
               status == "failed" || status == "incomplete" {
                let details = (frame["response"] as? [String: Any])?["status_details"] as? [String: Any]
                let reason = (details?["error"] as? [String: Any])?["message"] as? String
                    ?? details?["reason"] as? String ?? "response \(status)"
                events.append(.failure("The voice reply \(status == "failed" ? "failed" : "was cut short"): \(reason)."))
            }
            events.append(.responseDone)
            return events
        case "error", "invalid_request_error":
            let error = frame["error"] as? [String: Any] ?? frame
            let detail = error["message"] as? String ?? ""
            let text = detail.isEmpty ? "Realtime session error." : detail
            // Session-fatal errors announce themselves by type/code — every
            // other error frame is a rejected request on a live socket (an
            // invalid item.id once killed the whole session via .failure).
            let type = error["type"] as? String ?? ""
            let code = error["code"] as? String ?? ""
            let fatal = type.contains("session") || code.contains("session")
            return [fatal ? .failure(text) : .warning(text)]
        default:
            return []
        }
    }

    func teardown() {
        phase = .closed
        // A connect() suspended on session confirmation would otherwise wait
        // out its 10s timeout — teardown is the definitive answer it needs.
        failSessionReady(VoiceError("The realtime session closed."))
        keepalive?.cancel(); keepalive = nil
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }
}
