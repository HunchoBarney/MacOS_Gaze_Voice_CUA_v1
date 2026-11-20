import Foundation
import os

/// The wire under a Live session: WebRTC in the app, a fake in tests.
protocol LiveTransport: AnyObject, Sendable {
    /// Builds the connection (the microphone track and the "oai-events"
    /// channel) and returns its SDP offer with ICE candidates gathered.
    func offer() async throws -> String
    func accept(answer: String) async throws
    func send(_ message: Data) throws
    /// Data-channel messages, then one .closed when the connection ends.
    var incoming: AsyncStream<LiveTransportEvent> { get }
    func close()
}

enum LiveTransportEvent: Sendable, Equatable {
    case message(Data)
    case closed(String?)
}

/// How a session ended. Only session.closed carries the final usage, so a nil
/// usage means it never arrived: the connection dropped, or the close timed out.
struct LiveSessionEnding: Equatable, Sendable {
    let reason: LiveCloseReason
    let usage: LiveUsage?
    var confirmed: Bool { usage != nil }
}

/// One GPT-Live session over a transport: create it through the broker, wait
/// for session.started, follow Standby and resume, and close it gracefully so
/// the final usage is confirmed. Events reach \`onEvent\` on the main actor in
/// arrival order. Nothing here acts on what is heard.
@MainActor
final class LiveSession: LiveSessionSending {
    enum Phase: Equatable {
        case idle, connecting
        /// Started, inference paused until someone speaks (the speech wake policy).
        case standby
        /// Inference running: Live is listening and may speak.
        case active
        case closing
        case ended(LiveSessionEnding)
    }

    private static let log = Logger(subsystem: "com.karanvirkang.jarvis", category: "live")

    private(set) var phase: Phase = .idle
    private(set) var sessionID: String?
    /// The latest usage the server reported, kept for when the connection
    /// drops before session.closed confirms it.
    private(set) var lastUsage: LiveUsage?
    /// How long each step of the last start took: the offer (ICE gathered),
    /// the broker's session creation, applying the answer, and session.started.
    private(set) var startSteps: [(step: String, seconds: Double)] = []
    var onEvent: ((LiveSessionEvent) -> Void)?

    private let transport: LiveTransport
    private let broker: LiveSessionCreating
    private let config: LiveSessionConfig
    private var pump: Task<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var endWaiters: [CheckedContinuation<LiveSessionEnding, Never>] = []

    init(transport: LiveTransport, broker: LiveSessionCreating, config: LiveSessionConfig) {
        self.transport = transport
        self.broker = broker
        self.config = config
    }

    /// Connects and returns once session.started arrives.
    func start(timeout: Duration = .seconds(10)) async throws {
        guard phase == .idle else { return }
        phase = .connecting
        startSteps = []
        let clock = ContinuousClock()
        var mark = clock.now
        func step(_ name: String) {
            let elapsed = clock.now - mark
            mark = clock.now
            startSteps.append((name, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
        }
        do {
            let offer = try await transport.offer()
            step("offer")
            let answer = try await broker.createSession(offer: offer, config: config)
            step("create")
            sessionID = answer.id
            try await transport.accept(answer: answer.sdp)
            step("answer")
        } catch {
            end(LiveSessionEnding(reason: .connectionLost, usage: nil))
            throw error
        }
        let incoming = transport.incoming
        pump = Task { [weak self] in
            for await event in incoming {
                guard let self else { return }
                switch event {
                case .message(let data): self.receive(data)
                case .closed(let why):
                    Self.log.notice("live_transport_closed \(why ?? "", privacy: .public)")
                    self.end(LiveSessionEnding(reason: .connectionLost, usage: nil))
                }
            }
        }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, self.phase == .connecting else { return }
            self.finishStart(.failure(LiveSessionError.startTimedOut))
            self.end(LiveSessionEnding(reason: .connectionLost, usage: nil))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { startWaiter = $0 }
        step("started")
    }

    /// Adds text to the conversation. Dropped once the session isn't running.
    func send(_ append: LiveAppend) {
        guard phase == .standby || phase == .active else { return }
        do { try transport.send(append.json()) } catch {
            Self.log.notice("live_append_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks Live to finish and waits for session.closed, so the reason and the
    /// final usage are confirmed. On timeout the connection is dropped and the
    /// usage stays unconfirmed.
    func close(timeout: Duration = .seconds(5)) async -> LiveSessionEnding {
        switch phase {
        case .ended(let ending): return ending
        case .idle, .connecting:
            end(LiveSessionEnding(reason: .closeRequested, usage: nil))
        case .standby, .active:
            let command = ["type": "session.close", "event_id": "jarvis_close_" + UUID().uuidString]
            do { try transport.send(JSONSerialization.data(withJSONObject: command)) } catch {
                Self.log.notice("live_close_send_failed \(error.localizedDescription, privacy: .public)")
            }
            phase = .closing
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled, self.phase == .closing else { return }
                self.end(LiveSessionEnding(reason: .closeRequested, usage: nil))
            }
            defer { deadline.cancel() }
            return await withCheckedContinuation { endWaiters.append($0) }
        case .closing:
            return await withCheckedContinuation { endWaiters.append($0) }
        }
        if case .ended(let ending) = phase { return ending }
        return LiveSessionEnding(reason: .closeRequested, usage: nil)
    }

    private func receive(_ data: Data) {
        let decoded: LiveSessionEvent?
        do { decoded = try LiveSessionEvent.decode(data) } catch {
            Self.log.notice("live_event_undecodable \(String(describing: error), privacy: .public)")
            return
        }
        guard let event = decoded else { return }
        if case .ended = phase { return }
        switch event {
        case .started(let id):
            sessionID = id
            if phase == .connecting { phase = .standby }
            finishStart(.success(()))
        case .resumed:
            if phase == .standby { phase = .active }
        case .paused:
            if phase == .active { phase = .standby }
        case .usage(let usage):
            lastUsage = usage
        case .closed(let reason, let usage):
            end(LiveSessionEnding(reason: reason, usage: usage))
            return
        default: break
        }
        onEvent?(event)
    }

    private func finishStart(_ result: Result<Void, Error>) {
        guard let waiter = startWaiter else { return }
        startWaiter = nil
        waiter.resume(with: result)
    }

    private func end(_ ending: LiveSessionEnding) {
        if case .ended = phase { return }
        let wasRunning = phase != .idle && phase != .connecting
        phase = .ended(ending)
        finishStart(.failure(LiveSessionError.endedBeforeStart))
        transport.close()
        pump?.cancel(); pump = nil
        let waiters = endWaiters
        endWaiters = []
        waiters.forEach { $0.resume(returning: ending) }
        if wasRunning { onEvent?(.closed(reason: ending.reason, usage: ending.usage)) }
    }
}

enum LiveSessionError: LocalizedError, Equatable {
    case startTimedOut, endedBeforeStart

    var errorDescription: String? {
        switch self {
        case .startTimedOut: return "The voice session didn't start in time."
        case .endedBeforeStart: return "The voice session ended before it started."
        }
    }
}
