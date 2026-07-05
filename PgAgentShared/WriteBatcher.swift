import Foundation
import OSLog

/// Coalesces PTY input writes so a paste of N bytes produces one FFI
/// call instead of N. Single keystrokes still flush quickly (~16 ms),
/// so no perceptible latency on interactive input.
///
/// **Threading:** every method must be invoked on the `queue` passed at
/// init (`BridgeManager.dispatchQueue` in practice). The class assumes
/// serial access — no internal locks.
///
/// **Ordering:** a single shared buffer is appended in call order and
/// drained in one `rshellPtyWrite` call, so byte order is preserved.
/// Concurrent writes for different connections live in separate
/// `WriteBatcher` instances and have no ordering relationship by design
/// (different SSH sessions).
final class WriteBatcher {
    private let connectionId: String
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.mc-ssh", category: "write-batch")

    /// Pending bytes waiting to be flushed.
    private var pending = Data()

    /// In-flight flush, if any. Cancelled when we flush eagerly on size
    /// threshold or when a fresh `append` extends the window.
    private var pendingFlush: DispatchWorkItem?

    /// Maximum delay before flushing accumulated bytes. 16 ms ≈ one frame
    /// at 60 fps — below human latency perception for keypresses.
    private static let flushDelay: TimeInterval = 0.016

    /// Eager flush when buffered size exceeds this. A large paste still
    /// gets coalesced into a few calls rather than one giant one, which
    /// would tie up the FFI queue for too long on slow links.
    private static let flushThreshold = 4096

    init(connectionId: String, queue: DispatchQueue) {
        self.connectionId = connectionId
        self.queue = queue
    }

    func append(_ data: Data) {
        pending.append(data)

        // Threshold flush: send now without resetting the timer.
        if pending.count >= Self.flushThreshold {
            flushNow()
            return
        }

        // Reset the timer — coalescing window starts again so a steady
        // stream of writes (`yes` piped into a command, etc.) gets
        // batched up to the threshold rather than firing on every tick.
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        pendingFlush = work
        queue.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
    }

    /// Flush whatever is buffered immediately. Safe to call when empty.
    func flushNow() {
        pendingFlush?.cancel()
        pendingFlush = nil

        guard !pending.isEmpty else { return }
        let chunk = pending
        pending = Data()
        _ = rshellPtyWrite(connectionId: connectionId, data: chunk)
    }
}
