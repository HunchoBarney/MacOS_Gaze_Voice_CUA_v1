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

    /// A passing full hash is remembered per path — in memory because every
    /// connect() and pool proxy verifies, and in UserDefaults so a cold app
    /// start also skips the ~72MB read. The record is bound to the pin, so a
    /// new expectedSHA256 always rehashes.
    private static var memoryVerified: [String: (sha: String, fingerprint: String)] = [:]
    private static let memoryVerifiedLock = NSLock()
    private static let verifiedDefaultsKey = "cuaDependencyVerifiedStat"

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
        if let hit { return hit.sha == sha ? hit.fingerprint : nil }
        guard let entry = UserDefaults.standard.dictionary(forKey: verifiedDefaultsKey)?[path] as? [String: String],
              entry["sha"] == sha, let fingerprint = entry["fp"] else { return nil }
        memoryVerifiedLock.lock()
        memoryVerified[path] = (sha: sha, fingerprint: fingerprint)
        memoryVerifiedLock.unlock()
        return fingerprint
    }

    private static func recordVerified(path: String, sha: String, fingerprint: String) {
        memoryVerifiedLock.lock()
        memoryVerified[path] = (sha: sha, fingerprint: fingerprint)
        memoryVerifiedLock.unlock()
        var all = UserDefaults.standard.dictionary(forKey: verifiedDefaultsKey) ?? [:]
        // Verified targets are the two executable paths plus test fixtures —
        // cap the record so throwaway paths cannot grow it without bound.
        if all.count >= 8, all[path] == nil { all.removeAll(keepingCapacity: true) }
        all[path] = ["sha": sha, "fp": fingerprint]
        UserDefaults.standard.set(all, forKey: verifiedDefaultsKey)
    }

    private static func forgetVerified(path: String) {
        memoryVerifiedLock.lock()
        memoryVerified.removeValue(forKey: path)
        memoryVerifiedLock.unlock()
        if var all = UserDefaults.standard.dictionary(forKey: verifiedDefaultsKey),
           all.removeValue(forKey: path) != nil {
            UserDefaults.standard.set(all, forKey: verifiedDefaultsKey)
        }
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
