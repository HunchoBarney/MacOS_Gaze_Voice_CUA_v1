import Foundation
import JarvisCore

/// Where a model call goes and the bearer it carries: the provider itself
/// with a developer's own key, or Jarvis's credential service with this
/// Mac's install token.
struct ServiceRoute: Sendable, Equatable {
    let url: URL
    let bearer: String
}

/// What opens one Realtime socket: a developer's own OpenAI key (model
/// nil, the client's default), or a short-lived client secret and the
/// model it was minted for.
struct RealtimeCredential: Sendable, Equatable {
    let key: String
    let model: String?
}

/// The app side of Jarvis's credential service (`CredentialService/`,
/// KAR-38). The owner's keys stay on the service. This Mac registers once
/// for an anonymous install token, kept in Keychain, and with it mints
/// Realtime client secrets and reaches the Responses and Jev proxies.
final class HostedCredentials: @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct Failure: Error, LocalizedError, Equatable {
        let code: String
        let message: String

        static let unreachable = Failure(code: "unreachable",
            message: "Jarvis can't reach its service right now. Check your internet connection.")
        static let malformed = Failure(code: "malformed",
            message: "Jarvis's service sent an answer Jarvis couldn't read.")

        var errorDescription: String? { message }
    }

    let baseURL: URL
    private let tokenStore: APIKeyStore
    private let transport: Transport
    private let registration = Registration()

    init(baseURL: URL, tokenStore: APIKeyStore,
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.transport = transport
    }

    /// The service's address: `JARVIS_CREDENTIALS_URL` from the launch
    /// environment, else `JarvisCredentialsURL` in Info.plist. Only https,
    /// or http to this Mac for `wrangler dev`.
    static func serviceURL(environment: [String: String], infoValue: Any?) -> URL? {
        let raw = environment["JARVIS_CREDENTIALS_URL"] ?? (infoValue as? String) ?? ""
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host(), !host.isEmpty else { return nil }
        switch url.scheme {
        case "https": return url
        case "http" where ["localhost", "127.0.0.1"].contains(host): return url
        default: return nil
        }
    }

    var responsesURL: URL { baseURL.appending(path: "v1/responses") }
    var jevURL: URL { baseURL.appending(path: "v1/jev") }

    /// The stored token, without registering. Agents read it when they spawn.
    var storedToken: String? {
        guard let token = try? tokenStore.read(), !token.isEmpty else { return nil }
        return token
    }

    /// This Mac's install token, registering once if there is none yet.
    /// Concurrent callers share one registration.
    func installToken() async throws -> String {
        if let token = storedToken { return token }
        return try await registration.run { [self] in
            if let token = storedToken { return token }
            var request = URLRequest(url: baseURL.appending(path: "v1/installs"), timeoutInterval: 10)
            request.httpMethod = "POST"
            guard let token = try await send(request)["token"]?.string, !token.isEmpty else {
                throw Failure.malformed
            }
            try tokenStore.save(token)
            return token
        }
    }

    /// A fresh Realtime client secret. A token the service no longer knows
    /// (its ledger was reset) is dropped and this Mac registers again once;
    /// a revoked one stays revoked.
    func realtimeCredential() async throws -> RealtimeCredential {
        do {
            return try await mintRealtimeSecret()
        } catch let failure as Failure where failure.code == "unknown_install" {
            try? tokenStore.delete()
            return try await mintRealtimeSecret()
        }
    }

    private func mintRealtimeSecret() async throws -> RealtimeCredential {
        var request = URLRequest(url: baseURL.appending(path: "v1/realtime/client_secret"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await installToken())", forHTTPHeaderField: "Authorization")
        let reply = try await send(request)
        guard let value = reply["value"]?.string, !value.isEmpty,
              let model = reply["model"]?.string, !model.isEmpty else { throw Failure.malformed }
        return RealtimeCredential(key: value, model: model)
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(status) else {
            throw Failure(code: json?["error"]?["code"]?.string ?? "http_\(status)",
                          message: json?["error"]?["message"]?.string
                            ?? "Jarvis's service returned an error (\(status)).")
        }
        guard let json else { throw Failure.malformed }
        return json
    }

    private actor Registration {
        private var pending: Task<String, Error>?

        func run(_ register: @escaping @Sendable () async throws -> String) async throws -> String {
            if let pending { return try await pending.value }
            let task = Task { try await register() }
            pending = task
            defer { pending = nil }
            return try await task.value
        }
    }
}
