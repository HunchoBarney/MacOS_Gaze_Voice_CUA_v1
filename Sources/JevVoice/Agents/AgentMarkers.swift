import Foundation

/// Parses the bracketed control markers agents emit inside their final
/// message text (mirror/07-clickys.md):
///   <ROUTINE>{"action":"create","every_minutes":60,"title":"…","task":"…"}</ROUTINE>
///   <COMPUTER_USE_REQUEST>plain-language ask</COMPUTER_USE_REQUEST>
/// The `</>` close variant is accepted as well — the fork has been seen to
/// emit it when the tag is the last thing in the message.
public enum AgentMarkers {
    /// Decoded `<ROUTINE>` payload. `every_minutes` maps to Routine's
    /// `everyMinutes`; snake and camel keys both accepted.
    public struct RoutineMarker: Decodable, Sendable, Equatable {
        /// "create" | "pause" | "resume" | "delete" — unknown actions pass
        /// through so the coordinator can decide.
        public var action: String
        public var everyMinutes: Int?
        public var title: String?
        public var task: String?
        public var routineID: String?

        enum CodingKeys: String, CodingKey {
            case action, title, task
            case everyMinutesSnake = "every_minutes"
            case everyMinutesCamel = "everyMinutes"
            case routineIDSnake = "routine_id"
            case routineIDCamel = "routineId"
            case id
        }

        public init(action: String, everyMinutes: Int? = nil, title: String? = nil,
                    task: String? = nil, routineID: String? = nil) {
            self.action = action; self.everyMinutes = everyMinutes
            self.title = title; self.task = task; self.routineID = routineID
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            action = try c.decodeIfPresent(String.self, forKey: .action) ?? "create"
            everyMinutes = try c.decodeIfPresent(Int.self, forKey: .everyMinutesSnake)
                ?? c.decodeIfPresent(Int.self, forKey: .everyMinutesCamel)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            task = try c.decodeIfPresent(String.self, forKey: .task)
            routineID = try c.decodeIfPresent(String.self, forKey: .routineIDSnake)
                ?? c.decodeIfPresent(String.self, forKey: .routineIDCamel)
                ?? c.decodeIfPresent(String.self, forKey: .id)
        }
    }

    /// All well-formed `<ROUTINE>{json}</ROUTINE>` payloads in `text`.
    /// Malformed JSON inside a marker is skipped, never fatal.
    public static func routines(in text: String) -> [RoutineMarker] {
        markers(in: text, tag: "ROUTINE").compactMap {
            try? JSONDecoder().decode(RoutineMarker.self, from: Data(text[$0.content].utf8))
        }
    }

    /// The ask text of each computer-use consent request, trimmed.
    public static func computerUseRequests(in text: String) -> [String] {
        markers(in: text, tag: "COMPUTER_USE_REQUEST")
            .map { String(text[$0.content]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Message text with every marker block removed — what should be spoken
    /// or shown as the agent's visible reply.
    public static func strippingMarkers(_ text: String) -> String {
        var stripped = "", cursor = text.startIndex
        let all = (markers(in: text, tag: "ROUTINE")
            + markers(in: text, tag: "COMPUTER_USE_REQUEST"))
            .sorted { $0.whole.lowerBound < $1.whole.lowerBound }
        for marker in all {
            stripped += text[cursor..<marker.whole.lowerBound]
            cursor = marker.whole.upperBound
        }
        stripped += text[cursor...]
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<TAG>…</TAG>` and `<TAG>…</>` spans, in order. `content` is the inner
    /// text; `whole` covers open tag through close tag.
    private static func markers(in text: String, tag: String)
        -> [(whole: Range<String.Index>, content: Range<String.Index>)] {
        let open = "<\(tag)>", closes = ["</\(tag)>", "</>"]
        var found: [(Range<String.Index>, Range<String.Index>)] = []
        var cursor = text.startIndex
        while let openRange = text.range(of: open, range: cursor..<text.endIndex) {
            var best: Range<String.Index>?
            for close in closes {
                if let r = text.range(of: close, range: openRange.upperBound..<text.endIndex),
                   best == nil || r.lowerBound < best!.lowerBound {
                    best = r
                }
            }
            guard let close = best else { break }
            found.append((openRange.lowerBound..<close.upperBound,
                          openRange.upperBound..<close.lowerBound))
            cursor = close.upperBound
        }
        return found
    }
}
