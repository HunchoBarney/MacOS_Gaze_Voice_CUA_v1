import Foundation
import JarvisCore

/// A small client for GPT-6.1 Terra on OpenAI's Responses API: text and
/// in-memory PNGs in, one JSON object out, constrained by a strict JSON
/// schema. Requests set `store: false`, so OpenAI keeps nothing. Built to be
/// shared: screen questions use it today and KAR-43's screen agents can
/// take it as is.
///
/// The key comes from a closure (`Config.openAIAPIKey` in the app: the
/// `OPENAI_API_KEY` environment variable, then Keychain) and is only ever
/// put in the `Authorization` header. Nothing here logs a request or a
/// response body.
struct TerraClient: Sendable {
    static let model = "gpt-6.1-terra"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Effort: String, Sendable {
        case none, low, medium, high
    }

    struct Request: Sendable {
        /// The system-level instructions: who Terra is answering and how.
        var instructions: String
        /// The user turn: the question plus any text context.
        var text: String
        /// PNG bytes, sent inline as data URLs. Never a file or a link.
        var images: [Data] = []
        var schemaName: String
        /// A JSON Schema object; strict mode needs every property listed in
        /// `required` and `additionalProperties: false`.
        var schema: JSONValue
        var effort: Effort = .low
        var maxOutputTokens = 1_000
    }

    enum Failure: Error, LocalizedError, Equatable {
        case missingKey
        case http(status: Int, message: String)
        case refused(String)
        case incomplete(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add an OpenAI API key in Jarvis settings to ask about pictures on screen."
            case .http(let status, let message): return "OpenAI returned \(status): \(message)"
            case .refused(let why): return "The model declined: \(why)"
            case .incomplete(let reason): return "The answer was cut off (\(reason))."
            case .malformed: return "OpenAI returned an answer Jarvis couldn't read."
            }
        }
    }

    /// Tokens one response billed, as OpenAI reported them. Cached input is
    /// part of `input`; reasoning is part of `output`.
    struct Usage: Sendable, Equatable {
        var input = 0
        var cached = 0
        var output = 0

        init(input: Int = 0, cached: Int = 0, output: Int = 0) {
            self.input = input
            self.cached = cached
            self.output = output
        }

        init?(_ response: JSONValue) {
            guard let usage = response["usage"] else { return nil }
            input = usage["input_tokens"]?.integer ?? 0
            cached = usage["input_tokens_details"]?["cached_tokens"]?.integer ?? 0
            output = usage["output_tokens"]?.integer ?? 0
        }

        /// Dollars at Terra 6.1 list prices: $1 per million input tokens,
        /// $0.05 cached and $5 output. Uncached input is priced at the
        /// 1.25x cache-write rate, so this never undercounts.
        var dollars: Double {
            (Double(max(0, input - cached)) * 1.25 + Double(cached) * 0.05 + Double(output) * 5) / 1_000_000
        }
    }

    let apiKey: @Sendable () -> String?
    var transport: Transport = { try await URLSession.shared.data(for: $0) }
    var timeout: TimeInterval = 20
    /// Called once per answered request with what it billed, before the
    /// answer is read, so a refusal or a cut-off still counts.
    var onUsage: (@Sendable (Usage) -> Void)?

    /// Sends one request and returns the JSON object Terra produced.
    func respond(_ request: Request) async throws -> JSONValue {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw Failure.missingKey
        }
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(Self.body(for: request))
        let (data, response) = try await transport(urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(status) else {
            throw Failure.http(status: status,
                               message: json?["error"]?["message"]?.string ?? "no detail")
        }
        guard let json else { throw Failure.malformed }
        if let usage = Usage(json) { onUsage?(usage) }
        return try Self.output(of: json)
    }

    /// Decodes Terra's JSON object into `T`.
    func respond<T: Decodable>(_ request: Request, as type: T.Type) async throws -> T {
        let value = try await respond(request)
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            throw Failure.malformed
        }
    }

    static func body(for request: Request) -> JSONValue {
        var content: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(request.text)])]
        for png in request.images {
            content.append(.object([
                "type": .string("input_image"),
                "image_url": .string("data:image/png;base64," + png.base64EncodedString()),
                "detail": .string("high"),
            ]))
        }
        return .object([
            "model": .string(model),
            "store": .bool(false),
            "instructions": .string(request.instructions),
            "input": .array([.object(["role": .string("user"), "content": .array(content)])]),
            "reasoning": .object(["effort": .string(request.effort.rawValue)]),
            "max_output_tokens": .number(Double(request.maxOutputTokens)),
            "text": .object(["format": .object([
                "type": .string("json_schema"),
                "name": .string(request.schemaName),
                "schema": request.schema,
                "strict": .bool(true),
            ])]),
        ])
    }

    /// The JSON object inside a Responses payload: the first `output_text`
    /// of the first message, or the refusal or cut-off that replaced it.
    static func output(of response: JSONValue) throws -> JSONValue {
        if response["status"]?.string == "incomplete" {
            throw Failure.incomplete(response["incomplete_details"]?["reason"]?.string ?? "unknown")
        }
        let parts = (response["output"]?.array ?? [])
            .filter { $0["type"]?.string == "message" }
            .flatMap { $0["content"]?.array ?? [] }
        if let refusal = parts.first(where: { $0["type"]?.string == "refusal" })?["refusal"]?.string {
            throw Failure.refused(refusal)
        }
        guard let text = parts.first(where: { $0["type"]?.string == "output_text" })?["text"]?.string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              value.object != nil
        else { throw Failure.malformed }
        return value
    }
}
