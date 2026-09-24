import Foundation

// =============================================================================
// Small main-actor concurrency primitives shared by the connection layers.
//
// - InFlightTaskCoalescer: concurrent callers asking for the same key share one
//   in-flight operation instead of racing duplicate ones (e.g. two Postgres
//   profiles tunnelling through the same bastion both opening the SSH
//   connection — the second open replaced, and so killed, the first).
// - SerialAsyncQueue: runs operations strictly one after another, so a
//   refresh can never overlap another refresh or a shutdown.
// =============================================================================

@MainActor
final class InFlightTaskCoalescer<Key: Hashable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Error>] = [:]

    init() {}

    /// True while an operation for `key` is running.
    func isInFlight(_ key: Key) -> Bool {
        inFlight[key] != nil
    }

    /// Run `operation` for `key`, or join the one already running. The shared
    /// operation is unstructured, so one waiter's cancellation never cancels
    /// it for the others.
    func run(
        key: Key,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { @MainActor in
            try await operation()
        }
        inFlight[key] = task
        defer {
            if inFlight[key] == task { inFlight.removeValue(forKey: key) }
        }
        return try await task.value
    }
}

@MainActor
final class SerialAsyncQueue {
    private var tail: Task<Void, Never>?

    init() {}

    /// Enqueue `operation` after everything already enqueued and wait for it.
    /// Never call from inside an operation on the same queue (it would wait on
    /// itself).
    func run(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }
}
