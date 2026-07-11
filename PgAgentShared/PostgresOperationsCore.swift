import Foundation

enum PostgresProgressOperation: String, Codable, Equatable, Sendable {
    case vacuum = "VACUUM"
    case analyze = "ANALYZE"
    case createIndex = "CREATE INDEX"
    case cluster = "CLUSTER"
}

struct PostgresProgressOperationRecord: Identifiable, Equatable, Sendable {
    let pid: Int32
    let database: String
    let target: String
    let operation: PostgresProgressOperation
    let phase: String
    let completedUnits: Double?
    let totalUnits: Double?

    var id: String { "\(pid):\(operation.rawValue):\(target)" }
    var percentComplete: Double? {
        guard let completedUnits, let totalUnits, totalUnits > 0 else { return nil }
        return min(100, max(0, completedUnits / totalUnits * 100))
    }
}

enum PostgresProgressParseError: LocalizedError {
    case malformedRow
    case unknownOperation(String)

    var errorDescription: String? {
        switch self {
        case .malformedRow: return "PostgreSQL progress row was malformed."
        case .unknownOperation(let value): return "Unknown PostgreSQL progress operation: \(value)."
        }
    }
}

enum PostgresProgressParser {
    static func parse(_ cells: [String?]) throws -> PostgresProgressOperationRecord {
        guard cells.count >= 7,
              let pidText = cells[0], let pid = Int32(pidText),
              let database = cells[1], let target = cells[2],
              let operationText = cells[3],
              let operation = PostgresProgressOperation(rawValue: operationText),
              let phase = cells[4]
        else {
            if cells.count > 3, let value = cells[3],
               PostgresProgressOperation(rawValue: value) == nil {
                throw PostgresProgressParseError.unknownOperation(value)
            }
            throw PostgresProgressParseError.malformedRow
        }
        return PostgresProgressOperationRecord(
            pid: pid,
            database: database,
            target: target,
            operation: operation,
            phase: phase,
            completedUnits: cells[5].flatMap(Double.init),
            totalUnits: cells[6].flatMap(Double.init)
        )
    }
}

enum PostgresProgressSQL {
    static let activeOperations = """
        SELECT pid, datname, relid::regclass::text, 'VACUUM', phase,
               heap_blks_scanned::numeric, NULLIF(heap_blks_total, 0)::numeric
          FROM pg_stat_progress_vacuum
        UNION ALL
        SELECT pid, datname, relid::regclass::text, 'ANALYZE', phase,
               sample_blks_scanned::numeric, NULLIF(sample_blks_total, 0)::numeric
          FROM pg_stat_progress_analyze
        UNION ALL
        SELECT pid, datname, relid::regclass::text, 'CREATE INDEX', phase,
               blocks_done::numeric, NULLIF(blocks_total, 0)::numeric
          FROM pg_stat_progress_create_index
        UNION ALL
        SELECT pid, datname, relid::regclass::text, 'CLUSTER', phase,
               heap_blks_scanned::numeric, NULLIF(heap_blks_total, 0)::numeric
          FROM pg_stat_progress_cluster
        ORDER BY 1
        """
}

struct FleetDriftSnapshot: Equatable, Sendable {
    let profileId: String
    let group: String
    let environment: String
    let serverMajorVersion: Int?
    let schemaFingerprint: String?
}

enum FleetDriftKind: String, Codable, Hashable, Sendable {
    case serverVersion
    case schema
}

struct FleetDriftFinding: Identifiable, Equatable, Sendable {
    let profileId: String
    let referenceProfileId: String
    let group: String
    let kind: FleetDriftKind
    let detail: String

    var id: String { "\(group):\(profileId):\(kind.rawValue)" }
}

enum FleetDriftPolicy {
    /// Compare only explicitly related profiles. The caller supplies `group`
    /// (folder + database is the product default), preventing meaningless
    /// comparisons between unrelated databases in a 20-instance fleet.
    static func findings(in snapshots: [FleetDriftSnapshot]) -> [FleetDriftFinding] {
        Dictionary(grouping: snapshots, by: \.group).keys.sorted().flatMap { group -> [FleetDriftFinding] in
            let members = snapshots.filter { $0.group == group }.sorted { $0.profileId < $1.profileId }
            guard members.count > 1 else { return [] }
            let reference = members.first(where: { $0.environment == "production" }) ?? members[0]
            return members.filter { $0.profileId != reference.profileId }.flatMap { candidate in
                var result: [FleetDriftFinding] = []
                if let expected = reference.serverMajorVersion,
                   let actual = candidate.serverMajorVersion, expected != actual {
                    result.append(FleetDriftFinding(
                        profileId: candidate.profileId,
                        referenceProfileId: reference.profileId,
                        group: group,
                        kind: .serverVersion,
                        detail: "PostgreSQL \(actual) differs from reference PostgreSQL \(expected)."))
                }
                if let expected = reference.schemaFingerprint,
                   let actual = candidate.schemaFingerprint, expected != actual {
                    result.append(FleetDriftFinding(
                        profileId: candidate.profileId,
                        referenceProfileId: reference.profileId,
                        group: group,
                        kind: .schema,
                        detail: "Catalog fingerprint differs from the group reference."))
                }
                return result
            }
        }
    }
}

struct PostgresDBARunbookStep: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sql: String
    let isReadOnly: Bool
    let interpretation: String
}

struct PostgresDBARunbook: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let summary: String
    let steps: [PostgresDBARunbookStep]

    static let catalog: [PostgresDBARunbook] = [
        PostgresDBARunbook(
            id: "connection-storm",
            title: "Connection storm",
            summary: "Identify capacity pressure, noisy clients, and idle transactions before cancelling anything.",
            steps: [
                .init(id: "capacity", title: "Connection capacity", sql: "SELECT count(*) AS used, current_setting('max_connections')::int AS max_connections FROM pg_stat_activity;", isReadOnly: true, interpretation: "Sustained usage above the environment threshold needs pooling or client remediation."),
                .init(id: "clients", title: "Clients by application", sql: "SELECT application_name, usename, state, count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY 1,2,3 ORDER BY 4 DESC;", isReadOnly: true, interpretation: "Find the application and role creating the surge."),
                .init(id: "idle-xacts", title: "Old idle transactions", sql: "SELECT pid, usename, application_name, now() - xact_start AS age, left(query, 200) FROM pg_stat_activity WHERE state LIKE 'idle in transaction%' ORDER BY xact_start;", isReadOnly: true, interpretation: "Resolve the application defect before terminating a backend."),
            ]),
        PostgresDBARunbook(
            id: "replication-lag",
            title: "Replication lag",
            summary: "Distinguish sender lag, replay lag, and retained-WAL pressure.",
            steps: [
                .init(id: "senders", title: "Physical replicas", sql: "SELECT application_name, client_addr, state, sync_state, write_lag, flush_lag, replay_lag FROM pg_stat_replication ORDER BY application_name;", isReadOnly: true, interpretation: "Compare write, flush, and replay lag before acting."),
                .init(id: "slots", title: "Replication slots", sql: "SELECT slot_name, slot_type, active, restart_lsn, wal_status, safe_wal_size FROM pg_replication_slots ORDER BY slot_name;", isReadOnly: true, interpretation: "Inactive slots can retain unbounded WAL; verify ownership before removal."),
            ]),
        PostgresDBARunbook(
            id: "wraparound-risk",
            title: "Transaction ID wraparound",
            summary: "Find the databases, tables, transactions, and slots preventing freezing.",
            steps: [
                .init(id: "databases", title: "Database XID age", sql: "SELECT datname, age(datfrozenxid) AS xid_age FROM pg_database ORDER BY xid_age DESC;", isReadOnly: true, interpretation: "Treat ages approaching 1.5 billion as urgent."),
                .init(id: "tables", title: "Oldest table XIDs", sql: "SELECT n.nspname, c.relname, age(c.relfrozenxid) AS xid_age FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','m') ORDER BY xid_age DESC LIMIT 50;", isReadOnly: true, interpretation: "Check autovacuum settings and blockers on the oldest relations."),
                .init(id: "blockers", title: "Old transactions", sql: "SELECT pid, usename, now() - xact_start AS age, backend_xid, backend_xmin, left(query, 200) FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY xact_start;", isReadOnly: true, interpretation: "Long transactions can prevent vacuum progress."),
            ]),
    ]
}
