import Foundation

/// What Jarvis chooses for a Live session. The broker fixes everything else
/// (model, client delegation, no tools, store off, the speech wake policy).
struct LiveSessionConfig: Equatable, Sendable {
    struct Message: Equatable, Sendable {
        enum Role: String, Sendable { case developer, user, assistant }
        let role: Role
        let text: String
    }

    var instructions: String?
    var input: [Message] = []
    var voice = "marin"
    /// Seconds without a transcript before Live pauses into Standby (5–60).
    var idleTimeoutS = 8
    /// How much speech evidence wakes a paused session (0–1); nil is OpenAI's 0.5.
    var vadThreshold: Double?

    /// The JSON the broker's `POST /v1/live/sessions` accepts (#582).
    func brokerBody(sdp: String) throws -> Data {
        var body: [String: Any] = ["sdp": sdp, "idle_timeout_s": idleTimeoutS, "voice": voice]
        if let instructions { body["instructions"] = instructions }
        if let vadThreshold { body["vad_threshold"] = vadThreshold }
        if !input.isEmpty {
            body["input"] = input.map { message in
                let part = message.role == .assistant ? "output_text" : "input_text"
                return ["type": "message", "role": message.role.rawValue,
                        "content": [["type": part, "text": message.text]]] as [String: Any]
            }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// A created session: its id and the SDP answer for the peer connection.
struct LiveSessionAnswer: Equatable, Sendable {
    let id: String
    let sdp: String
}

/// Exchanges an SDP offer for a running Live session. In the app this is the
/// hosted broker, so the Mac never holds an OpenAI key.
protocol LiveSessionCreating: Sendable {
    func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer
}

struct LiveBrokerError: LocalizedError, Equatable {
    let status: Int
    let code: String?
    let message: String
    var errorDescription: String? { message }
}

/// \`POST /v1/live/sessions\` on the credential Worker (#582), authorised by the
/// install token. The response is OpenAI's own creation body, passed through.
struct HostedLiveSessions: LiveSessionCreating {
    let baseURL: URL
    let installToken: @Sendable () async throws -> String
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
        var request = URLRequest(url: baseURL.appending(path: "v1/live/sessions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await installToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try config.brokerBody(sdp: offer)
        request.timeoutInterval = 15
        let (data, response) = try await send(request)
        return try Self.answer(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Reads the 201 creation body, or the broker's or OpenAI's error body.
    static func answer(data: Data, status: Int) throws -> LiveSessionAnswer {
        struct Created: Decodable {
            struct Session: Decodable { let id: String }
            struct Transport: Decodable { let type: String; let sdp: String? }
            let session: Session
            let transport: Transport
        }
        struct Failure: Decodable {
            struct Detail: Decodable { let code: String?; let message: String }
            let error: Detail
        }
        guard (200..<300).contains(status) else {
            let detail = try? JSONDecoder().decode(Failure.self, from: data).error
            throw LiveBrokerError(status: status, code: detail?.code,
                                  message: detail?.message ?? "The voice service answered \(status).")
        }
        let created = try JSONDecoder().decode(Created.self, from: data)
        guard created.transport.type == "webrtc", let sdp = created.transport.sdp, !sdp.isEmpty else {
            throw LiveBrokerError(status: status, code: nil, message: "The voice service sent no WebRTC answer.")
        }
        return LiveSessionAnswer(id: created.session.id, sdp: sdp)
    }
}
