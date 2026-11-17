import Foundation

/// Sendable JSON at the versioned Driver boundary; UI and actions decode concrete types.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? { object?[key] }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var integer: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v else { return nil }
        return Int(exactly: v)
    }
}

public enum DriverConnectionError: Error, LocalizedError, Equatable {
    case unavailable, closed, malformed, timedOut, remote(String), refused(String)
    case toolRefused(tool: String, code: String, detail: String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Install Cua Driver in Applications before connecting."
        case .closed: return "Cua disconnected. A dispatched action may have completed; inspect before retrying."
        case .malformed: return "Cua returned an invalid response. No action will be replayed."
        case .timedOut: return "Cua timed out. A dispatched action may have completed; inspect before retrying."
        case .remote(let text), .refused(let text): return text
        // The driver-side refusal text stays OUT of localizedDescription —
        // refusal messages can carry private observed content and this
        // description reaches user-facing surfaces. The typed code is the
        // safe signal; `detail` rides along only for MCP envelopes where the
        // agent needs the actionable reason.
        case .toolRefused(let tool, let code, _):
            return "Cua could not complete \(tool) (\(code)). Inspect the target before retrying."
        }
    }

    /// The daemon's own refusal reason, for the local diagnostics log only —
    /// kept out of `errorDescription` because refusal text can carry private
    /// observed content and that description reaches user-facing surfaces.
    /// The log file already records transcripts verbatim, so the same
    /// privacy posture applies.
    public var diagnosticsDetail: String? {
        if case .toolRefused(_, _, let detail) = self, !detail.isEmpty { return detail }
        return nil
    }
}

/// Incremental framing with a bound, including for an unterminated line.
public struct MCPFrames {
    private var buffer = Data()
    public let limit: Int
    public init(limit: Int = 16 * 1024 * 1024) { self.limit = limit }
    public mutating func append(_ data: Data) throws -> [JSONValue] {
        buffer.append(data)
        var messages: [JSONValue] = []
        while let end = buffer.firstIndex(of: 10) {
            guard end <= limit else { throw DriverConnectionError.malformed }
            let line = buffer.prefix(upTo: end)
            guard !line.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: line),
                  value["jsonrpc"] == .string("2.0") else { throw DriverConnectionError.malformed }
            messages.append(value)
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= limit else { throw DriverConnectionError.malformed }
        return messages
    }
}
