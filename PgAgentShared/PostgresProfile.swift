import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// Why a separate model?
// `ConnectionProfile` is heavily SSH-shaped: AuthMethod, sshKeyReference,
// passphrase flows, agent identity hints, monitored systemd services. Adding
// Postgres-only fields (database, sslmode, tunnel ref) would either pollute
// the SSH model with optionals that don't apply, or require codec gymnastics
// to keep older saved stores readable. A parallel `PostgresProfile` keeps the
// SSH model clean and the Postgres model honest. If a unified profile model
// emerges later, both feed into it — but don't speculate now.
// =============================================================================

enum PostgresAuthMethod: Codable, Hashable, Sendable {
    /// Password lives in the keychain under `PostgresProfile.keychainAccount`.
    case keychain
    /// Password lives in the profile (in-memory only). Useful for tests and
    /// throwaway connections; never written to disk.
    case ephemeralPassword(String)

    // The ephemeral password is a runtime-only secret. The default synthesized
    // Codable conformance would serialize it as plaintext if an
    // `.ephemeralPassword` profile were ever persisted (the store does not
    // guard against this). Instead, encode *only* a discriminator and always
    // decode to `.keychain`: the secret can never reach disk, and a persisted
    // ephemeral profile degrades to keychain auth rather than leaking.
    private enum CodingKeys: String, CodingKey { case kind }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("keychain", forKey: .kind)
    }

    init(from decoder: Decoder) throws {
        self = .keychain
    }
}

enum PostgresTlsMode: String, Codable, Sendable, CaseIterable {
    case disable
    case prefer
    case require
    case verifyFull = "verify_full"

    var displayName: String {
        switch self {
        case .disable:     return "Disable"
        case .prefer:      return "Prefer"
        case .require:     return "Require (no verify)"
        case .verifyFull:  return "Verify-full"
        }
    }

    /// One-line explanation shown under the TLS picker. Shared so the macOS
    /// and iOS connection forms can't drift out of sync.
    var hint: String {
        switch self {
        case .disable:
            return "No encryption. Only safe over a private network."
        case .prefer:
            return "Try TLS, fall back to plaintext."
        case .require:
            return "Require TLS but skip certificate verification (encrypts the wire, not authenticates the server)."
        case .verifyFull:
            return "Require TLS and validate the server certificate against the system trust store. Recommended for production."
        }
    }
}

/// Semantic environment tag for a connection. Drives the badge treatment
/// everywhere the profile surfaces (sidebar, tab chrome, mobile rows):
/// production is loud (red capsule), staging/development are subtle,
/// unspecified renders nothing.
enum PostgresEnvironment: String, Codable, CaseIterable, Sendable {
    case unspecified
    case development
    case staging
    case production

    var displayName: String {
        switch self {
        case .unspecified: return "Unspecified"
        case .development: return "Development"
        case .staging:     return "Staging"
        case .production:  return "Production"
        }
    }

    /// Short badge text. `nil` for unspecified (no badge at all).
    var badgeLabel: String? {
        switch self {
        case .unspecified: return nil
        case .development: return "DEV"
        case .staging:     return "STAGING"
        case .production:  return "PRODUCTION"
        }
    }
}

/// SSH authentication method for an inline (iOS) tunnel. macOS tunnels never
/// carry this — they inherit auth from the referenced SSH profile.
enum PostgresTunnelAuth: String, Codable, Hashable, Sendable, CaseIterable {
    case password
    case privateKey

    var displayName: String {
        switch self {
        case .password:   return "Password"
        case .privateKey: return "Private Key"
        }
    }
}

/// Optional SSH tunnel descriptor stored on the profile.
///
/// Two shapes share this type:
///   • macOS references a saved SSH `ConnectionProfile`: `sshConnectionId` is
///     that profile's id, and the inline `ssh*` fields stay nil.
///   • iOS has no SSH connection store, so it stores the SSH endpoint inline
///     (`sshHost`/`sshPort`/`sshUser`/`sshAuth`). There `sshConnectionId` is a
///     synthetic id used only as a Keychain-account and live-connection cache
///     key.
///
/// The live SSH connection is resolved at connect time — so the tunnel
/// survives an SSH reconnect without editing the Postgres profile.
struct PostgresTunnel: Codable, Hashable, Sendable {
    var sshConnectionId: String
    var remoteHost: String
    var remotePort: UInt16

    // Inline SSH endpoint (iOS). Defaults keep the memberwise initializer and
    // decoding of existing macOS profiles working unchanged.
    var sshHost: String? = nil
    var sshPort: UInt16? = nil
    var sshUser: String? = nil
    var sshAuth: PostgresTunnelAuth? = nil

    /// True when the tunnel carries its own SSH endpoint (iOS inline config)
    /// rather than referencing a saved SSH profile (macOS).
    var isInline: Bool { sshHost != nil }

    /// Keychain account for the inline SSH endpoint's credentials
    /// (`user@host:port`, matching `ConnectionProfile.keychainAccount`).
    /// Nil for macOS profile-reference tunnels. The resolver and the mobile
    /// edit form both compute the account through here so they never diverge.
    var sshKeychainAccount: String? {
        guard let sshHost, let sshUser else { return nil }
        return "\(sshUser)@\(sshHost):\(sshPort ?? 22)"
    }
}

struct PostgresProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var database: String
    var user: String
    var auth: PostgresAuthMethod
    var tls: PostgresTlsMode
    var applicationName: String?
    var tunnel: PostgresTunnel?
    var connectTimeoutSecs: UInt64?
    /// Per-profile pool tuning. `nil` inherits the built-in default
    /// (max=5, idle=300s, minIdle=1) — explicit values are surfaced
    /// in the Advanced section of the connection edit form for users
    /// on quota-strict managed providers.
    var maxPoolSize: UInt32?
    var idleTimeoutSecs: UInt64?
    var minIdleConnections: UInt32?
    var folderPath: String?
    var createdAt: Date
    var lastConnected: Date?
    var color: String?
    var notes: String?
    /// Semantic environment tag. Persisted profiles from builds that
    /// predate this field decode as `.unspecified` (see `init(from:)`).
    var environment: PostgresEnvironment
    /// When `true`, the bridge layer refuses every statement that isn't
    /// classified read-only (see `PostgresStatementClassifier`) and the
    /// grid's editing affordances are hidden. Decodes to `false` for
    /// profiles saved before this field existed.
    var isReadOnly: Bool
    /// Last local modification — drives last-writer-wins in iCloud sync.
    /// Stamped by `PostgresProfileStore.saveOrUpdate`; profiles saved before
    /// this field existed decode it as `createdAt`.
    var updatedAt: Date
    /// Opt-in per connection: store the keychain password as a
    /// *synchronizable* item (iCloud Keychain) so it follows the user's
    /// devices. Default `false` = device-local only. The synced profile
    /// record NEVER carries the password either way — iCloud Keychain is
    /// the only transport. Decodes to `false` for older profiles.
    var syncPassword: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String = "127.0.0.1",
        port: UInt16 = 5432,
        database: String,
        user: String,
        auth: PostgresAuthMethod = .keychain,
        // Default to `.require`, not `.prefer`: `.prefer` silently falls back to
        // plaintext if the server doesn't offer TLS, which a network attacker
        // can force by stripping the TLS negotiation. SSH-tunneled connections
        // are already encrypted by the tunnel; users who genuinely need
        // plaintext can still opt down in the connection editor.
        tls: PostgresTlsMode = .require,
        applicationName: String? = "mc-ssh",
        tunnel: PostgresTunnel? = nil,
        connectTimeoutSecs: UInt64? = 10,
        maxPoolSize: UInt32? = nil,
        idleTimeoutSecs: UInt64? = nil,
        minIdleConnections: UInt32? = nil,
        folderPath: String? = nil,
        createdAt: Date = Date(),
        lastConnected: Date? = nil,
        color: String? = nil,
        notes: String? = nil,
        environment: PostgresEnvironment = .unspecified,
        isReadOnly: Bool = false,
        updatedAt: Date = Date(),
        syncPassword: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.auth = auth
        self.tls = tls
        self.applicationName = applicationName
        self.tunnel = tunnel
        self.connectTimeoutSecs = connectTimeoutSecs
        self.maxPoolSize = maxPoolSize
        self.idleTimeoutSecs = idleTimeoutSecs
        self.minIdleConnections = minIdleConnections
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.lastConnected = lastConnected
        self.color = color
        self.notes = notes
        self.environment = environment
        self.isReadOnly = isReadOnly
        self.updatedAt = updatedAt
        self.syncPassword = syncPassword
    }

    // Custom decoding only so `environment` / `isReadOnly` — added after
    // profiles already shipped — default instead of failing on older saved
    // stores. Encoding stays synthesized. Keep the key list in sync when
    // adding fields (or make new fields Optional, which decodes leniently
    // for free).
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, user, auth, tls
        case applicationName, tunnel, connectTimeoutSecs
        case maxPoolSize, idleTimeoutSecs, minIdleConnections
        case folderPath, createdAt, lastConnected, color, notes
        case environment, isReadOnly, updatedAt, syncPassword
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        database = try c.decode(String.self, forKey: .database)
        user = try c.decode(String.self, forKey: .user)
        auth = try c.decode(PostgresAuthMethod.self, forKey: .auth)
        tls = try c.decode(PostgresTlsMode.self, forKey: .tls)
        applicationName = try c.decodeIfPresent(String.self, forKey: .applicationName)
        tunnel = try c.decodeIfPresent(PostgresTunnel.self, forKey: .tunnel)
        connectTimeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .connectTimeoutSecs)
        maxPoolSize = try c.decodeIfPresent(UInt32.self, forKey: .maxPoolSize)
        idleTimeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .idleTimeoutSecs)
        minIdleConnections = try c.decodeIfPresent(UInt32.self, forKey: .minIdleConnections)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        environment = try c.decodeIfPresent(PostgresEnvironment.self, forKey: .environment)
            ?? .unspecified
        isReadOnly = try c.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        // Pre-sync profiles never carried a modification stamp; treating
        // them as "unchanged since creation" makes any synced copy win the
        // first LWW comparison, which is the conservative default.
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        syncPassword = try c.decodeIfPresent(Bool.self, forKey: .syncPassword) ?? false
    }

    /// Stable account string for the keychain. Includes the database so the
    /// same `(user, host, port)` triple can hold distinct credentials per
    /// database — common when one Postgres server hosts multiple apps.
    var keychainAccount: String { "\(user)@\(host):\(port)/\(database)" }

    /// The environment to badge with. Prefers the explicit `environment`
    /// tag; falls back to the legacy `color` highlight strings
    /// ("production"/"development"/"testing") that predate the enum so
    /// existing users keep their badges without re-editing profiles.
    var effectiveEnvironment: PostgresEnvironment {
        if environment != .unspecified { return environment }
        switch color {
        case "production":  return .production
        case "development": return .development
        case "testing":     return .staging
        default:            return .unspecified
        }
    }
}

// =============================================================================
// Persistence
// =============================================================================

/// Owns the Postgres profile collection. Persisted to
/// `Application Support/com.mc-ssh/postgres-profiles.json`. Mirrors the
/// shape of `ConnectionStoreManager` so the sidebar can use familiar CRUD.
@MainActor
final class PostgresProfileStore: ObservableObject {
    static let shared = PostgresProfileStore()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-store")

    @Published var profiles: [PostgresProfile] = []

    private static var storeFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appendingPathComponent("com.mc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("postgres-profiles.json")
    }

    private init() {
        load()
    }

    func saveOrUpdate(_ profile: PostgresProfile) {
        // Stamp the modification time here (single choke point for local
        // mutations) so last-writer-wins sync has a truthful clock.
        // Remote merges bypass this via `applyRemoteMerge` and keep the
        // originating device's stamp.
        var stamped = profile
        stamped.updatedAt = Date()
        var reconnectRequired = false
        if let idx = profiles.firstIndex(where: { $0.id == stamped.id }) {
            let previous = profiles[idx]
            reconnectRequired = Self.connectionSettingsChanged(from: previous, to: stamped)
            // If the keychain account changed, drop the old entry so we
            // don't accumulate orphaned secrets.
            if previous.keychainAccount != stamped.keychainAccount {
                KeychainManager.shared.deletePassword(
                    kind: .postgresPassword,
                    account: previous.keychainAccount
                )
            }
            profiles[idx] = stamped
        } else {
            profiles.append(stamped)
        }
        persist()
        CloudSyncEngine.shared.noteProfilesChanged()

        if reconnectRequired {
            Task { @MainActor in
                await PostgresConnectionManager.shared.reconnectIfNeeded(profile: stamped)
            }
        }
    }

    func delete(_ profile: PostgresProfile) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await PostgresConnectionManager.shared.forget(profileId: profile.id)
            removeLocally(profile)
            persist()
            CloudSyncEngine.shared.noteProfileDeleted(id: profile.id)
        }
    }

    /// Shared teardown for local + remote-initiated deletions: drop the
    /// profile, its keychain entry, and its per-profile artifacts.
    private func removeLocally(_ profile: PostgresProfile) {
        profiles.removeAll { $0.id == profile.id }
        KeychainManager.shared.deletePassword(
            kind: .postgresPassword,
            account: profile.keychainAccount
        )
        // Wipe per-profile artifacts — history and saved queries —
        // for the same privacy reason. Recreating a profile with
        // the same id (defensive — ids are UUIDs in practice)
        // shouldn't inherit the previous user's SQL.
        PostgresHistoryStore.shared.purge(profileId: profile.id)
        PostgresSavedQueriesStore.shared.purge(profileId: profile.id)
    }

    /// Apply a merged batch of remote changes (CloudSyncEngine). Preserves
    /// the remote `updatedAt` stamps and does NOT notify the sync engine —
    /// that would echo remote changes straight back up.
    func applyRemoteMerge(upserts: [PostgresProfile], deleteIds: [String]) {
        guard !(upserts.isEmpty && deleteIds.isEmpty) else { return }
        var changed = false
        for profile in upserts {
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                if profiles[idx] != profile {
                    let reconnectRequired = Self.connectionSettingsChanged(
                        from: profiles[idx], to: profile
                    )
                    profiles[idx] = profile
                    if reconnectRequired {
                        Task { @MainActor in
                            await PostgresConnectionManager.shared.reconnectIfNeeded(profile: profile)
                        }
                    }
                    changed = true
                }
            } else {
                profiles.append(profile)
                changed = true
            }
        }
        for id in deleteIds {
            guard let existing = profiles.first(where: { $0.id == id }) else { continue }
            Task { @MainActor in
                await PostgresConnectionManager.shared.forget(profileId: id)
            }
            removeLocally(existing)
            changed = true
        }
        if changed { persist() }
    }

    func profile(withId id: String) -> PostgresProfile? {
        profiles.first { $0.id == id }
    }

    private static func connectionSettingsChanged(
        from old: PostgresProfile,
        to new: PostgresProfile
    ) -> Bool {
        old.host != new.host
            || old.port != new.port
            || old.database != new.database
            || old.user != new.user
            || old.auth != new.auth
            || old.tls != new.tls
            || old.applicationName != new.applicationName
            || old.tunnel != new.tunnel
            || old.connectTimeoutSecs != new.connectTimeoutSecs
            || old.maxPoolSize != new.maxPoolSize
            || old.idleTimeoutSecs != new.idleTimeoutSecs
            || old.minIdleConnections != new.minIdleConnections
            || old.isReadOnly != new.isReadOnly
    }

    func markConnected(_ profile: PostgresProfile) {
        var updated = profile
        updated.lastConnected = Date()
        saveOrUpdate(updated)
    }

    // MARK: - Disk

    private func load() {
        let url = Self.storeFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode([PostgresProfile].self, from: data)
        } catch {
            logger.error("Failed to load postgres profiles: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            try data.write(to: Self.storeFileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist postgres profiles: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// =============================================================================
// Profile → FFI mapping
// =============================================================================

extension PostgresProfile {
    /// Build the FFI config used to open the connection. Caller is
    /// responsible for ensuring the keychain entry exists if the auth
    /// method is `.keychain`.
    func toFfiConfig() -> FfiPgConfig {
        let ffiAuth: FfiPgAuthMethod
        switch auth {
        case .keychain:
            ffiAuth = .keychain(account: keychainAccount)
        case .ephemeralPassword(let password):
            ffiAuth = .password(password: password)
        }

        let ffiTls: FfiPgTlsMode = {
            switch tls {
            case .disable:    return .disable
            case .prefer:     return .prefer
            case .require:    return .require
            case .verifyFull: return .verifyFull
            }
        }()

        let ffiTunnel = tunnel.map { t in
            FfiPgTunnel(
                sshConnectionId: t.sshConnectionId,
                remoteHost: t.remoteHost,
                remotePort: t.remotePort
            )
        }

        return FfiPgConfig(
            host: host,
            port: port,
            database: database,
            user: user,
            auth: ffiAuth,
            tls: ffiTls,
            applicationName: applicationName,
            tunnel: ffiTunnel,
            connectTimeoutSecs: connectTimeoutSecs ?? 10,
            maxPoolSize: maxPoolSize,
            idleTimeoutSecs: idleTimeoutSecs,
            // Coalesce nil (the common case — the forms leave this unset) to 0
            // so an idle-but-open profile releases its last connection instead
            // of pinning one for the app's lifetime (the core default is 1).
            // Applies to profiles saved before this field existed too, while
            // still honouring an explicit value set in the editor. We do NOT
            // lower maxPoolSize: each query tab holds a session lease for its
            // lifetime, so a low ceiling would exhaust multi-tab workflows —
            // the cross-profile fix is reference-counted release, not a smaller
            // per-profile pool.
            minIdleConnections: minIdleConnections ?? Self.defaultMinIdleConnections,
            profileId: id
        )
    }

    /// Let an idle, open profile release its last connection (the core default
    /// pins 1 for the app's lifetime). Combined with the idle timeout, an
    /// unused profile fully disconnects and reconnects transparently on demand.
    static let defaultMinIdleConnections: UInt32 = 0
}
