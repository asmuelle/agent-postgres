import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// SSHTunnelResolver (iOS) — turn a Postgres profile's *inline* SSH tunnel
// config into a live SSH connection id the Rust ConnectionManager holds.
//
// The macOS app references a saved SSH `ConnectionProfile` (its terminal
// subsystem: ConnectionStoreManager / CredentialResolver / key vault, none of
// which ship on iOS). iOS instead stores the SSH endpoint inline on the
// Postgres profile (`PostgresTunnel.ssh*`), so this resolver builds an
// ephemeral `ConnectionProfile`, pulls credentials from the Keychain, opens
// the SSH connection via the shared `BridgeManager.connect`, and returns the
// canonical connection id `FfiPgTunnel.sshConnectionId` requires.
//
// Type name matches the macOS resolver in PgAgentApp/SSHTunnelResolver.swift so
// the shared BridgeManager+Postgres call site compiles on both platforms; the
// two live in separate targets, so there is no collision.
// =============================================================================
@MainActor
enum SSHTunnelResolver {
    enum ResolveError: LocalizedError {
        case notInline
        case incompleteConfig
        case passwordUnavailable(host: String)
        case keyUnavailable(host: String)
        case keyMaterializeFailed(String)
        case connectFailed(host: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .notInline:
                return "This SSH tunnel has no endpoint configured. Edit the connection and set up the SSH tunnel section."
            case .incompleteConfig:
                return "The SSH tunnel is missing a host or username. Edit the connection and complete the SSH tunnel section."
            case .passwordUnavailable(let host):
                return "No saved SSH password for \(host). Edit the connection and re-enter the SSH password."
            case .keyUnavailable(let host):
                return "No saved SSH private key for \(host). Edit the connection and import the private key again."
            case .keyMaterializeFailed(let detail):
                return "Couldn't prepare the SSH private key: \(detail)"
            case .connectFailed(let host, let detail):
                return "Opening the SSH tunnel to \(host) failed: \(detail)"
            }
        }
    }

    /// Connection ids opened by this resolver, keyed by the tunnel's synthetic
    /// `sshConnectionId`. Revalidated against the Rust manager before every
    /// reuse — a dropped session is reopened, not assumed.
    private static var liveConnections: [String: String] = [:]

    /// Reclaim bookkeeping: how many live Postgres connections use each SSH
    /// tunnel, and which tunnel each Postgres connection uses — so the SSH
    /// connection is closed once its last Postgres consumer disconnects.
    private static var tunnelRefCounts: [String: Int] = [:]   // ssh key -> count
    private static var pgToSshKey: [String: String] = [:]     // pg conn id -> ssh key

    private static let logger = Logger(subsystem: "com.mc-ssh", category: "ssh-tunnel-resolver-mobile")

    /// A stable per-tunnel session suffix keeps the tunnel's SSH connection
    /// keyed separately and shared across Postgres profiles that tunnel
    /// through the same endpoint.
    private static let sessionSuffix = "pg-tunnel"

    static func liveConnectionId(for tunnel: PostgresTunnel) async throws -> String {
        guard tunnel.isInline else { throw ResolveError.notInline }
        guard let sshHost = tunnel.sshHost, !sshHost.isEmpty,
              let sshUser = tunnel.sshUser, !sshUser.isEmpty
        else {
            throw ResolveError.incompleteConfig
        }

        let cacheKey = tunnel.sshConnectionId
        if let cached = liveConnections[cacheKey],
           rshellIsConnected(connectionId: cached)
        {
            return cached
        }

        let connectionId = try await open(tunnel, sshHost: sshHost, sshUser: sshUser)
        liveConnections[cacheKey] = connectionId
        return connectionId
    }

    /// Record that a Postgres connection now depends on `tunnel`'s SSH
    /// connection. Ignored for tunnels this resolver didn't open, or a
    /// duplicate register for the same Postgres connection.
    static func registerTunnelUse(pgConnectionId: String, tunnel: PostgresTunnel) {
        let key = tunnel.sshConnectionId
        guard liveConnections[key] != nil, pgToSshKey[pgConnectionId] == nil else { return }
        pgToSshKey[pgConnectionId] = key
        tunnelRefCounts[key, default: 0] += 1
    }

    /// Drop a Postgres connection's dependency; closes the SSH connection once
    /// no Postgres connection uses it anymore.
    static func releaseTunnelUse(pgConnectionId: String) {
        guard let key = pgToSshKey.removeValue(forKey: pgConnectionId) else { return }
        let count = tunnelRefCounts[key] ?? 0
        if count <= 1 {
            tunnelRefCounts.removeValue(forKey: key)
            if let sshId = liveConnections.removeValue(forKey: key) {
                BridgeManager.shared.disconnect(connectionId: sshId)
                logger.log("Closed idle SSH tunnel host connection: \(sshId, privacy: .public)")
            }
        } else {
            tunnelRefCounts[key] = count - 1
        }
    }

    private static func open(
        _ tunnel: PostgresTunnel,
        sshHost: String,
        sshUser: String
    ) async throws -> String {
        let sshPort = tunnel.sshPort ?? 22
        let account = tunnel.sshKeychainAccount ?? "\(sshUser)@\(sshHost):\(sshPort)"
        let auth = tunnel.sshAuth ?? .password

        let profile = ConnectionProfile(
            name: "pg-tunnel \(sshHost)",
            host: sshHost,
            port: sshPort,
            username: sshUser,
            authMethod: auth == .password ? .password : .publicKey,
            kind: .ssh
        )

        var password: String?
        var passphrase: String?
        var materializedKey: MaterializedSSHKey?

        switch auth {
        case .password:
            guard let stored = KeychainManager.shared.loadPassword(kind: .sshPassword, account: account),
                  !stored.isEmpty
            else {
                throw ResolveError.passwordUnavailable(host: sshHost)
            }
            password = stored

        case .privateKey:
            guard let pem = MobileSSHKeyStore.load(account: account), !pem.isEmpty else {
                throw ResolveError.keyUnavailable(host: sshHost)
            }
            do {
                materializedKey = try MaterializedSSHKey(pem: pem)
            } catch {
                throw ResolveError.keyMaterializeFailed(error.localizedDescription)
            }
            // An empty stored passphrase means an unencrypted key — pass nil.
            let storedPassphrase = KeychainManager.shared.loadPassword(kind: .sshKeyPassphrase, account: account)
            passphrase = (storedPassphrase?.isEmpty == false) ? storedPassphrase : nil
        }
        defer { materializedKey?.remove() }

        do {
            let connectionId = try await BridgeManager.shared.connect(
                profile: profile,
                password: password,
                keyPath: materializedKey?.path,
                passphrase: passphrase,
                useAgent: false,
                agentIdentityHint: nil,
                sessionId: sessionSuffix
            )
            logger.log("Opened SSH tunnel host connection: \(connectionId, privacy: .public)")
            return connectionId
        } catch {
            throw ResolveError.connectFailed(
                host: sshHost,
                detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}

/// A private key PEM written to a short-lived, file-protected temp file so
/// russh (which loads a key by *path*, not by bytes) can read it, then removed
/// once the connect completes.
private struct MaterializedSSHKey {
    let path: String
    private let url: URL

    init(pem: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pg-tunnel-\(UUID().uuidString).pem")
        // `.completeFileProtection` encrypts the file at rest; the connect
        // runs foregrounded (device unlocked) so the read always succeeds.
        try Data(pem.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        self.url = url
        self.path = url.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
