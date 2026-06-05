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

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String = "127.0.0.1",
        port: UInt16 = 5432,
        database: String,
        user: String,
        auth: PostgresAuthMethod = .keychain,
        tls: PostgresTlsMode = .prefer,
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
        notes: String? = nil
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
    }

    /// Stable account string for the keychain. Includes the database so the
    /// same `(user, host, port)` triple can hold distinct credentials per
    /// database — common when one Postgres server hosts multiple apps.
    var keychainAccount: String { "\(user)@\(host):\(port)/\(database)" }
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
