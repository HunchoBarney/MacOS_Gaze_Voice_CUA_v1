import Foundation
import CryptoKit
import JarvisCore

/// Exact upstream integration tested for this migration. Stock auto-updates
/// must not silently replace the verified build.
enum CuaDependency {
    static let sourceRevision = "09dd7017fca72678fd707490f8d2913a55d97e72" // cua-driver-rs-v0.54.0 + host-connections-only.patch
    static let hostBundleID = "com.karanvirkang.jarvis"
    static let installedExecutable = URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
    /// `make app` embeds the pinned build at Contents/Resources/cua-driver so
    /// spawned children inherit this app's TCC identity. Unpackaged runs
    /// (swift run, tests) fall back to the installed driver.
    static var bundledExecutable: URL? { Bundle.main.url(forResource: "cua-driver", withExtension: nil) }
    static var executable: URL { bundledExecutable ?? installedExecutable }
    static let executableSHA256 = "0bb686e1e44b5e80c26f6666b29e6a613621d25f4cc7dd407e19794193186b1c"
    /// Signing is part of `make app`, so the embedded copy can never match the
    /// upstream byte hash. The build records the post-signing digest here and
    /// the outer app signature seals it; unpackaged bundles have no embedded
    /// driver and never reach this key.
    static var bundledSHA256: String? {
        Bundle.main.object(forInfoDictionaryKey: "JevCuaDriverSHA256") as? String
    }

    /// A passing full hash is remembered per path for the process lifetime —
    /// every daemon spawn verifies, so the stat shortcut skips
    /// repeat ~72MB reads. Nothing persists: a UserDefaults record is
    /// forgeable by any same-UID process that can stat() the file, so each
    /// cold start pays one honest hash. The record is bound to the pin, so
    /// a new expectedSHA256 always rehashes.
    private static var memoryVerified: [String: (sha: String, fingerprint: String)] = [:]
    private static let memoryVerifiedLock = NSLock()

    /// `stat` identity of the file a hash covered: dev, ino, size and both
    /// timestamps. The record is taken BEFORE the read, so a mid-read swap
    /// can only cost an extra rehash, never pass unverified content — and
    /// ctime cannot be rewound by a writer preserving size and mtime.
    private static func statFingerprint(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):"
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):"
            + "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    private static func recordedFingerprint(path: String, sha: String) -> String? {
        memoryVerifiedLock.lock()
        let hit = memoryVerified[path]
        memoryVerifiedLock.unlock()
        guard let hit, hit.sha == sha else { return nil }
        return hit.fingerprint
    }

    private static func recordVerified(path: String, sha: String, fingerprint: String) {
        memoryVerifiedLock.lock()
        memoryVerified[path] = (sha: sha, fingerprint: fingerprint)
        memoryVerifiedLock.unlock()
    }

    private static func forgetVerified(path: String) {
        memoryVerifiedLock.lock()
        memoryVerified.removeValue(forKey: path)
        memoryVerifiedLock.unlock()
    }

    static func verify(_ file: URL, expectedSHA256: String) throws {
        let path = file.standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw DriverConnectionError.refused("The required Cua Driver Local build is missing from Applications. Restore the pinned migration dependency before connecting.")
        }
        let fingerprint = statFingerprint(path)
        if let fingerprint, recordedFingerprint(path: path, sha: expectedSHA256) == fingerprint { return }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else {
            forgetVerified(path: path)
            throw DriverConnectionError.refused("Cua Driver Local differs from the tested migration build. Restore the pinned dependency; no fallback Driver was started.")
        }
        if let fingerprint { recordVerified(path: path, sha: expectedSHA256, fingerprint: fingerprint) }
    }
}
