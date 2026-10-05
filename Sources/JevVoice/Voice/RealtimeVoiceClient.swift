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
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "realtime")

    enum Event {
        case sessionStarted(id: String)
        case sessionUpdated
        case inputCommitted(itemID: String)
        case transcriptDelta(String)
        case transcriptDone(String, languages: [String])
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
    }

    enum Phase { case connecting, ready, closed }

    private(set) var phase: Phase = .connecting
    var onEvent: ((Event) -> Void)?

    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
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
                "description": "Control the user's Mac — open or quit apps, click, type, scroll, menus, multi-step tasks across apps. Call this for anything the user wants DONE on the machine. Pass the user's instruction verbatim, in the language they spoke. Returns STARTED immediately; a '[task outcome]' message with the verified result arrives later — never claim a task finished before it does.",
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
                "description": "Answer a question a running task asked the user — a yes/no confirmation, which window to use, or text it needs. Call this whenever the user is replying to something you asked, not giving a new instruction.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "answer": ["type": "string", "description": "The user's answer, verbatim — 'yes', 'no', a window title, or the text to use."]
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

        To act on the Mac, call computer_command with the user's instruction \
        verbatim — make the call your first output, before any speech; the \
        acknowledgement comes after it returns. Fill app when one is named \
        or obvious from the screenshot (for media pick the likely one — \
        Spotify, Music, the browser — don't spend a voice turn asking), and \
        literal_text with the content to type or search for — 'play Marvin's \
        Room by Drake' → literal_text "Marvin's Room Drake", not the whole \
        sentence. Repeat names, places, and titles exactly as the user said \
        them — never paraphrase (Yuba City stays Yuba City). \
        The tool returns STARTED the moment work begins — acknowledge in a few \
        words ("On it") and never claim it finished. The verified result \
        arrives later as a "[task outcome]" message; when it does, tell the \
        user plainly what happened — done, blocked, or what stopped it.

        When you see "[needs confirmation]" or "[question]" a task is waiting \
        on the user — ask it out loud in your own words, and when they answer, \
        call respond_to_task with what they said. Plain "yes"/"no" turns after \
        you asked a confirmation are answers, not new commands.

        For background or long-running work use delegate_to_agent. For \
        "cancel"/"stop"/"never mind" use cancel_task. For anything that \
        needs the live internet — news, facts, lookups — call web_lookup; \
        say a short beat first ("checking") since it takes a moment. For \
        questions deeper than the visible screen but answerable from what \
        you know, use send_to_higher_model.

        Keep replies to one or two sentences — this is voice. Answer in \
        whatever language the user speaks. If they ask how to do something, \
        explain briefly instead of acting. You may simply converse.
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
        try await send(["type": "session.update", "session": session])
        connectedAt = Date()
        phase = .ready
        Self.log.notice("realtime_connected model=\(model, privacy: .public)")
    }

    var isReady: Bool {
        phase == .ready && socket?.state == .running
    }

    func sendAudio(_ pcm: Data) async throws {
        guard isReady else { throw VoiceError("The realtime session is not connected.") }
        try await send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
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
    func deleteItem(itemID: String) async throws {
        try await send(["type": "conversation.item.delete", "item_id": itemID])
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw VoiceError("The realtime session is not connected.") }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func startReceiver(_ socket: URLSessionWebSocketTask) {
        receiver = Task { [weak self, weak socket] in
            while !Task.isCancelled {
                do {
                    guard let socket else { return }
                    let message = try await socket.receive()
                    guard let self, !Task.isCancelled else { return }
                    if case .string(let payload) = message {
                        for event in Self.decode(payload) { self.onEvent?(event) }
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    // A failed upgrade carries the HTTP status; a closed data
                    // phase carries the WS close code — surface both.
                    let status = (socket?.response as? HTTPURLResponse)?.statusCode
                    let close = socket?.closeCode.rawValue
                    Self.log.notice("realtime_socket_ended error=\(error.localizedDescription, privacy: .public) http=\(status ?? 0, privacy: .public) close=\(close ?? -1, privacy: .public)")
                    self.phase = .closed
                    if let status, status != 101 {
                        self.onEvent?(.failure("Realtime connection refused (HTTP \(status))."))
                    }
                    self.onEvent?(.closed)
                    return
                }
            }
        }
    }

    /// Parse one JSON frame into zero or more events. Kept static and pure so
    /// the contract stays unit-testable without a socket.
    static func decode(_ payload: String) -> [Event] {
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
        case "conversation.item.created":
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
            events.append(.responseDone)
            return events
        case "error", "invalid_request_error":
            let detail = (frame["error"] as? [String: Any])?["message"] as? String
                ?? frame["message"] as? String ?? "Realtime session error."
            return [.failure(detail)]
        default:
            return []
        }
    }

    func teardown() {
        phase = .closed
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }
}
