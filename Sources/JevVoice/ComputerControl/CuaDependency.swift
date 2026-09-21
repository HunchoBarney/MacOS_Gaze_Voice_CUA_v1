import Foundation
import CryptoKit
import JevVoiceCore

/// Exact local integration tested for this migration. Stock auto-updates must
/// not silently remove the source patches required by the host.
enum CuaDependency {
    static let sourceRevision = "662e9ddb2e2fd6ded048635713e199b3476926a6"
    static let executable = URL(fileURLWithPath: "/Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local")
    static let executableSHA256 = "699d330bd1cd4e2255f0c99e889f1358952de246254fac7e4417b08dd6578d2a"

    static func verify(_ file: URL, expectedSHA256: String) throws {
        guard FileManager.default.isExecutableFile(atPath: file.path) else {
            throw DriverConnectionError.refused("The required Cua Driver Local build is missing from Applications. Restore the pinned migration dependency before connecting.")
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else {
            throw DriverConnectionError.refused("Cua Driver Local differs from the tested migration build. Restore the pinned dependency; no fallback Driver was started.")
        }
    }
}
