import Foundation
import CryptoKit
import JevVoiceCore

/// Exact upstream integration tested for this migration. Stock auto-updates
/// must not silently replace the verified build.
enum CuaDependency {
    static let sourceRevision = "58aba84" // cua-driver-rs-v0.32.0
    static let hostBundleID = "com.chriswozniczek.jevvoice"
    static let installedExecutable = URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
    /// `make app` embeds the pinned build at Contents/Resources/cua-driver so
    /// spawned children inherit this app's TCC identity. Unpackaged runs
    /// (swift run, tests) fall back to the installed driver.
    static var bundledExecutable: URL? { Bundle.main.url(forResource: "cua-driver", withExtension: nil) }
    static var executable: URL { bundledExecutable ?? installedExecutable }
    static let executableSHA256 = "656ff1c1aea1ee063d7735bcd8eb4491346971d4fb3199c6d2260b40aae83c66"
    /// Signing is part of `make app`, so the embedded copy can never match the
    /// upstream byte hash. The build records the post-signing digest here and
    /// the outer app signature seals it; unpackaged bundles have no embedded
    /// driver and never reach this key.
    static var bundledSHA256: String? {
        Bundle.main.object(forInfoDictionaryKey: "JevCuaDriverSHA256") as? String
    }

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
