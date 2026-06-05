import Combine
import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresConnectionStatusStore — one tiny ObservableObject that tracks
// which Postgres profile ids currently have a live connection in the
// app.
//
// Why a separate store rather than reading `BridgeManager` state:
// `BridgeManager` doesn't expose its connection map, and the Postgres
// workspace already has a clean lifecycle hook (connect / disconnect)
// to call into. Keeping the store profile-id-keyed (not connection-id-
// keyed) means the sidebar — which knows profile ids, not connection
// ids — can render directly.
//
// State is UI-only: not persisted, lost on app launch, recovered when
// the user reopens a workspace and the connection establishes again.
// =============================================================================

/// Liveness state for a profile's workspace. The `error` case
/// carries the user-visible message so the sidebar tooltip can
/// surface it without a separate lookup.
enum PostgresWorkspaceStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

@MainActor
final class PostgresConnectionStatusStore: ObservableObject {
    static let shared = PostgresConnectionStatusStore()

    @Published private(set) var statusByProfile: [String: PostgresWorkspaceStatus] = [:]

    private var eventSubscription: AnyCancellable?

    private init() {
        // Subscribe to the central FFI event bus so connection
        // status events emitted by the Rust side (Connected,
        // Disconnected, Error) reflect in the sidebar dot. The
        // workspace's explicit `markConnecting/markConnected/etc`
        // calls still fire — the bus subscription is additive,
        // catching events the workspace doesn't see (e.g. an
        // unexpected wire close).
        eventSubscription = PgAgentEventBus.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard case let .connectionStatus(connectionId, payload) = event,
                      connectionId.hasPrefix("pg:")
                else { return }
                self?.handleBusEvent(connectionId: connectionId, payload: payload)
            }
    }

    /// Translate a Rust-side connection_id (`pg:user@host:port/db#profileId`)
    /// to a profile id. Current ids carry the profile id suffix; the
    /// endpoint match is retained for older bare ids.
    private func profileId(forConnectionId connectionId: String) -> String? {
        let profiles = PostgresProfileStore.shared.profiles
        if let suffixStart = connectionId.lastIndex(of: "#") {
            let suffixIndex = connectionId.index(after: suffixStart)
            let candidate = String(connectionId[suffixIndex...])
            if profiles.contains(where: { $0.id == candidate }) {
                return candidate
            }
        }
        return profiles.first { p in
            "pg:\(p.user)@\(p.host):\(p.port)/\(p.database)" == connectionId
        }?.id
    }

    private func handleBusEvent(connectionId: String, payload: String) {
        guard let profileId = profileId(forConnectionId: connectionId) else { return }
        // Payload format from `mc-ssh-macos/src/ffi.rs`:
        //   {"status":"connected"} | {"status":"disconnected"} | {"status":"error"}
        // No detail string in v1; the message is a fixed status
        // word. Parse defensively: anything we don't recognize
        // means leave the existing status alone.
        let payloadStatus: PostgresWorkspaceStatus?
        if payload.contains("\"connected\"") {
            payloadStatus = .connected
        } else if payload.contains("\"disconnected\"") {
            payloadStatus = .disconnected
        } else if payload.contains("\"error\"") {
            payloadStatus = .error("connection lost")
        } else {
            payloadStatus = nil
        }
        guard let newStatus = payloadStatus else { return }
        // Don't overwrite a more-specific in-app `connecting` /
        // `error(message)` with a generic event-bus update arriving
        // afterward. The bus delivers the same Connected event the
        // workspace already set, so this is mostly a no-op for the
        // happy path; the value is in catching unexpected drops.
        if newStatus == .connected, statusByProfile[profileId] == .connecting {
            // Workspace already saw the success; bus is duplicative.
            return
        }
        setStatus(newStatus, profileId: profileId)
    }

    func setStatus(_ status: PostgresWorkspaceStatus, profileId: String) {
        if status == .disconnected {
            // `.disconnected` is the default; drop the entry rather
            // than store it so a long-running session doesn't grow
            // a map of zero-value entries for every profile ever
            // touched.
            statusByProfile.removeValue(forKey: profileId)
        } else {
            statusByProfile[profileId] = status
        }
    }

    func status(forProfile profileId: String) -> PostgresWorkspaceStatus {
        statusByProfile[profileId] ?? .disconnected
    }

    // Legacy helpers for the existing callers (browser view marks
    // connect/disconnect; older readers asked `isConnected`).
    func markConnected(profileId: String) {
        setStatus(.connected, profileId: profileId)
    }

    func markConnecting(profileId: String) {
        setStatus(.connecting, profileId: profileId)
    }

    func markError(_ message: String, profileId: String) {
        setStatus(.error(message), profileId: profileId)
    }

    func markDisconnected(profileId: String) {
        setStatus(.disconnected, profileId: profileId)
    }

    func isConnected(profileId: String) -> Bool {
        status(forProfile: profileId) == .connected
    }
}
