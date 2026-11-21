import Foundation
import GRDB
import Synchronization

/// One thing Jarvis remembers about the user, kept in the user's own words.
struct Memory: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case person, preference, note, request
    }

    var id: Int64?
    var kind: Kind
    /// Who or what the memory is about, when the words name one ("Dana").
    var subject: String?
    var text: String
    var createdAt: Date
    /// Past requests expire; everything else stays until the user deletes it.
    var expiresAt: Date?

    static let databaseTableName = "memory"

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The memories picked for one Live session, and the block of text that
/// carries them into its instructions or a `session.thinking.append`.
struct MemoryContext: Equatable, Sendable {
    static let empty = MemoryContext(memories: [])
    /// Under the 500-token limit of one `session.thinking.append`.
    static let instructionBudget = 1_600

    let memories: [Memory]

    var instructions: String {
        guard !memories.isEmpty else { return "" }
        var block = "What you know about the user from earlier conversations, in their words. Use it when it helps; don't read it out:"
        for memory in memories {
            let line = "\n- " + (memory.kind == .request ? "Earlier request: " : "") + memory.text
            guard block.count + line.count <= Self.instructionBudget else { break }
            block += line
        }
        return block
    }
}

/// Jarvis's memory of the user: one SQLite database under
/// ~/Library/Application Support/Jarvis/Memory, searched with FTS5. Nothing
/// is written anywhere else, the database opens only on first use, and
/// deleted text is overwritten on disk rather than left in free pages.
final class MemoryStore: Sendable {
    static let shared = MemoryStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis/Memory", isDirectory: true),
        isEnabled: { UserDefaults.standard.bool(forKey: "voice.live") })

    static let maxLength = 280
    static let requestLifetime: TimeInterval = 90 * 24 * 60 * 60

    let directory: URL
    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let database = Mutex<DatabaseQueue?>(nil)

    init(directory: URL,
         isEnabled: @escaping @Sendable () -> Bool,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.isEnabled = isEnabled
        self.now = now
    }

    var databaseURL: URL { directory.appendingPathComponent("memory.sqlite") }

    // MARK: - Live sessions

    /// The few memories relevant to a new Live session or request: matches
    /// for the utterance first, then standing preferences and people.
    /// Read fresh on every call, so a deleted memory never comes back.
    /// Empty when `voice.live` is off or the database can't be opened.
    func sessionContext(for utterance: String?, limit: Int = 8) -> MemoryContext {
        guard isEnabled(), limit > 0 else { return .empty }
        let cutoff = now()
        let picked = try? queue().write { db -> [Memory] in
            try Self.purgeExpired(db, at: cutoff)
            var picked: [Memory] = []
            if let pattern = utterance.flatMap(Self.anyWordPattern) {
                picked = try Memory.fetchAll(db, sql: """
                    SELECT memory.* FROM memory
                    JOIN memory_ft ON memory_ft.rowid = memory.id
                    WHERE memory_ft MATCH ?
                    ORDER BY bm25(memory_ft), memory.createdAt DESC
                    LIMIT ?
                    """, arguments: [pattern, limit])
            }
            let taken = picked.compactMap(\.id)
            picked += try Memory.fetchAll(db, sql: """
                SELECT * FROM memory
                WHERE kind IN ('preference', 'person') AND id NOT IN (SELECT value FROM json_each(?))
                ORDER BY kind = 'preference' DESC, createdAt DESC
                LIMIT ?
                """, arguments: [String(describing: taken), limit - picked.count])
            return picked
        }
        return MemoryContext(memories: picked ?? [])
    }

    // MARK: - Writing

    /// Saves something the user asked Jarvis to remember. Saying the same
    /// thing twice refreshes the memory instead of storing a copy.
    @discardableResult
    func remember(_ words: String) throws -> Memory {
        let text = Self.clean(words)
        guard !text.isEmpty else { throw MemoryError.empty }
        let (kind, subject) = Self.classify(text)
        return try save(Memory(kind: kind, subject: subject, text: text, createdAt: now(), expiresAt: nil))
    }

    /// Records a one-line summary of a finished request, kept 90 days.
    @discardableResult
    func recordRequest(_ summary: String) throws -> Memory {
        let text = Self.clean(summary)
        guard !text.isEmpty else { throw MemoryError.empty }
        let created = now()
        return try save(Memory(kind: .request, subject: nil, text: text, createdAt: created,
                               expiresAt: created.addingTimeInterval(Self.requestLifetime)))
    }

    private func save(_ memory: Memory) throws -> Memory {
        try queue().write { db in
            if var existing = try Memory.filter(Column("text") == memory.text).fetchOne(db) {
                existing.createdAt = memory.createdAt
                existing.expiresAt = memory.expiresAt
                try existing.update(db)
                return existing
            }
            var memory = memory
            try memory.insert(db)
            return memory
        }
    }

    // MARK: - Reading

    /// Memories that mention every word of `subject`, best match first.
    /// `includeRequests: false` keeps to what the person asked Jarvis to
    /// remember, leaving out summaries of past requests.
    func recall(_ subject: String, limit: Int = 3, includeRequests: Bool = true) throws -> [Memory] {
        let words = Self.meaningfulWords(subject)
        guard let pattern = FTS5Pattern(matchingAllTokensIn: words.isEmpty ? subject : words.joined(separator: " "))
        else { return [] }
        let cutoff = now()
        return try queue().write { db in
            try Self.purgeExpired(db, at: cutoff)
            return try Memory.fetchAll(db, sql: """
                SELECT memory.* FROM memory
                JOIN memory_ft ON memory_ft.rowid = memory.id
                WHERE memory_ft MATCH ? AND (? OR memory.kind != 'request')
                ORDER BY bm25(memory_ft, 4.0, 1.0), memory.createdAt DESC
                LIMIT ?
                """, arguments: [pattern, includeRequests, limit])
        }
    }

    /// Every memory, newest first, delivered now and again after each change.
    @MainActor
    func observeAll(onError: @escaping @MainActor @Sendable (Error) -> Void,
                    onChange: @escaping @MainActor @Sendable ([Memory]) -> Void) throws -> AnyDatabaseCancellable {
        let cutoff = now()
        let queue = try queue()
        try queue.write { try Self.purgeExpired($0, at: cutoff) }
        return ValueObservation
            .tracking { try Memory.order(Column("createdAt").desc, Column("id").desc).fetchAll($0) }
            .start(in: queue, scheduling: .immediate, onError: onError, onChange: onChange)
    }

    // MARK: - Forgetting

    func delete(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        _ = try queue().write { try Memory.deleteAll($0, keys: ids) }
    }

    /// Deletes every memory, rebuilds the search index and compacts the
    /// file, so none of the old text is left in it.
    func forgetAll() throws {
        let queue = try queue()
        try queue.write { db in
            _ = try Memory.deleteAll(db)
            try db.execute(sql: "INSERT INTO memory_ft(memory_ft) VALUES('rebuild')")
        }
        try queue.vacuum()
    }

    // MARK: - Database

    private func queue() throws -> DatabaseQueue {
        try database.withLock { opened in
            if let opened { return opened }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA secure_delete = ON")
                try db.execute(sql: "PRAGMA temp_store = MEMORY")
            }
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            try Self.migrator.migrate(queue)
            opened = queue
            return queue
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "memory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("subject", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("expiresAt", .datetime)
            }
            try db.create(virtualTable: "memory_ft", using: FTS5()) { t in
                t.synchronize(withTable: "memory")
                t.tokenizer = .unicode61()
                t.column("subject")
                t.column("text")
            }
            // A deleted memory leaves the search index at once instead of
            // waiting for a segment merge (SQLite 3.42+).
            try db.execute(sql: "INSERT INTO memory_ft(memory_ft, rank) VALUES('secure-delete', 1)")
        }
        return migrator
    }

    private static func purgeExpired(_ db: Database, at date: Date) throws {
        _ = try Memory.filter(Column("expiresAt") < date).deleteAll(db)
    }

    // MARK: - Text

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "about", "can", "could", "do", "does", "for", "from", "have",
        "he", "her", "him", "his", "how", "i", "if", "in", "is", "it", "its", "me", "my", "of",
        "on", "or", "our", "please", "she", "so", "that", "the", "their", "them", "then", "there",
        "they", "this", "to", "up", "was", "we", "what", "when", "where", "which", "who", "why",
        "will", "with", "would", "you", "your", "jarvis",
    ]

    /// Any meaningful word of the utterance, or nil when it has none.
    static func anyWordPattern(_ utterance: String) -> FTS5Pattern? {
        FTS5Pattern(matchingAnyTokenIn: meaningfulWords(utterance).prefix(16).joined(separator: " "))
    }

    private static func meaningfulWords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) && seen.insert($0).inserted }
    }

    /// Collapses whitespace, caps the length at a word boundary, and
    /// capitalises a plain first word ("my gate code…") but never an email,
    /// a name like "iPhone" or a single letter.
    static func clean(_ words: String) -> String {
        var text = words.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if text.count > maxLength {
            let head = text.prefix(maxLength - 1)
            let cut = head.lastIndex(of: " ").flatMap { head.distance(from: head.startIndex, to: $0) > maxLength - 40 ? $0 : nil }
            text = String(head[..<(cut ?? head.endIndex)]) + "…"
        }
        let firstWord = text.prefix { $0 != " " }
        guard firstWord.count > 1, firstWord.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return text }
        return firstWord.capitalized + text.dropFirst(firstWord.count)
    }

    /// People are "Dana is my manager" or "my manager is Dana";
    /// preferences are "I like…", "use Chrome for work"; the rest are notes.
    static func classify(_ text: String) -> (Memory.Kind, String?) {
        let name = #"([A-Z][\p{L}'’\-]+(?: [A-Z][\p{L}'’\-]+)?)"#
        if let subject = firstCapture(#"^"# + name + #"(?:'s| is| was) (?:my|our) "#, in: text)
            ?? firstCapture(#"^(?:My|Our) [\p{L} ]+ (?:is|was) "# + name + #"\.?$"#, in: text) {
            return (.person, subject)
        }
        let preference = #"^(?:I (?:like|love|prefer|hate|want|don't like|do not like|always|never|use)\b|(?:Use|Always|Never|Call me|Don't|Do not)\b)"#
        if text.range(of: preference, options: [.regularExpression, .caseInsensitive]) != nil {
            return (.preference, nil)
        }
        return (.note, nil)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

enum MemoryError: Error {
    case empty
}
