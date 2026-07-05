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

/// Optional SSH tunnel descriptor stored on the profile.
/// `sshConnectionId` references a live SSH connection in `ConnectionManager`
/// at connect time — so the tunnel survives an SSH reconnect without
/// editing the Postgres profile.
struct PostgresTunnel: Codable, Hashable, Sendable {
    var sshConnectionId: String
    var remoteHost: String
    var remotePort: UInt16
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
        isReadOnly: Bool = false
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
        case environment, isReadOnly
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
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            let previous = profiles[idx]
            // If the keychain account changed, drop the old entry so we
            // don't accumulate orphaned secrets.
            if previous.keychainAccount != profile.keychainAccount {
                KeychainManager.shared.deletePassword(
                    kind: .postgresPassword,
                    account: previous.keychainAccount
                )
            }
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    func delete(_ profile: PostgresProfile) {
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
        persist()
    }

    func profile(withId id: String) -> PostgresProfile? {
        profiles.first { $0.id == id }
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
            minIdleConnections: minIdleConnections,
            profileId: id
        )
    }
}
