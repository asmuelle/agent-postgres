import Foundation
import OSLog

// =============================================================================
// PostgresAuditLog — local, exportable audit trail of every write executed
// through pgAgent.
//
// Persisted as JSONL (one JSON object per line) to
// `Application Support/com.mc-ssh/postgres-audit.jsonl` — same storage
// idiom as `PostgresHistoryStore`, but append-only and cross-profile:
// an audit trail wants one immutable stream, not per-profile files that
// vanish when a profile is deleted.
//
// Low-noise by design: only write-classified statements, grid DML, and
// transaction control are recorded — never SELECTs. Recording is
// fire-and-forget from the bridge (an audit failure is logged, never
// thrown, and never blocks or fails the query path).
// =============================================================================

/// One audit record. Field names are the JSONL schema — treat as
/// append-only (add optional fields, never rename) so old log lines
/// stay parseable.
struct PostgresAuditRecord: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case execute
        case updateCell = "update_cell"
        case insertRow = "insert_row"
        case deleteRows = "delete_rows"
        case transaction
        // Guarded on-call fixes (roadmap 1.2 alert → action loop).
        case cancelBackend = "cancel_backend"
        case terminateBackend = "terminate_backend"
    }

    let ts: Date
    let profileName: String
    let host: String
    let database: String
    let user: String
    let action: Action
    /// The SQL text (or a synthesized description for grid DML), capped
    /// at `PostgresAuditLog.statementCap` characters.
    let statement: String
    /// "ok" or "error:<message>" (message capped).
    let outcome: String
    let rowsAffected: UInt64?

    private enum CodingKeys: String, CodingKey {
        case ts, profileName, host, database, user, action, statement, outcome, rowsAffected
    }
}

actor PostgresAuditLog {
    static let shared = PostgresAuditLog()

    static let statementCap = 2_000
    private static let errorMessageCap = 500

    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-audit")

    /// Where the JSONL stream lives. Nonisolated so the export UI can
    /// reference the path without hopping onto the actor.
    nonisolated static var fileURL: URL {
        // Application Support always resolves in practice; fall back to the
        // temp directory (same idiom as PostgresHistoryStore) rather than
        // crashing on an exotic sandbox state.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("com.mc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("postgres-audit.jsonl")
    }

    private init() {}

    // MARK: - Recording

    /// Append one record. Never throws — audit failures must not surface
    /// into the query path; they are logged and dropped.
    func record(
        profileName: String,
        host: String,
        database: String,
        user: String,
        action: PostgresAuditRecord.Action,
        statement: String,
        error: String?,
        rowsAffected: UInt64?
    ) {
        let outcome: String
        if let error {
            outcome = "error:\(String(error.prefix(Self.errorMessageCap)))"
        } else {
            outcome = "ok"
        }
        let entry = PostgresAuditRecord(
            ts: Date(),
            profileName: profileName,
            host: host,
            database: database,
            user: user,
            action: action,
            statement: String(statement.prefix(Self.statementCap)),
            outcome: outcome,
            rowsAffected: rowsAffected
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // No .prettyPrinted — each record must stay on one line (JSONL).
            var line = try encoder.encode(entry)
            line.append(0x0A) // "\n"
            try append(line, to: Self.fileURL)
        } catch {
            logger.error("audit append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: - Reading (viewer / export)

    /// The most recent `limit` records, newest first. Reads at most the
    /// last `maxBytes` of the file so an old, large log can't stall the
    /// settings pane; a record truncated by the byte window is skipped.
    func recentRecords(limit: Int = 200, maxBytes: Int = 512 * 1024) -> [PostgresAuditRecord] {
        let url = Self.fileURL
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var records: [PostgresAuditRecord] = []
            for line in text.split(separator: "\n").suffix(limit * 2) {
                guard let lineData = line.data(using: .utf8),
                      let record = try? decoder.decode(PostgresAuditRecord.self, from: lineData)
                else { continue } // partial first line from the byte window, or corruption
                records.append(record)
            }
            return Array(records.suffix(limit).reversed())
        } catch {
            logger.error("audit read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
