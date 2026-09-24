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
        case identityNotSelected
        case identityMissing
        case identityKeyUnavailable(name: String)
        case identityPassphraseUnavailable(name: String)
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
            case .identityNotSelected:
                return "This SSH tunnel has no identity selected. Edit the connection and pick an SSH identity."
            case .identityMissing:
                return "The SSH identity this tunnel used was deleted. Edit the connection and pick another identity."
            case .identityKeyUnavailable(let name):
                return "The private key for the identity \"\(name)\" is missing from this device's Keychain. Recreate the identity and add its public key to the server."
            case .identityPassphraseUnavailable(let name):
                return "The passphrase for the identity \"\(name)\" couldn't be read from the Keychain. Unlock the device and try again."
            case .keyMaterializeFailed(let detail):
                return "Couldn't prepare the SSH private key: \(detail)"
            case .connectFailed(let host, let detail):
                return "Opening the SSH tunnel to \(host) failed: \(detail)"
            }
        }
    }

    /// A resolved tunnel plus the use counted for it. Obtain with
    /// `acquireTunnel(for:)` before the Postgres connect is awaited, then
    /// either `bindTunnelUse` (connect succeeded) or `cancelTunnelUse`
    /// (connect failed) — exactly once. Same shape as the macOS resolver so
    /// the shared `pgConnect` uses one code path on both platforms.
    struct TunnelLease: Sendable {
        let liveConnectionId: String
        fileprivate let reservation: SSHTunnelUseLedger.Reservation?
    }

    /// Connection ids opened by this resolver, keyed by the tunnel's synthetic
    /// `sshConnectionId`. Revalidated against the Rust manager before every
    /// reuse — a dropped session is reopened, not assumed.
    private static var liveConnections: [String: String] = [:]

    /// Reclaim bookkeeping: how many Postgres connections (live or still
    /// connecting) use each SSH tunnel, so the SSH connection is closed once
    /// its last Postgres consumer disconnects.
    private static var ledger = SSHTunnelUseLedger()

    /// Every open for a tunnel uses the same fixed session id, i.e. the same
    /// Rust connection key; a second concurrent open would replace (and so
    /// disconnect) the first. Concurrent callers share one open instead.
    private static let opens = InFlightTaskCoalescer<String, String>()

    /// A resolved-then-closed race can repeat only if the tunnel keeps being
    /// torn down underneath us; give up after a few rounds instead of looping.
    private static let maxResolveAttempts = 3

    private static let logger = Logger(subsystem: "com.mc-ssh", category: "ssh-tunnel-resolver-mobile")

    /// A stable per-tunnel session suffix keeps the tunnel's SSH connection
    /// keyed separately and shared across Postgres profiles that tunnel
    /// through the same endpoint.
    private static let sessionSuffix = "pg-tunnel"

    /// Resolve `tunnel` to an open SSH connection's id, connecting if needed.
    /// No use is counted.
    static func liveConnectionId(for tunnel: PostgresTunnel) async throws -> String {
        try await resolve(tunnel, countUse: false).liveConnectionId
    }

    /// Resolve `tunnel` to a live SSH connection and count a use of it in the
    /// same main-actor step, so no concurrent release can close it before the
    /// caller's Postgres connect finishes.
    static func acquireTunnel(for tunnel: PostgresTunnel) async throws -> TunnelLease {
        try await resolve(tunnel, countUse: true)
    }

    private static func resolve(_ tunnel: PostgresTunnel, countUse: Bool) async throws -> TunnelLease {
        guard tunnel.isInline else { throw ResolveError.notInline }
        guard let sshHost = tunnel.sshHost, !sshHost.isEmpty,
              let sshUser = tunnel.sshUser, !sshUser.isEmpty
        else {
            throw ResolveError.incompleteConfig
        }

        let key = tunnel.sshConnectionId
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
                let connectionId = try await open(tunnel, sshHost: sshHost, sshUser: sshUser)
                liveConnections[key] = connectionId
                return connectionId
            }
            if liveConnections[key] == opened {
                return lease(connectionId: opened, key: key, countUse: countUse)
            }
            // Closed again before this waiter resumed — resolve afresh.
        }
        throw ResolveError.connectFailed(
            host: sshHost,
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
        var keyPEM: String?

        switch auth {
        case .password:
            guard let stored = await KeychainManager.shared.loadPasswordAsync(kind: .sshPassword, account: account),
                  !stored.isEmpty
            else {
                throw ResolveError.passwordUnavailable(host: sshHost)
            }
            password = stored

        case .privateKey:
            guard let pem = await KeychainStorage.offMain({ MobileSSHKeyStore.load(account: account) }),
                  !pem.isEmpty
            else {
                throw ResolveError.keyUnavailable(host: sshHost)
            }
            keyPEM = pem
            // An empty stored passphrase means an unencrypted key — pass nil.
            let storedPassphrase = await KeychainManager.shared.loadPasswordAsync(kind: .sshKeyPassphrase, account: account)
            passphrase = (storedPassphrase?.isEmpty == false) ? storedPassphrase : nil

        case .identity:
            // A shared identity's key lives under the identity's own account,
            // not this endpoint's — so several tunnels reuse one keypair.
            guard let identityId = tunnel.sshIdentityId else {
                throw ResolveError.identityNotSelected
            }
            guard let identity = MobileSSHIdentityStore.shared.identity(id: identityId) else {
                throw ResolveError.identityMissing
            }
            // Read the key and passphrase off the main thread (keychain I/O
            // can block); same items `privateKeyPEM(id:)`/`passphrase(id:)` read.
            let identityAccount = identity.keychainAccount
            let (storedPem, storedPassphrase) = await KeychainStorage.offMain {
                (MobileSSHKeyStore.load(account: identityAccount),
                 MobileSSHKeyStore.loadPassphrase(account: identityAccount))
            }
            guard let pem = storedPem, !pem.isEmpty else {
                throw ResolveError.identityKeyUnavailable(name: identity.name)
            }
            keyPEM = pem
            passphrase = (storedPassphrase?.isEmpty == false) ? storedPassphrase : nil
            // An encrypted key whose passphrase didn't load would otherwise be
            // handed to russh as if it were unencrypted, surfacing only as an
            // opaque auth rejection. Fail with the real reason instead.
            if identity.isEncrypted, passphrase == nil {
                throw ResolveError.identityPassphraseUnavailable(name: identity.name)
            }
        }

        // Written to disk only once every check passed, and removed on every
        // exit path after that.
        let materializedKey: MaterializedSSHKey?
        do {
            materializedKey = try keyPEM.map { try MaterializedSSHKey(pem: $0) }
        } catch {
            throw ResolveError.keyMaterializeFailed(error.localizedDescription)
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
