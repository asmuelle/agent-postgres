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
//      Rust manager still holds it (`rshellIsConnected`).
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

    /// Connection ids opened by this resolver, keyed by SSH profile id.
    /// Validated against the Rust manager before every reuse — a
    /// dropped/disconnected session is reopened, not assumed.
    private static var liveConnections: [String: String] = [:]

    private static let logger = Logger(subsystem: "com.mc-ssh", category: "ssh-tunnel-resolver")

    /// Resolve `reference` — normally an SSH profile id; tolerated as a
    /// raw live connection id for forward compatibility — to an open
    /// connection's id, connecting if necessary.
    static func liveConnectionId(forSSHProfileReference reference: String) async throws -> String {
        guard
            let sshProfile = ConnectionStoreManager.shared.connections
                .first(where: { $0.id == reference })
        else {
            // Not a known profile: accept a value that already names a
            // live connection (an id another surface opened), else the
            // reference is stale.
            if rshellIsConnected(connectionId: reference) {
                return reference
            }
            throw ResolveError.profileMissing(reference)
        }

        if let cached = liveConnections[sshProfile.id],
           rshellIsConnected(connectionId: cached)
        {
            return cached
        }

        let connectionId = try await open(sshProfile)
        liveConnections[sshProfile.id] = connectionId
        return connectionId
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
