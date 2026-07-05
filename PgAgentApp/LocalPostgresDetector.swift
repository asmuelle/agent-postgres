import Foundation
import Network

/// First-run helper (roadmap 2.1): detect a locally running PostgreSQL by
/// probing 127.0.0.1:5432 with a bare TCP connect — no SQL, no handshake,
/// non-blocking, bounded at ~300 ms. Used only when the connection list is
/// empty, to offer a one-click localhost profile.
enum LocalPostgresDetector {

    static let defaultTimeout: TimeInterval = 0.3

    /// True if `host:port` accepts a TCP connection within `timeout`.
    static func probe(
        host: String = "127.0.0.1",
        port: UInt16 = 5432,
        timeout: TimeInterval = defaultTimeout
    ) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host), port: nwPort, using: .tcp
            )
            // NWConnection fires state changes from its queue and the
            // timeout fires from another — guard the single-shot resume.
            let resumeLock = NSLock()
            var resumed = false
            func finish(_ result: Bool) {
                resumeLock.lock()
                let shouldResume = !resumed
                resumed = true
                resumeLock.unlock()
                guard shouldResume else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                case .waiting:
                    // "waiting" means no listener right now (connection
                    // refused / unreachable) — for a 300 ms local probe
                    // that's a miss, not something to wait out.
                    finish(false)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            let queue = DispatchQueue(label: "com.pgagent.local-pg-probe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    /// The ready-to-edit profile offered when a local server is detected:
    /// current macOS username (Homebrew/Postgres.app superuser default),
    /// `postgres` database, no password, TLS `prefer` (local servers
    /// usually run with ssl=off, and loopback traffic never leaves the
    /// machine — `.require` would fail out of the box).
    static func makeLocalhostProfile() -> PostgresProfile {
        PostgresProfile(
            name: "Local PostgreSQL",
            host: "127.0.0.1",
            port: 5432,
            database: "postgres",
            user: NSUserName(),
            auth: .keychain,
            tls: .prefer,
            environment: .development
        )
    }
}
