import Network
import XCTest
@testable import Jarvis

/// The tracker API token fails closed: a spawned tracker always gets this
/// launch's token, and an already-running tracker is adopted only when its
/// own token file is readable and the tracker accepts it.
final class TrackerTokenTests: XCTestCase {

    func testStoredTokenIsNilWhenMissingOrEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracker-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".tracker_api_token")
        XCTAssertNil(TrackerHost.storedToken(at: nil))
        XCTAssertNil(TrackerHost.storedToken(at: file))
        try " \n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(TrackerHost.storedToken(at: file))
        try " fixture-token\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(TrackerHost.storedToken(at: file), "fixture-token")
    }

    func testSpawnedTrackerUsesTheLaunchToken() {
        XCTAssertEqual(TrackerHost.apiToken(), TrackerHost.launchToken)
    }

    func testRunningTrackerWithoutAReadableTokenIsNotAdopted() async throws {
        let server = try await FakeTrackerAPI.start(acceptedToken: "fixture-good-token")
        defer { server.stop() }
        let host = TrackerHost(spawnEnabled: false, port: server.port, tokenFile: { nil })
        await host.userRequestedStart()
        let state = await settledState(host)
        XCTAssertEqual(state, .failed(TrackerHost.foreignTrackerMessage))
        XCTAssertEqual(TrackerHost.apiToken(), TrackerHost.launchToken)
    }

    func testRunningTrackerThatRefusesItsStoredTokenIsNotAdopted() async throws {
        let file = try tokenFile(containing: "fixture-stale-token")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let server = try await FakeTrackerAPI.start(acceptedToken: "fixture-good-token")
        defer { server.stop() }
        let host = TrackerHost(spawnEnabled: false, port: server.port, tokenFile: { file })
        await host.userRequestedStart()
        let state = await settledState(host)
        XCTAssertEqual(state, .failed(TrackerHost.foreignTrackerMessage))
        XCTAssertEqual(TrackerHost.apiToken(), TrackerHost.launchToken)
        XCTAssertFalse(server.sawUnauthenticatedQuit, "a failed adoption must not drive the tracker")
    }

    func testRunningTrackerWithItsTokenIsAdoptedUntilItStops() async throws {
        let file = try tokenFile(containing: "fixture-good-token")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let server = try await FakeTrackerAPI.start(acceptedToken: "fixture-good-token")
        defer { server.stop() }
        let host = TrackerHost(spawnEnabled: false, port: server.port, tokenFile: { file })
        await host.userRequestedStart()
        let state = await settledState(host)
        XCTAssertEqual(state, .running)
        XCTAssertEqual(TrackerHost.apiToken(), "fixture-good-token")
        await host.installForTest(child: nil, attempts: TrackerHost.maxAttempts, state: .stopped)
        XCTAssertEqual(TrackerHost.apiToken(), TrackerHost.launchToken,
                       "dropping the adoption drops the adopted token")
    }

    private func tokenFile(containing token: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracker-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".tracker_api_token")
        try token.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func settledState(_ host: TrackerHost) async -> TrackerHost.State {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let state = await host.state
            if state != .starting { return state }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await host.state
    }
}

/// A stand-in tracker API on an ephemeral port: /health answers like the
/// tracker, every other route needs the accepted bearer token.
private final class FakeTrackerAPI: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var quitWithoutToken = false
    var sawUnauthenticatedQuit: Bool { lock.withLock { quitWithoutToken } }
    var port: Int { Int(listener.port?.rawValue ?? 0) }

    private init(listener: NWListener) { self.listener = listener }

    static func start(acceptedToken: String) async throws -> FakeTrackerAPI {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = FakeTrackerAPI(listener: listener)
        listener.newConnectionHandler = { [server] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let authorized = request.lowercased().contains("authorization: bearer \(acceptedToken)")
                let (status, body): (String, String)
                if request.hasPrefix("GET /health ") {
                    (status, body) = ("200 OK", #"{"ok":true,"started_at":"fixture"}"#)
                } else if authorized {
                    (status, body) = ("200 OK", "{}")
                } else {
                    if request.hasPrefix("POST /control ") { server.lock.withLock { server.quitWithoutToken = true } }
                    (status, body) = ("401 Unauthorized", #"{"error":"unauthorized"}"#)
                }
                let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = NSLock()
            var done = false
            listener.stateUpdateHandler = { state in
                let result: Result<Void, Error>?
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(error)
                default: result = nil
                }
                guard let result else { return }
                let first = resumed.withLock { () -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            listener.start(queue: .global())
        }
        return server
    }

    func stop() { listener.cancel() }
}
