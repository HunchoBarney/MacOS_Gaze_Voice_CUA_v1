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

/// How a session ended. Without session.closed the final usage is unconfirmed
/// and the last usage report stands in for it.
struct LiveSessionEnding: Equatable, Sendable {
    let reason: LiveCloseReason?
    let usage: LiveUsage?
    var confirmed: Bool { reason != nil }
}

enum LiveSessionUpdate: Equatable, Sendable {
    case started(sessionID: String)
    case resumed
    case paused
    case usage(LiveUsage)
    case inputTranscript(LiveTranscriptDelta)
    case outputTranscript(LiveTranscriptDelta)
    case error(LiveError)
    case ended(LiveSessionEnding)
}

/// One GPT-Live session over a transport: create it through the broker, wait
/// for session.started, follow standby and resume, and close it gracefully so
/// the final usage is confirmed. Nothing here acts on what is heard.
@MainActor
final class LiveSession {
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
    private(set) var lastUsage: LiveUsage?
    /// How long each step of the last start took: the offer (ICE gathered),
    /// the broker's session creation, applying the answer, and session.started.
    private(set) var startSteps: [(step: String, seconds: Double)] = []
    var onUpdate: ((LiveSessionUpdate) -> Void)?

    private let transport: LiveTransport
    private let broker: LiveSessionCreating
    private let config: LiveSessionConfig
    private var pump: Task<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var endWaiters: [CheckedContinuation<LiveSessionEnding, Never>] = []
    private var eventCount = 0

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
            let now = clock.now
            let elapsed = now - mark
            startSteps.append((name, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
            mark = now
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
            end(LiveSessionEnding(reason: nil, usage: nil))
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
                    self.end(LiveSessionEnding(reason: nil, usage: self.lastUsage))
                }
            }
        }
        if case .ended = phase { throw LiveSessionError.endedBeforeStart }
        if phase != .connecting { step("started"); return }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, self.phase == .connecting else { return }
            self.finishStart(.failure(LiveSessionError.startTimedOut))
            self.end(LiveSessionEnding(reason: nil, usage: self.lastUsage))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { startWaiter = $0 }
        step("started")
    }

    /// Sends a command on the data channel and returns its event id, which
    /// errors and acknowledgements quote back as client_event_id.
    @discardableResult
    func send(_ command: LiveClientCommand) throws -> String {
        guard phase == .standby || phase == .active else { throw LiveSessionError.notRunning }
        eventCount += 1
        let id = "jarvis_\(eventCount)"
        try transport.send(command.json(eventID: id))
        return id
    }

    /// Asks Live to finish and waits for session.closed, so the reason and the
    /// final usage are confirmed. On timeout the connection is dropped and the
    /// ending is unconfirmed.
    func close(timeout: Duration = .seconds(5)) async -> LiveSessionEnding {
        switch phase {
        case .ended(let ending): return ending
        case .idle, .connecting:
            finishStart(.failure(LiveSessionError.endedBeforeStart))
            end(LiveSessionEnding(reason: nil, usage: lastUsage))
        case .standby, .active:
            do { try send(.close) } catch {
                Self.log.notice("live_close_send_failed \(error.localizedDescription, privacy: .public)")
            }
            phase = .closing
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled, self.phase == .closing else { return }
                self.end(LiveSessionEnding(reason: nil, usage: self.lastUsage))
            }
            defer { deadline.cancel() }
            if case .ended(let ending) = phase { return ending }
            return await withCheckedContinuation { endWaiters.append($0) }
        case .closing:
            return await withCheckedContinuation { endWaiters.append($0) }
        }
        if case .ended(let ending) = phase { return ending }
        return LiveSessionEnding(reason: nil, usage: lastUsage)
    }

    private func receive(_ data: Data) {
        let event: LiveServerEvent
        do { event = try LiveServerEvent(json: data) } catch {
            Self.log.notice("live_event_undecodable \(String(describing: error), privacy: .public)")
            return
        }
        if case .ended = phase { return }
        switch event {
        case .started(let id):
            sessionID = id
            if phase == .connecting { phase = .standby }
            finishStart(.success(()))
            onUpdate?(.started(sessionID: id))
        case .resumed:
            if phase == .standby { phase = .active }
            onUpdate?(.resumed)
        case .paused:
            if phase == .active { phase = .standby }
            onUpdate?(.paused)
        case .usage(let usage):
            lastUsage = usage
            onUpdate?(.usage(usage))
        case .inputTranscript(let delta): onUpdate?(.inputTranscript(delta))
        case .outputTranscript(let delta): onUpdate?(.outputTranscript(delta))
        case .error(let error): onUpdate?(.error(error))
        case .closed(let reason, let usage):
            lastUsage = usage
            end(LiveSessionEnding(reason: reason, usage: usage))
        case .other: break
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        guard let waiter = startWaiter else { return }
        startWaiter = nil
        waiter.resume(with: result)
    }

    private func end(_ ending: LiveSessionEnding) {
        if case .ended = phase { return }
        phase = .ended(ending)
        finishStart(.failure(LiveSessionError.endedBeforeStart))
        transport.close()
        pump?.cancel(); pump = nil
        let waiters = endWaiters
        endWaiters = []
        waiters.forEach { $0.resume(returning: ending) }
        onUpdate?(.ended(ending))
    }
}

enum LiveSessionError: LocalizedError, Equatable {
    case startTimedOut, endedBeforeStart, notRunning

    var errorDescription: String? {
        switch self {
        case .startTimedOut: return "The voice session didn't start in time."
        case .endedBeforeStart: return "The voice session ended before it started."
        case .notRunning: return "The voice session isn't running."
        }
    }
}
