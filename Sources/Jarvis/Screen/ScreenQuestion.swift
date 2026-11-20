import CoreGraphics
import Foundation

/// Answers a spoken question about the screen from its words: the focused
/// window's digest, or for "what's on my screen" every visible window's
/// title plus that digest. The words go to Realtime as a tool result; no
/// picture is taken here.
enum ScreenQuestion {
    enum Scope: String, Sendable { case window, screen }

    struct WindowTitle: Sendable, Equatable {
        var app: String
        var title: String
    }

    /// Words for the model to answer from, or a fixed line Jarvis says
    /// itself.
    enum Reply: Equatable {
        case text(String, digest: ScreenDigest?)
        case refused(String)
        case unavailable(String)
    }

    static let vaultRefusal = "That's a password manager, so I won't read it."
    static let unreadable = "I can't read this window right now."
    static let thinText = "I can't read that part from text yet."
    static let failure = "I couldn't read the screen just now."
    static let maxWindows = 20
    static let maxQuestionCharacters = 300
    static let thinTextCharacters = 300
    static let guidance = """
        These are the words in the window, read as text, not a picture. Answer the question \
        from them in one or two short sentences. Call a control by its exact label. If the \
        words don't answer it, say you can't read that part from text yet.
        """

    static func reply(question: String, scope: Scope, focused: ScreenDigest?,
                      windows: [WindowTitle]) async -> Reply {
        let question = String(question.prefix(maxQuestionCharacters))
        let listed = scope == .screen ? Array(windows.prefix(maxWindows)) : []
        if listed.isEmpty {
            guard let focused else { return .unavailable(unreadable) }
            if focused.withheld == .vault { return .refused(vaultRefusal) }
            if needsPicture(focused) { return await pictureTier(question: question, digest: focused) }
        }
        var lines = ["Question: \(question)"]
        if !listed.isEmpty {
            lines.append("Open windows, front to back:")
            lines += listed.map { $0.title.isEmpty ? "- \($0.app)" : "- \($0.app): \($0.title)" }
            lines.append("Focused window:")
        }
        lines.append(focused?.rendered ?? "(The focused window could not be read.)")
        return .text(lines.joined(separator: "\n"), digest: focused)
    }

    /// Too few words to answer from: an empty read, only pictures, or a
    /// web view with under about 300 characters of text.
    static func needsPicture(_ digest: ScreenDigest) -> Bool {
        guard !digest.items.isEmpty, !digest.items.allSatisfy({ $0.kind == "image" }) else { return true }
        return digest.webArea && digest.items.reduce(0) { $0 + $1.text.count } < thinTextCharacters
    }

    /// The picture tier's seam. Piece 5 sends one redacted picture of this
    /// window to Terra here; until then Jarvis says it can't read that
    /// part from text yet.
    static func pictureTier(question: String, digest: ScreenDigest) async -> Reply {
        .unavailable(thinText)
    }

    /// The say-less tool result: the model answers from these words.
    static func output(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let fields = ["kind": "screen_text", "screen": text, "how_to_answer": guidance]
        guard let data = try? encoder.encode(fields) else { return #"{"kind":"screen_text"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    static func isScreenAnswer(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return fields["kind"] == "screen_text"
    }

    /// The control an answer points at: the one named item whose label the
    /// answer says, longest label first ("Send Later" over "Send"). Plain
    /// text and labels under three letters ("OK", "Go") never glow, and two
    /// items with the same label can't be told apart.
    static func pointedRef(answer: String, in digest: ScreenDigest) -> String? {
        let spoken = words(answer)
        let named = digest.items.compactMap { item -> (ref: String, label: String)? in
            let label = words(item.text)
            guard item.kind != "text", label.filter(\.isLetter).count >= 3, spoken.contains(label) else { return nil }
            return (item.ref, label)
        }
        guard let longest = named.map(\.label.count).max() else { return nil }
        let best = named.filter { $0.label.count == longest }
        return best.count == 1 ? best[0].ref : nil
    }

    private static func words(_ text: String) -> String {
        " " + text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
    }

    /// "What is this" at a gaze point: the smallest element under it, read
    /// from the same redacted digest.
    static func describe(at point: CGPoint, in digest: ScreenDigest) -> String {
        if digest.withheld == .vault { return vaultRefusal }
        func area(_ item: ScreenDigest.Item) -> CGFloat {
            guard let frame = item.frame else { return 0 }
            return frame.width * frame.height
        }
        let hit = digest.items.filter { $0.frame?.contains(point) == true }.min { area($0) < area($1) }
        guard let hit else {
            return digest.windowTitle.isEmpty
                ? "That's \(digest.app)'s window."
                : "That's \(digest.app)'s “\(digest.windowTitle)” window."
        }
        if hit.kind == "text" { return "That says “\(hit.text)” in \(digest.app)." }
        let article = "aeiou".contains(hit.kind.first ?? "x") ? "an" : "a"
        if hit.text.isEmpty { return "That's \(article) \(hit.kind) in \(digest.app)." }
        return "That's \(article) \(hit.kind), “\(hit.text)”, in \(digest.app)."
    }
}
