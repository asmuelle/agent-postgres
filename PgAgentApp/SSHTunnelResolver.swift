import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// SSHTunnelResolver — turn a saved SSH *profile* id into a live SSH
// *connection* id the Rust ConnectionManager actually holds.
//
// Why this exists: `FfiPgTunnel.sshConnectionId` must be the canonical id
// `rshellConnect` returned (`user@host:port[#session]`). The Postgres
// connection form can only store the picked SSH profile's UUID, and
// passing that through verbatim made every tunnel connect fail with
// "SSH connection is not open" — the tunnel feature never worked.
//
// Resolution order:
//   1. A connection this resolver opened earlier for the profile, if the
//      Rust manager still holds it (`rshellIsConnected`, checked off-main).
//   2. Auto-open: stored Keychain credentials / key vault / agent via the
//      same CredentialResolver + SSHKeyAccessCoordinator the SSH flows
//      use — silently (no prompts). Password profiles without a stored
//      password fail with a message telling the user what to do.
// =============================================================================

@MainActor
enum SSHTunnelResolver {
    enum ResolveError: LocalizedError {
        case profileMissing(String)
        case credentialsUnavailable(name: String)
        case keyAccess(name: String, detail: String)
        case connectFailed(name: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .profileMissing(let id):
                return "The SSH profile this tunnel references (\(id)) no longer exists. Edit the Postgres connection and pick an SSH connection again."
            case .credentialsUnavailable(let name):
                return "No stored password for SSH profile “\(name)”. Save the password to the Keychain (or switch the profile to key/agent auth), then retry."
            case .keyAccess(let name, let detail):
                return "Can't access the SSH key for “\(name)”: \(detail)"
            case .connectFailed(let name, let detail):
                return "Opening SSH connection “\(name)” failed: \(detail)"
            }
        }
    }

    /// A resolved tunnel plus the use counted for it. Obtain with
    /// `acquireTunnel(for:)` before the Postgres connect is awaited, then
    /// either `bindTunnelUse` (connect succeeded) or `cancelTunnelUse`
    /// (connect failed) — exactly once.
    struct TunnelLease: Sendable {
        let liveConnectionId: String
        /// Nil for a tunnel this resolver didn't open (a raw live id another
        /// surface owns) — nothing to count or reclaim.
        fileprivate let reservation: SSHTunnelUseLedger.Reservation?
    }

    /// Connection ids opened by this resolver, keyed by SSH profile id.
    /// Validated against the Rust manager before every reuse — a
    /// dropped/disconnected session is reopened, not assumed.
    private static var liveConnections: [String: String] = [:]

    /// Reclaim bookkeeping: how many Postgres connections (live or still
    /// connecting) use each SSH tunnel, so the SSH connection is closed once
    /// its last Postgres consumer disconnects.
    private static var ledger = SSHTunnelUseLedger()

    /// Every open for a profile uses the same fixed session id, i.e. the same
    /// Rust connection key; a second concurrent open would replace (and so
    /// disconnect) the first. Concurrent callers share one open instead.
    private static let opens = InFlightTaskCoalescer<String, String>()

    /// A resolved-then-closed race can repeat only if the tunnel keeps being
    /// torn down underneath us; give up after a few rounds instead of looping.
    private static let maxResolveAttempts = 3

    private static let logger = Logger(subsystem: "com.mc-ssh", category: "ssh-tunnel-resolver")

    /// Resolve a Postgres profile's tunnel to an open SSH connection's id.
    /// On macOS the tunnel references a saved SSH profile, so this delegates
    /// to the profile-id resolution path. (The iOS resolver reads the tunnel's
    /// inline SSH endpoint instead.)
    static func liveConnectionId(for tunnel: PostgresTunnel) async throws -> String {
        try await liveConnectionId(forSSHProfileReference: tunnel.sshConnectionId)
    }

    /// Resolve `reference` — normally an SSH profile id; tolerated as a
    /// raw live connection id for forward compatibility — to an open
    /// connection's id, connecting if necessary. No use is counted: the
    /// connection stays open until a counted Postgres user releases it.
    static func liveConnectionId(forSSHProfileReference reference: String) async throws -> String {
        try await resolve(reference: reference, countUse: false).liveConnectionId
    }

    /// Resolve `tunnel` to a live SSH connection and count a use of it in the
    /// same main-actor step, so no concurrent release can close it before the
    /// caller's Postgres connect finishes.
    static func acquireTunnel(for tunnel: PostgresTunnel) async throws -> TunnelLease {
        try await resolve(reference: tunnel.sshConnectionId, countUse: true)
    }

    private static func resolve(reference: String, countUse: Bool) async throws -> TunnelLease {
        guard
            let sshProfile = ConnectionStoreManager.shared.connections
                .first(where: { $0.id == reference })
        else {
            // Not a known profile: accept a value that already names a
            // live connection (an id another surface opened), else the
            // reference is stale.
            if await isConnected(reference) {
                return TunnelLease(liveConnectionId: reference, reservation: nil)
            }
            throw ResolveError.profileMissing(reference)
        }

        let key = sshProfile.id
        for _ in 0..<maxResolveAttempts {
            if let cached = liveConnections[key] {
                let alive = await isConnected(cached)
                // Re-check after the hop: a release may have closed (or an
                // open replaced) the cached connection meanwhile.
                guard liveConnections[key] == cached else { continue }
                if alive {
                    return lease(connectionId: cached, key: key, countUse: countUse)
                }
                liveConnections.removeValue(forKey: key)
            }

            let opened = try await opens.run(key: key) {
                let connectionId = try await open(sshProfile)
                liveConnections[key] = connectionId
                return connectionId
            }
            if liveConnections[key] == opened {
                return lease(connectionId: opened, key: key, countUse: countUse)
            }
            // Closed again before this waiter resumed — resolve afresh.
        }
        throw ResolveError.connectFailed(
            name: sshProfile.name,
            detail: "The SSH connection closed while the tunnel was being set up."
        )
    }

    private static func lease(connectionId: String, key: String, countUse: Bool) -> TunnelLease {
        TunnelLease(
            liveConnectionId: connectionId,
            reservation: countUse ? ledger.reserve(key: key) : nil
        )
    }

    /// Bind a lease's use to the Postgres connection it produced.
    static func bindTunnelUse(_ lease: TunnelLease, pgConnectionId: String) {
        guard let reservation = lease.reservation else { return }
        closeIfUnused(ledger.bind(reservation, pgConnectionId: pgConnectionId))
    }

    /// Drop a lease whose Postgres connect failed.
    static func cancelTunnelUse(_ lease: TunnelLease) {
        guard let reservation = lease.reservation else { return }
        closeIfUnused(ledger.cancel(reservation))
    }

    /// Drop a Postgres connection's dependency; closes the SSH connection once
    /// no Postgres connection uses it anymore.
    static func releaseTunnelUse(pgConnectionId: String) {
        closeIfUnused(ledger.release(pgConnectionId: pgConnectionId))
    }

    private static func closeIfUnused(_ key: String?) {
        guard let key, let sshId = liveConnections.removeValue(forKey: key) else { return }
        // An open in flight for this key reuses the same Rust connection key
        // and replaces this connection itself; disconnecting now would kill
        // the replacement instead.
        guard !opens.isInFlight(key) else { return }
        BridgeManager.shared.disconnect(connectionId: sshId)
        logger.log("Closed idle SSH tunnel host connection: \(sshId, privacy: .public)")
    }

    /// `rshellIsConnected` blocks on the Rust runtime — keep it off the main actor.
    private static func isConnected(_ connectionId: String) async -> Bool {
        await Task.detached(priority: .utility) {
            rshellIsConnected(connectionId: connectionId)
        }.value
    }

    private static func open(_ sshProfile: ConnectionProfile) async throws -> String {
        // Silent credential resolution — a Postgres connect is not the
        // place to pop SSH password sheets, so prompts resolve to nil
        // and surface as a clear, actionable error instead.
        let resolver = CredentialResolver(
            profile: sshProfile,
            passwordProvider: { _, _ in nil },
            passphraseProvider: { _ in nil }
        )
        guard let credential = await resolver.resolve() else {
            throw ResolveError.credentialsUnavailable(name: sshProfile.name)
        }

        var prepared: PreparedSSHKey? = nil
        if sshProfile.authMethod == .publicKey {
            do {
                prepared = try await SSHKeyAccessCoordinator.prepare(
                    sshProfile.sshKeyReference,
                    profile: sshProfile,
                    sessionId: nil
                )
            } catch {
                throw ResolveError.keyAccess(
                    name: sshProfile.name,
                    detail: error.localizedDescription
                )
            }
        }
        defer { prepared?.stop() }

        do {
            // A stable per-profile session suffix keeps the tunnel's SSH
            // connection keyed separately from terminal tabs (so closing
            // a terminal can't tear the tunnel down) while letting every
            // Postgres profile that tunnels through the same SSH profile
            // share one connection.
            let connectionId = try await BridgeManager.shared.connect(
                profile: sshProfile,
                password: credential.password,
                keyPath: prepared?.keyPath,
                passphrase: credential.passphrase,
                useAgent: prepared?.useAgent ?? false,
                agentIdentityHint: prepared?.agentIdentityHint,
                sessionId: "pg-tunnel"
            )
            logger.log("Opened SSH tunnel host connection: \(connectionId, privacy: .public)")
            return connectionId
        } catch {
            throw ResolveError.connectFailed(
                name: sshProfile.name,
                detail: (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
        }
    }
}
