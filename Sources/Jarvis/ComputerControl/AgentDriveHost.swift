import Darwin
import Foundation
import OSLog
import Synchronization
import JarvisCore

/// The host end of an agent's computer use. Codex spawns each agent's
/// `Jarvis --mcp-stdio` child, and the Cua daemon admits only the app
/// itself (`--host-connections-only`), so the child never opens a daemon
/// connection. It hands each `drive_until`/`suggest_action` call to the app
/// over this socket, and the app runs the DriveLoop on its own connection,
/// under its own consent state and keys.
///
/// Trust: the socket sits in a private mkdtemp directory (mode 0700), every
/// peer must have this user's uid (`getpeereid`), and every request carries
/// the token the app minted for that agent and passed to its Codex through
/// `env_vars`. A token names one agent, so a child can't act as another.
///
/// Wire: one request per connection, one JSON line each way. The request is
/// `{agent, token, tool, arguments}` and the reply is the MCP tool result.
/// The child closing its end cancels the run.
final class AgentDriveHost: Sendable {
    static let tokenVariable = "JARVIS_AGENT_TOKEN"
    static let maxLineBytes = 1 << 20
    typealias Handler = @Sendable (_ agent: String, _ tool: String, _ arguments: JSONValue) async -> JSONValue

    private static let log = Logger(subsystem: "com.karanvirkang.jarvis", category: "agent-drive-host")

    let socketPath: String
    private let listener: Int32
    private let tokens = Mutex<[String: String]>([:])
    private let handler: Handler

    /// Binds `agents.sock` in a fresh private directory under `base` and
    /// starts accepting. Nil when the socket can't be made.
    init?(base: String = NSTemporaryDirectory(), handler: @escaping Handler) {
        guard let directory = CuaSocketDirectory.create(in: base) else { return nil }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("agents.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard Self.withAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        socketPath = path
        listener = fd
        self.handler = handler
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// The agent's token, minted on first use and stable for this app run.
    func token(for agent: String) -> String {
        tokens.withLock { tokens in
            if let token = tokens[agent] { return token }
            var generator = SystemRandomNumberGenerator()
            let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
                .joined()
            tokens[agent] = token
            return token
        }
    }

    /// Stops accepting. Calls already running finish.
    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func authorized(agent: String, token: String) -> Bool {
        guard let expected = tokens.withLock({ $0[agent] }) else { return false }
        let a = Array(expected.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    /// One call: check the peer and the token, run the tool, reply, and
    /// cancel the run if the child hangs up first. The descriptor closes
    /// only after the run has finished writing, so it is never reused
    /// under a late write.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            Self.log.error("refused an agent connection from another user")
            return
        }
        guard let line = Self.readLine(fd),
              let request = try? JSONDecoder().decode(JSONValue.self, from: line),
              let agent = request["agent"]?.string, let token = request["token"]?.string,
              let tool = request["tool"]?.string else {
            Self.writeLine(fd, Self.toolError("Jarvis couldn't read that request."))
            return
        }
        guard authorized(agent: agent, token: token) else {
            Self.log.error("refused an agent request with an unknown token")
            Self.writeLine(fd, Self.toolError("Jarvis doesn't recognize this agent. Restart it from Jarvis."))
            return
        }
        let finished = DispatchSemaphore(value: 0)
        let arguments = request["arguments"] ?? .object([:])
        let run = Task { [handler] in
            let result = await handler(agent, tool, arguments)
            Self.writeLine(fd, result)
            shutdown(fd, SHUT_RDWR)
            finished.signal()
        }
        var byte: UInt8 = 0
        while read(fd, &byte, 1) > 0 {}
        run.cancel()
        finished.wait()
    }

    // MARK: - Child side

    /// Sends one request to the app and returns its reply. Cancelling the
    /// calling task hangs up, which cancels the run in the app.
    static func forward(socket path: String, request: JSONValue) async throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DriverConnectionError.unavailable }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard withAddress(path, { connect(fd, $0, $1) }) == 0 else {
            close(fd)
            throw DriverConnectionError.unavailable
        }
        defer { close(fd) }
        guard writeLine(fd, request) else { throw DriverConnectionError.closed }
        let line: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread { continuation.resume(returning: readLine(fd)) }
            }
        } onCancel: {
            shutdown(fd, SHUT_RDWR)
        }
        try Task.checkCancellation()
        guard let line, let reply = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            throw DriverConnectionError.closed
        }
        return reply
    }

    // MARK: - Wire

    static func toolText(_ text: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    static func toolError(_ text: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                 "isError": .bool(true)])
    }

    private static func withAddress(_ path: String,
                                    _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    @discardableResult
    private static func writeLine(_ fd: Int32, _ value: JSONValue) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Bytes up to the first newline, or nil on EOF, error or an oversized line.
    private static func readLine(_ fd: Int32) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while line.count <= maxLineBytes {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[..<newline])
                return line
            }
            line.append(contentsOf: buffer[..<count])
        }
        return nil
    }
}
