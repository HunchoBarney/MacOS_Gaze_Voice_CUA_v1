import Foundation

public enum JevError: Error, LocalizedError {
    case http(status: Int, body: String)
    case transport(Error)
    case decoding(Error)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "Jev API error \(status): \(body)"
        case .transport(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let error):
            return "Failed to decode Jev response: \(error.localizedDescription)"
        }
    }
}

public final class JevClient: Sendable {
    public let apiKey: String
    public let baseURL: URL
    public let model: String
    private let session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!,
        model: String = "jev-latest",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    @discardableResult
    public func systemOne<State: Encodable>(
        state: State,
        questions: [String: Question],
        assets: [String: JevImageAsset]? = nil
    ) async throws -> (response: SystemOneResponse, latencyMs: Double) {
        let images = assets?.isEmpty == false ? assets : nil
        if questions.values.contains(where: \.requiresImage), images == nil {
            throw JevVisionError.missingImage
        }
        if let images {
            let textBody = try JSONEncoder().encode(
                SystemOneRequest(model: model, state: state, questions: questions))
            let object = try JSONSerialization.jsonObject(with: textBody) as? [String: Any]
            func strings(in value: Any) -> [String] {
                if let text = value as? String { return [text] }
                if let array = value as? [Any] { return array.flatMap { strings(in: $0) } }
                if let map = value as? [String: Any] { return map.values.flatMap { strings(in: $0) } }
                return []
            }
            var references = strings(in: object?["state"] as Any)
            for question in (object?["questions"] as? [String: [String: Any]] ?? [:]).values {
                references += strings(in: question["instructions"] as Any)
                references += strings(in: question["criteria"] as Any)
            }
            guard images.keys.allSatisfy({ reference in
                !reference.isEmpty && references.contains(where: { $0.contains(reference) })
            }) else { throw JevVisionError.unreferencedAsset }
        }
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        // Per-step judgments sit inside a voice hold: a hung request must
        // bound out fast. There is no retry on this path — the drive loop
        // settles a thrown call as a blocked step — so 8s is the whole
        // stall, down from the old 20s default.
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if images != nil {
            request.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        }
        request.httpBody = try JSONEncoder().encode(
            SystemOneRequest(model: model, state: state, questions: questions, assets: images)
        )
        if images != nil, (request.httpBody?.count ?? 0) > 32 * 1024 * 1024 {
            throw JevVisionError.requestTooLarge
        }

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JevError.transport(error)
        }
        let latencyMs = Date().timeIntervalSince(start) * 1000

        guard let http = response as? HTTPURLResponse else {
            throw JevError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw JevError.http(status: http.statusCode, body: body)
        }
        do {
            let decoded = try JSONDecoder().decode(SystemOneResponse.self, from: data)
            return (decoded, latencyMs)
        } catch {
            throw JevError.decoding(error)
        }
    }
}
