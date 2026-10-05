import Foundation
import JevVoiceCore

/// Shapes `list_apps` responses into the roster form
/// `{apps:[{name,bundle_id,running,pid}]}`. There is no cache here: every
/// call site passes `useInstalledAppCache: false` and CuaVoiceRuntime owns
/// roster freshness through its own stale-while-revalidate `appList` read.
/// Process/window authority always comes from fresh Driver observations.
@MainActor
final class CuaAppInventory {
    /// The roster shape: `{apps:[{name,bundle_id,running,pid}]}`.
    typealias Snapshot = JSONValue

    /// Validates and trims one raw list_apps response. `running`/`pid` ride
    /// along as advisory hints for fast-lane target disambiguation only —
    /// dispatch authority still comes from fresh reads.
    func read(fetch: () async throws -> JSONValue) async throws -> JSONValue {
        let observed = try await fetch()
        try Task.checkCancellation()
        guard let apps = observed["apps"]?.array else { throw DriverConnectionError.malformed }
        let names = apps.compactMap { app -> JSONValue? in
            guard let name = app["name"]?.string, let bundle = app["bundle_id"]?.string, !bundle.isEmpty else { return nil }
            return .object(["name": .string(name), "bundle_id": .string(bundle),
                            "running": app["running"] ?? .bool(false),
                            "pid": app["pid"] ?? .number(0)])
        }
        return .object(["apps": .array(names)])
    }
}
