import Foundation
import AppKit

/// Locates the codex CLI the app itself would spawn — same search order as
/// the agent runtime wiring (bundled CodexRuntime first, then the working-
/// copy vendor tree, then the user's ~/.local/bin install). Unpackaged runs
/// and tests land on the dev paths.
enum CodexDependency {
    static var executable: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("CodexRuntime/bin/codex"))
            candidates.append(resources.appendingPathComponent("CodexRuntime/codex"))
        }
        // Repository root from this file's compile-time path — survives any
        // process cwd, so `swift run`/`swift test` still find the vendor tree.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(sourceRoot.appendingPathComponent("build/vendor/CodexRuntime/bin/codex"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("build/vendor/CodexRuntime/bin/codex"))
        candidates.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codex"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}

/// ChatGPT sign-in state for the planner lane: probes `codex login status`
/// against `~/.codex/auth.json` and runs the vendored binary's device-auth
/// flow (`codex login --device-auth` prints a URL + one-time code, so no TTY
/// is needed — the page opens itself and the code lands on the clipboard).
/// A visible Terminal `codex login` is the fallback when the binary can't
/// print a URL. Never throws; only reports what it verified.
final class CodexAuth: ObservableObject {
    enum Status: Equatable, Sendable {
        case signedOut
        case signedIn(String?)
        case unreachable
    }

    static let shared = CodexAuth()

    /// Last verified status — `signedOut` until a probe confirms otherwise,
    /// never claimed signed-in without auth.json plus a clean status reply.
    @Published private(set) var chatGPTAuthStatus: Status = .signedOut
    @Published private(set) var signInInFlight = false
    /// One-time device code while a device-auth flow is waiting on the user.
    @Published private(set) var signInCode: String?
    /// True when the flow had to fall back to a Terminal window.
    @Published private(set) var signInOpenedTerminal = false

    private let binary: URL?
    private let codexHome: URL
    private let stateLock = NSLock()
    private var cachedStatus: (status: Status, at: Date)?
    private var signInProcess: Process?
    private var inFlight = false

    var binaryAvailable: Bool {
        binary.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }

    init(binary: URL? = CodexDependency.executable,
         codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")) {
        self.binary = binary
        self.codexHome = codexHome
    }

    /// Async publish kick for views — the probe runs off the caller.
    func refresh() {
        Task.detached { [weak self] in _ = await self?.status() }
    }

    /// Synchronous lock helpers — calling them from async contexts is
    /// legal; holding `lock()` across a suspension point is not.
    private func cachedStatusIfFresh() -> Status? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let cached = cachedStatus, Date().timeIntervalSince(cached.at) < 30 else {
            return nil
        }
        return cached.status
    }

    private func storeStatus(_ status: Status) {
        stateLock.lock()
        cachedStatus = (status, Date())
        stateLock.unlock()
    }

    private func setSignInProcess(_ process: Process?) {
        stateLock.lock()
        signInProcess = process
        stateLock.unlock()
    }

    private func clearSignInState() {
        stateLock.lock()
        signInProcess = nil
        inFlight = false
        stateLock.unlock()
    }

    /// Verified auth state, cached for ~30s so the settings view can poll
    /// freely. Never throws — every failure folds into `.unreachable`.
    @discardableResult
    func status() async -> Status {
        if let cached = cachedStatusIfFresh() { return cached }
        let result = await probe()
        storeStatus(result)
        publish { $0.chatGPTAuthStatus = result }
        return result
    }

    /// Starts the device-auth login. The vendored binary prints the auth URL
    /// and a one-time code, then polls until the user completes it — we open
    /// the page, copy the code, and watch `~/.codex/auth.json` until it
    /// changes or ~3 minutes pass. Timeout just settles back to the real
    /// status; no error theater.
    func beginChatGPTSignIn() {
        stateLock.lock()
        guard !inFlight, let binary,
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            stateLock.unlock()
            return
        }
        inFlight = true
        stateLock.unlock()
        publish {
            $0.signInInFlight = true
            $0.signInCode = nil
            $0.signInOpenedTerminal = false
        }
        Task.detached { [weak self] in await self?.runSignInFlow(binary: binary) }
    }

    /// auth.json must exist and be non-empty before `login status` is even
    /// worth spawning — the file is the load-bearing check, the CLI confirms.
    private func probe() async -> Status {
        guard let binary, FileManager.default.isExecutableFile(atPath: binary.path) else {
            return .unreachable
        }
        let authFile = codexHome.appendingPathComponent("auth.json").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: authFile),
              (attrs[.size] as? Int ?? 0) > 0 else {
            return .signedOut
        }
        guard let outcome = await run(binary, arguments: ["login", "status"], timeout: 15) else {
            return .unreachable
        }
        return Self.parseStatus(exitCode: outcome.exitCode,
                                output: outcome.stdout + "\n" + outcome.stderr)
    }

    /// "Logged in using ChatGPT" / "Not logged in" — observed output is
    /// minimal, so anything unrecognized is unreachable rather than a guess.
    static func parseStatus(exitCode: Int32, output: String) -> Status {
        let text = stripANSI(output)
        let lowered = text.lowercased()
        // Negative first: "Not logged in" contains the "logged in" substring.
        if lowered.contains("not logged") || lowered.contains("not signed")
            || lowered.contains("signed out") {
            return .signedOut
        }
        if lowered.contains("logged in") || lowered.contains("signed in") {
            var label: String?
            if let line = text.split(separator: "\n").first(where: {
                let l = $0.lowercased(); return l.contains("logged in") || l.contains("signed in")
            }), let range = line.range(of: "using", options: .caseInsensitive) {
                let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                label = tail.isEmpty ? nil : tail
            }
            return .signedIn(label)
        }
        return .unreachable
    }

    // MARK: - Sign-in flow

    private func runSignInFlow(binary: URL) async {
        let baseline = authSignature()
        let buffer = SignInOutput()
        let process = Process()
        let out = Pipe(), err = Pipe()
        process.executableURL = binary
        process.arguments = ["login", "--device-auth"]
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        out.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }

        var spawned = true
        do {
            try process.run()
            setSignInProcess(process)
        } catch {
            spawned = false
        }
        // If the CLI couldn't start (or won't print a URL), the interactive
        // `codex login` in a visible Terminal window is the fallback.
        var terminalOpened = spawned ? false : openTerminalLogin(binary: binary)
        var openedURL = false
        var copiedCode = false
        let deadline = Date().addingTimeInterval(180)
        let urlDeadline = Date().addingTimeInterval(8)

        while !Task.isCancelled {
            if authChanged(since: baseline) { break }
            if Date() >= deadline { break }
            let text = buffer.text
            if !openedURL, let url = Self.deviceAuthURL(in: text) {
                openedURL = true
                onMain { NSWorkspace.shared.open(url) }
            }
            if !copiedCode {
                let artifact = Self.deviceAuthCode(in: text)
                    ?? Self.deviceAuthURL(in: text)?.absoluteString
                if let artifact {
                    copiedCode = true
                    onMain {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(artifact, forType: .string)
                    }
                    if let code = Self.deviceAuthCode(in: text) {
                        publish { $0.signInCode = code }
                    }
                }
            }
            // No URL within the grace window → this binary needs a real TTY.
            if !openedURL, !terminalOpened, Date() >= urlDeadline {
                if process.isRunning { process.terminate() }
                terminalOpened = openTerminalLogin(binary: binary)
                if !terminalOpened { break }
            }
            // The flow died on its own before auth landed — if it never
            // surfaced a URL, move it to the Terminal fallback once; if it
            // did, nothing is left to wait for.
            if !process.isRunning, !terminalOpened {
                if !openedURL { terminalOpened = openTerminalLogin(binary: binary) }
                if !terminalOpened { break }
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }

        if process.isRunning { process.terminate() }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        clearSignInState()
        // Fresh probe — bypasses the cache; whatever the truth is lands in UI.
        let result = await probe()
        storeStatus(result)
        publish {
            $0.chatGPTAuthStatus = result
            $0.signInInFlight = false
            $0.signInCode = nil
            $0.signInOpenedTerminal = false
        }
    }

    /// Writes a throwaway .command and opens it in Terminal — no AppleEvents
    /// prompt, and `codex login` gets the TTY its browser flow expects.
    @discardableResult
    private func openTerminalLogin(binary: URL) -> Bool {
        let script = """
        #!/bin/sh
        "\(binary.path)" login
        echo
        echo "Sign-in finished — you can close this window."
        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-codex-login-\(UUID().uuidString).command")
        guard let _ = try? script.write(to: file, atomically: true, encoding: .utf8),
              let _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path) else { return false }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Terminal", file.path]
        guard let _ = try? open.run() else { return false }
        publish { $0.signInOpenedTerminal = true }
        return true
    }

    private typealias AuthSignature = (exists: Bool, size: Int, mtime: Date?)

    private func authSignature() -> AuthSignature {
        let path = codexHome.appendingPathComponent("auth.json").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return (false, 0, nil)
        }
        return (true, attrs[.size] as? Int ?? 0, attrs[.modificationDate] as? Date)
    }

    /// Success means auth.json appeared or was rewritten with real content —
    /// a same-size same-mtime file means nothing landed yet.
    private func authChanged(since baseline: AuthSignature) -> Bool {
        let now = authSignature()
        guard now.exists, now.size > 0 else { return false }
        return !baseline.exists || now.size != baseline.size || now.mtime != baseline.mtime
    }

    /// First https URL in the (ANSI-cleaned) output — the device-auth page.
    static func deviceAuthURL(in output: String) -> URL? {
        let text = stripANSI(output)
        guard let range = text.range(of: "https://[^\\s\"']+", options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[range]))
    }

    /// One-time code shaped like `GE0K-353PD`.
    static func deviceAuthCode(in output: String) -> String? {
        let text = stripANSI(output)
        guard let range = text.range(of: "[A-Z0-9]{3,5}-[A-Z0-9]{4,6}",
                                     options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "",
                                  options: .regularExpression)
    }

    private struct Outcome {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Spawn-and-collect for short-lived probes; nil only when the process
    /// can't be launched at all. Timeout terminates — the handler still fires.
    private func run(_ binary: URL, arguments: [String], timeout: TimeInterval) async -> Outcome? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let out = Pipe(), err = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome.path
            process.environment = environment
            let resumed = ResumeGuard()
            process.terminationHandler = { process in
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                resumed.once {
                    continuation.resume(returning: Outcome(
                        exitCode: process.terminationStatus, stdout: stdout, stderr: stderr))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            } catch {
                resumed.once { continuation.resume(returning: nil) }
            }
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private func publish(_ body: @escaping (CodexAuth) -> Void) {
        onMain { body(self) }
    }
}

/// Readability handlers can deliver their last chunk after termination;
/// the continuation must resume exactly once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func once(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        body()
    }
}

/// Locked accumulation of device-auth stdout/stderr chunks — the flow's URL
/// and code are scraped from whatever the binary has printed so far.
private final class SignInOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
