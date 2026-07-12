import Foundation

struct FleetProbeMetrics: Codable, Equatable, Sendable {
    var serverVersionNum: Int?
    var serverMajorVersion: Int?
    var isInRecovery: Bool?
    var uptimeSeconds: Double?
    var totalConnections: Int?
    var maxConnections: Int?
    var connectionUtilizationPercent: Double?
    var oldestTransactionSeconds: Double?
    var idleInTransactionCount: Int?
    var xidAge: Int64?
    var replicationLagSeconds: Double?
    var retainedWalBytes: Int64?
    var databaseSizeBytes: Int64?
    var deadlocks: Int64?
    var tempBytes: Int64?
    var archiveFailureCount: Int64?
    var sslInUse: Bool?
    var runningMaintenanceCount: Int?
    var schemaFingerprint: String?

    static let empty = FleetProbeMetrics(
        serverVersionNum: nil,
        serverMajorVersion: nil,
        isInRecovery: nil,
        uptimeSeconds: nil,
        totalConnections: nil,
        maxConnections: nil,
        connectionUtilizationPercent: nil,
        oldestTransactionSeconds: nil,
        idleInTransactionCount: nil,
        xidAge: nil,
        replicationLagSeconds: nil,
        retainedWalBytes: nil,
        databaseSizeBytes: nil,
        deadlocks: nil,
        tempBytes: nil,
        archiveFailureCount: nil,
        sslInUse: nil,
        runningMaintenanceCount: nil,
        schemaFingerprint: nil
    )
}

enum FleetProbeParseError: LocalizedError, Equatable {
    case unexpectedColumnCount(Int)
    case unsupportedServer(Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedColumnCount(let count):
            return "Fleet probe returned \(count) columns; expected 17."
        case .unsupportedServer(let version):
            return "PostgreSQL \(version) is unsupported. pgAgent requires PostgreSQL 14 or newer."
        }
    }
}

enum PostgresServerVersionPolicy {
    static let minimumMajorVersion = 14

    @discardableResult
    static func validate(versionNum: Int) throws -> Int {
        let major = versionNum / 10_000
        guard major >= minimumMajorVersion else {
            throw FleetProbeParseError.unsupportedServer(major)
        }
        return major
    }
}

enum FleetProbeParser {
    static func parse(_ cells: [String?]) throws -> FleetProbeMetrics {
        guard cells.count >= 17 else {
            throw FleetProbeParseError.unexpectedColumnCount(cells.count)
        }
        let versionNum = cells[0].flatMap(Int.init)
        let major = try versionNum.map { try PostgresServerVersionPolicy.validate(versionNum: $0) }
        let total = cells[3].flatMap(Int.init)
        let max = cells[4].flatMap(Int.init)
        let utilization: Double? = {
            guard let total, let max, max > 0 else { return nil }
            return (Double(total) / Double(max)) * 100
        }()
        return FleetProbeMetrics(
            serverVersionNum: versionNum,
            serverMajorVersion: major,
            isInRecovery: parseBool(cells[1]),
            uptimeSeconds: cells[2].flatMap(Double.init),
            totalConnections: total,
            maxConnections: max,
            connectionUtilizationPercent: utilization,
            oldestTransactionSeconds: cells[5].flatMap(Double.init),
            idleInTransactionCount: cells[6].flatMap(Int.init),
            xidAge: cells[7].flatMap(Int64.init),
            replicationLagSeconds: cells[8].flatMap(Double.init),
            retainedWalBytes: cells[9].flatMap(Int64.init),
            databaseSizeBytes: cells[10].flatMap(Int64.init),
            deadlocks: cells[11].flatMap(Int64.init),
            tempBytes: cells[12].flatMap(Int64.init),
            archiveFailureCount: cells[13].flatMap(Int64.init),
            sslInUse: parseBool(cells[14]),
            runningMaintenanceCount: cells[15].flatMap(Int.init),
            schemaFingerprint: cells[16]
        )
    }

    private static func parseBool(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "t", "true", "1", "on": return true
        case "f", "false", "0", "off": return false
        default: return nil
        }
    }
}

enum FleetProbeSQL {
    /// One low-cost PostgreSQL 14+ row. Every metric is explicitly scoped and
    /// nullable so restricted managed-provider roles degrade without turning a
    /// healthy connection into a false outage.
    static let posture = """
        SELECT
          current_setting('server_version_num')::int,
          pg_is_in_recovery(),
          EXTRACT(EPOCH FROM clock_timestamp() - pg_postmaster_start_time()),
          (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'),
          current_setting('max_connections')::int,
          (SELECT EXTRACT(EPOCH FROM clock_timestamp() - min(xact_start))
             FROM pg_stat_activity WHERE xact_start IS NOT NULL),
          (SELECT count(*) FROM pg_stat_activity WHERE state LIKE 'idle in transaction%'),
          (SELECT max(age(datfrozenxid)) FROM pg_database),
          CASE WHEN pg_is_in_recovery()
               THEN EXTRACT(EPOCH FROM clock_timestamp() - pg_last_xact_replay_timestamp())
               ELSE (SELECT EXTRACT(EPOCH FROM max(replay_lag)) FROM pg_stat_replication)
          END,
          CASE WHEN pg_is_in_recovery() THEN NULL
               ELSE (SELECT max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))::bigint
                       FROM pg_replication_slots WHERE restart_lsn IS NOT NULL)
          END,
          pg_database_size(current_database()),
          (SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()),
          (SELECT temp_bytes FROM pg_stat_database WHERE datname = current_database()),
          (SELECT CASE
                    WHEN failed_count > 0
                     AND (last_archived_time IS NULL OR last_failed_time > last_archived_time)
                    THEN failed_count ELSE 0 END
             FROM pg_stat_archiver),
          (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()),
          ((SELECT count(*) FROM pg_stat_progress_vacuum)
           + (SELECT count(*) FROM pg_stat_progress_analyze)
           + (SELECT count(*) FROM pg_stat_progress_create_index)
           + (SELECT count(*) FROM pg_stat_progress_cluster)
           + (SELECT count(*) FROM pg_stat_progress_basebackup)
           + (SELECT count(*) FROM pg_stat_progress_copy)),
          (SELECT md5(COALESCE(string_agg(
              format('%I.%I.%I:%s:%s', n.nspname, c.relname, a.attname,
                     format_type(a.atttypid, a.atttypmod), a.attnotnull),
              ',' ORDER BY n.nspname, c.relname, a.attnum), ''))
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid
            WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname !~ '^pg_toast'
              AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND a.attnum > 0 AND NOT a.attisdropped)
        """
}

enum FleetPollingPolicy {
    static let defaultMaxConcurrent = 4

    static func batches<Element>(
        _ elements: [Element],
        maxConcurrent: Int = defaultMaxConcurrent
    ) -> [[Element]] {
        guard !elements.isEmpty else { return [] }
        let size = max(1, maxConcurrent)
        return stride(from: 0, to: elements.count, by: size).map { start in
            Array(elements[start..<min(start + size, elements.count)])
        }
    }
}

struct FleetEnvironmentThresholds: Codable, Equatable, Sendable {
    var longRunningSeconds: Int
    var connectionWarningPercent: Double
    var replicationLagWarningSeconds: Double
    var alertOnUnreachable: Bool
}

enum FleetEnvironmentPolicy {
    static func defaults(for environment: String) -> FleetEnvironmentThresholds {
        switch environment.lowercased() {
        case "production":
            return FleetEnvironmentThresholds(
                longRunningSeconds: 30,
                connectionWarningPercent: 80,
                replicationLagWarningSeconds: 60,
                alertOnUnreachable: true)
        case "staging":
            return FleetEnvironmentThresholds(
                longRunningSeconds: 60,
                connectionWarningPercent: 90,
                replicationLagWarningSeconds: 180,
                alertOnUnreachable: true)
        default:
            return FleetEnvironmentThresholds(
                longRunningSeconds: 120,
                connectionWarningPercent: 95,
                replicationLagWarningSeconds: 300,
                alertOnUnreachable: false)
        }
    }

    /// Combine operator-controlled alert counts with environment-aware posture
    /// limits. Production remains conservative without taking away the DBA's
    /// ability to disable count-based query and lock alerts.
    static func alertThresholds(
        for environment: String,
        user: FleetMonitorThresholds
    ) -> FleetMonitorThresholds {
        let policy = defaults(for: environment)
        return FleetMonitorThresholds(
            longRunningSeconds: policy.longRunningSeconds,
            longRunningCountAlert: user.longRunningCountAlert,
            blockedLockAlert: user.blockedLockAlert,
            alertOnUnreachable: user.alertOnUnreachable || policy.alertOnUnreachable,
            connectionWarningPercent: policy.connectionWarningPercent,
            replicationLagWarningSeconds: policy.replicationLagWarningSeconds)
    }
}

enum FleetPostureSeverity: String, Codable, Comparable, Sendable {
    case healthy, warning, critical

    static func < (lhs: FleetPostureSeverity, rhs: FleetPostureSeverity) -> Bool {
        let rank: [FleetPostureSeverity: Int] = [.healthy: 0, .warning: 1, .critical: 2]
        return rank[lhs, default: 0] < rank[rhs, default: 0]
    }
}

enum FleetPosturePolicy {
    static func severity(metrics: FleetProbeMetrics) -> FleetPostureSeverity {
        if let major = metrics.serverMajorVersion, major < 14 { return .critical }
        if (metrics.xidAge ?? 0) >= 1_800_000_000 { return .critical }
        if (metrics.connectionUtilizationPercent ?? 0) >= 95 { return .critical }
        if (metrics.replicationLagSeconds ?? 0) >= 300 { return .critical }
        if (metrics.xidAge ?? 0) >= 1_500_000_000 { return .warning }
        if (metrics.connectionUtilizationPercent ?? 0) >= 80 { return .warning }
        if (metrics.replicationLagSeconds ?? 0) >= 60 { return .warning }
        if (metrics.oldestTransactionSeconds ?? 0) >= 3_600 { return .warning }
        if (metrics.archiveFailureCount ?? 0) > 0 { return .warning }
        return .healthy
    }
}

enum FleetAlertDisposition: Codable, Equatable, Sendable {
    case active
    case acknowledged(at: Date)
    case snoozed(until: Date)
    case maintenance(until: Date)
    case resolved(at: Date)
}

enum FleetAlertLifecyclePolicy {
    static func shouldDeliver(
        disposition: FleetAlertDisposition,
        now: Date = Date()
    ) -> Bool {
        switch disposition {
        case .active: return true
        case .acknowledged, .resolved: return false
        case .snoozed(let until), .maintenance(let until): return until <= now
        }
    }
}

struct FleetSnapshotRecord: Codable, Equatable, Sendable {
    let profileId: String
    let capturedAt: Date
    let reachable: Bool
    let activeBackends: Int
    let longRunningCount: Int
    let blockedLockCount: Int
    let latencyMilliseconds: Double?
    let metrics: FleetProbeMetrics
    let errorMessage: String?
}

actor FleetSnapshotStore {
    private let fileURL: URL

    init(fileURL: URL = FleetSnapshotStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("com.mc-ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("fleet-snapshots.jsonl")
    }

    func append(_ snapshot: FleetSnapshotRecord) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(snapshot)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func recent(profileId: String? = nil, limit: Int = 500) throws -> [FleetSnapshotRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = data.split(separator: 0x0A).compactMap { line -> FleetSnapshotRecord? in
            try? decoder.decode(FleetSnapshotRecord.self, from: Data(line))
        }
        return decoded.reversed().filter { profileId == nil || $0.profileId == profileId }.prefix(limit).map { $0 }
    }
}
