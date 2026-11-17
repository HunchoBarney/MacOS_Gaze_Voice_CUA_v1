import CryptoKit
import Darwin
import Foundation

/// Explicit test authorization only. Reservations survive crashes and count
/// failed HTTP attempts; no credential or request text is written here.
actor SemanticRequestBudget {
    struct Authorization: Codable, Sendable {
        let id: String
        let scope: String
        let maximumRequests: Int
        let corpusSHA256: String
        let expiresAt: Double
    }

    enum Failure: Error {
        case invalidAuthorization, exhausted, duplicateSubject, storage
    }

    let directory: URL
    let authorization: Authorization

    init(directory: URL, corpusSHA256: String, now: Double = Date().timeIntervalSince1970) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("authorization.json"))
        let auth = try JSONDecoder().decode(Authorization.self, from: data)
        guard auth.scope == "typesafe-text-only", !auth.id.isEmpty,
              (1...50).contains(auth.maximumRequests), auth.expiresAt > now,
              auth.corpusSHA256 == corpusSHA256 else { throw Failure.invalidAuthorization }
        self.directory = directory
        self.authorization = auth
    }

    func reserve(subject: String, requestSHA256: String, allocation: String = "shadow") throws -> Int {
        guard authorization.expiresAt > Date().timeIntervalSince1970 else { throw Failure.invalidAuthorization }
        guard ["shadow", "gui"].contains(allocation) else { throw Failure.invalidAuthorization }
        let lock = directory.appendingPathComponent("requests.lock")
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.storage }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.storage }
        defer { flock(fd, LOCK_UN) }
        let ledger = directory.appendingPathComponent("requests.jsonl")
        let data = FileManager.default.fileExists(atPath: ledger.path) ? try Data(contentsOf: ledger) : Data()
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map { line -> [String: Any] in
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            guard let row, row["authorization"] as? String == authorization.id else { throw Failure.invalidAuthorization }
            return row
        }
        let count = rows.count
        guard count < authorization.maximumRequests else { throw Failure.exhausted }
        guard rows.filter({ $0["allocation"] as? String == allocation }).count < (allocation == "shadow" ? 45 : 5) else {
            throw Failure.exhausted
        }
        guard !rows.contains(where: { $0["subject"] as? String == subject }) else { throw Failure.duplicateSubject }
        let row: [String: Any] = [
            "authorization": authorization.id, "index": count + 1, "subject": subject,
            "allocation": allocation,
            "request_sha256": requestSHA256, "reserved_at": Date().timeIntervalSince1970
        ]
        var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        bytes.append(10)
        if !FileManager.default.fileExists(atPath: ledger.path) {
            guard FileManager.default.createFile(atPath: ledger.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw Failure.storage }
        }
        let handle = try FileHandle(forWritingTo: ledger)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
        guard Darwin.fsync(handle.fileDescriptor) == 0 else { throw Failure.storage }
        return count + 1
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
