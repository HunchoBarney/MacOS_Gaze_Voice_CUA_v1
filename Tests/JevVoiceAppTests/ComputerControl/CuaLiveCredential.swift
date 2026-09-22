import Foundation
import JevVoiceCore
@testable import JevVoice

/// Call only after the individual live test's opt-in gate. Never print the key.
enum CuaLiveCredential {
    static func jev() throws -> String {
        if let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty { return key }
        if let key = try KeychainAPIKeyStore(allowUserInteraction: false).read(), !key.isEmpty { return key }
        throw DriverConnectionError.refused("The authorized live check needs the configured Jev credential; no usable environment or noninteractive Keychain key was available.")
    }
}

/// Candidate runtime selection is explicit, hash-bound, and never falls back.
enum CuaLiveDriver {
    static func connection() throws -> CuaConnection {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["JARVIS_CUA_CANDIDATE_BIN"] else { return CuaConnection() }
        guard path.hasPrefix("/"), let hash = env["JARVIS_CUA_CANDIDATE_SHA256"], !hash.isEmpty else {
            throw DriverConnectionError.refused("Candidate Driver requires an absolute executable path and expected SHA-256.")
        }
        let executable = URL(fileURLWithPath: path)
        try CuaDependency.verify(executable, expectedSHA256: hash)
        // Plain mcp would proxy to the installed broker and prove the wrong build.
        return CuaConnection(executable: executable, arguments: ["mcp", "--direct", "--embedded"])
    }
}
