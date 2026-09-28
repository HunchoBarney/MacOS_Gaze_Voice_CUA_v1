import Foundation
import JevVoiceCore

/// Cache installed names only. Process/window authority always comes from fresh Driver observations.
@MainActor
final class CuaAppInventory {
    private var value: JSONValue?
    private var expiresAt: Double = 0
    func snapshot() -> JSONValue? { value }
    func read(now: Double = ProcessInfo.processInfo.systemUptime, fetch: () async throws -> JSONValue) async throws -> JSONValue {
        if let value, now < expiresAt { return value }
        let observed = try await fetch()
        try Task.checkCancellation()
        guard let apps = observed["apps"]?.array else { throw DriverConnectionError.malformed }
        let names = apps.compactMap { app -> JSONValue? in
            guard let name = app["name"]?.string, let bundle = app["bundle_id"]?.string, !bundle.isEmpty else { return nil }
            return .object(["name": .string(name), "bundle_id": .string(bundle)])
        }
        let result: JSONValue = .object(["apps": .array(names)])
        value = result; expiresAt = now + 60
        return result
    }
}
