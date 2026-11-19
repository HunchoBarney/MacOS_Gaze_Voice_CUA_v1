import Foundation

final class C2DraftJob: @unchecked Sendable {
    struct Content: Codable, Equatable, Sendable {
        let recipient: String
        let subject: String
        let body: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.recipient.utf8.elementsEqual(rhs.recipient.utf8)
                && lhs.subject.utf8.elementsEqual(rhs.subject.utf8)
                && lhs.body.utf8.elementsEqual(rhs.body.utf8)
        }
    }

    struct Location: Codable, Equatable, Sendable {
        let targetID: UUID
        let draftID: UUID
    }

    struct Draft: Codable, Sendable {
        let taskID: UUID
        let attemptID: UUID
        let location: Location
        let content: Content
    }

    struct Ask: Equatable, Sendable {
        let taskID: UUID
        let askID: UUID
        let deadline: ContinuousClock.Instant
    }

    enum Decision: Equatable, Sendable {
        case approve
        case decline
    }

    enum Outcome: Equatable, Sendable {
        enum Failure: Equatable, Sendable {
            case writeFailed
            case readFailed
            case missingDraft
            case identityMismatch
            case contentMismatch
        }

        case declined
        case cancelledBeforeDispatch
        case interruptedUnverified
        case unverified(Failure)
        case done
    }

    typealias Writer = @Sendable (Draft) async throws -> Void
    typealias Reopener = @Sendable (Location) async throws -> Draft?

    let ask: Ask
    let location: Location
    let content: Content

    private enum State {
        case awaitingDecision
        case queued(AsyncStream<Outcome>.Continuation)
        case dispatched(AsyncStream<Outcome>.Continuation)
        case finished(Outcome)
    }

    private let write: Writer
    private let reopen: Reopener
    private let lock = NSLock()
    private var state: State = .awaitingDecision
    private var worker: Task<Void, Never>?

    init(targetID: UUID, content: Content, approvalDeadline: ContinuousClock.Instant, taskID: UUID = UUID(), askID: UUID = UUID(),
         write: @escaping Writer, reopen: @escaping Reopener) {
        ask = Ask(taskID: taskID, askID: askID, deadline: approvalDeadline)
        location = Location(targetID: targetID, draftID: UUID())
        self.content = content
        self.write = write
        self.reopen = reopen
    }

    var outcome: Outcome? {
        lock.withLock {
            guard case .finished(let result) = state else { return nil }
            return result
        }
    }

    func answer(_ answerTo: Ask, with decision: Decision) async -> Outcome? {
        let (results, continuation) = AsyncStream<Outcome>.makeStream()
        let accepted = lock.withLock {
            guard case .awaitingDecision = state,
                  answerTo == ask, ContinuousClock.now < ask.deadline else { return false }
            if decision == .decline {
                finish(.declined, continuation: continuation)
            } else {
                state = .queued(continuation)
            }
            return true
        }
        guard accepted else {
            continuation.finish()
            return nil
        }
        guard decision == .approve else { return .declined }

        return await withTaskCancellationHandler {
            lock.withLock {
                if case .queued = state, !Task.isCancelled {
                    worker = Task { await persist() }
                }
            }
            var iterator = results.makeAsyncIterator()
            if let result = await iterator.next() { return result }
            cancel()
            return outcome
        } onCancel: {
            cancel()
        }
    }

    func waitForWorkerToFinish() async {
        let running = lock.withLock { worker }
        await running?.value
    }

    func cancel() {
        lock.withLock {
            switch state {
            case .awaitingDecision:
                state = .finished(.cancelledBeforeDispatch)
            case .queued(let continuation):
                finish(.cancelledBeforeDispatch, continuation: continuation)
            case .dispatched(let continuation):
                finish(.interruptedUnverified, continuation: continuation)
            case .finished:
                break
            }
        }
    }

    private func persist() async {
        let draft = Draft(taskID: ask.taskID, attemptID: UUID(), location: location, content: content)
        let dispatched = lock.withLock {
            guard case .queued(let continuation) = state else { return false }
            state = .dispatched(continuation)
            return true
        }
        guard dispatched else { return }

        do {
            try await write(draft)
        } catch {
            complete(.unverified(.writeFailed))
            return
        }

        guard outcome == nil else { return }
        do {
            guard let saved = try await reopen(location) else {
                complete(.unverified(.missingDraft))
                return
            }
            guard saved.taskID == draft.taskID,
                  saved.attemptID == draft.attemptID,
                  saved.location == draft.location else {
                complete(.unverified(.identityMismatch))
                return
            }
            complete(saved.content == draft.content ? .done : .unverified(.contentMismatch))
        } catch {
            complete(.unverified(.readFailed))
        }
    }

    private func complete(_ result: Outcome) {
        lock.withLock {
            guard case .dispatched(let continuation) = state else { return }
            finish(result, continuation: continuation)
        }
    }

    private func finish(_ result: Outcome, continuation: AsyncStream<Outcome>.Continuation) {
        state = .finished(result)
        continuation.yield(result)
        continuation.finish()
    }
}
