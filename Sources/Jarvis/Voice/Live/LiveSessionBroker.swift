import Foundation

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
/// install token. The response is OpenAI's own creation body, passed through,
/// and OpenAI's own errors (an over-long prompt, say) come back the same way.
struct HostedLiveSessions: LiveSessionCreating {
    let baseURL: URL
    let installToken: @Sendable () async throws -> String
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
        var request = URLRequest(url: baseURL.appending(path: "v1/live/sessions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await installToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: config.brokerBody(sdp: offer), options: [.sortedKeys])
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
