import Foundation
import Synchronization

final class LockedBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    var value: Value { storage.withLock { $0 } }
    func set(_ value: Value) { storage.withLock { $0 = value } }
}

final class CallbackCell<Value: Sendable>: Sendable {
    private let storage: Mutex<(@Sendable (Value) -> Void)?>
    init(_ body: (@Sendable (Value) -> Void)? = nil) { storage = Mutex(body) }
    func set(_ body: (@Sendable (Value) -> Void)?) { storage.withLock { $0 = body } }
    func get() -> (@Sendable (Value) -> Void)? { storage.withLock { $0 } }
    func call(_ value: Value) { get()?(value) }
}

final class VoidCallbackCell: Sendable {
    private let storage: Mutex<(@Sendable () -> Void)?>
    init(_ body: (@Sendable () -> Void)? = nil) { storage = Mutex(body) }
    func set(_ body: (@Sendable () -> Void)?) { storage.withLock { $0 = body } }
    func get() -> (@Sendable () -> Void)? { storage.withLock { $0 } }
    func call() { get()?() }
}

/// Unstructured work may outlive a timeout (CoreML cannot always cancel);
/// only the first completion can resume the caller or publish its result.
private final class VoiceDeadlineCompletion<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, Error>?
        var continuation: CheckedContinuation<Value, Error>?
        var tasks: [Task<Void, Never>] = []
    }
    private let storage = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result = storage.withLock { state -> Result<Value, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func installTasks(_ tasks: [Task<Void, Never>]) {
        let cancel = storage.withLock { state -> Bool in
            guard state.result == nil else { return true }
            state.tasks = tasks
            return false
        }
        if cancel { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<Value, Error>) {
        let pending = storage.withLock { state -> (CheckedContinuation<Value, Error>?, [Task<Void, Never>])? in
            guard state.result == nil else { return nil }
            state.result = result
            let pending = (state.continuation, state.tasks)
            state.continuation = nil; state.tasks = []
            return pending
        }
        guard let pending else { return }
        pending.0?.resume(with: result)
        pending.1.forEach { $0.cancel() }
    }
}

func withVoiceDeadline<Value: Sendable>(
    until deadline: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let completion = VoiceDeadlineCompletion<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let worker = Task {
                do { completion.finish(.success(try await operation())) }
                catch { completion.finish(.failure(error)) }
            }
            let timer = Task {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    catch { return }
                }
                completion.finish(.failure(LocalSpeechError.deadline))
            }
            completion.installTasks([worker, timer])
        }
    } onCancel: {
        completion.finish(.failure(CancellationError()))
    }
}
