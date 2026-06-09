import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// Postgres bridge surface — Swift wrappers over the uniffi-generated
// `rshell_pg_*` functions. Postgres calls run on the utility queue (not the
// terminal-input control queue) so a slow `LIST RELATIONS` against a large
// schema can't block keystroke writes to a PTY.
// =============================================================================

/// PostgreSQL's structured server-error fields, surfaced from
/// `FfiPgError.Database` so the UI can show the SQLSTATE, the failing
/// constraint, an editor position, and the server's detail/hint.
struct PostgresServerError: Sendable, Equatable {
    let sqlstate: String
    let message: String
    let detail: String?
    let hint: String?
    /// 1-based character offset into the submitted SQL, when the server
    /// reported one.
    let position: UInt32?
    let constraint: String?
    let column: String?
    let table: String?
    let schema: String?

    /// `true` when the session's transaction is aborted (SQLSTATE class 25,
    /// e.g. `25P02`) and a ROLLBACK is required before further statements run.
    var isInFailedTransaction: Bool { sqlstate.hasPrefix("25") }
}

/// Swift-side mirror of `FfiPgError` plus a few transport-level wrappers,
/// so the rest of the UI can pattern-match without depending on the
/// uniffi module.
enum PostgresBridgeError: Error, LocalizedError {
    case connect(String)
    case auth(String)
    case tls(String)
    case tunnel(String)
    /// Tunnel was requested but the SSH connection it depends on isn't
    /// open. UI can offer "Open SSH first, then retry".
    case tunnelSourceMissing(String)
    /// The cursor handle no longer matches an active result on this
    /// session — the same session opened a different cursor in
    /// between, or the session was released.
    case cursorExpired(String)
    /// All pooled connections are leased to other sessions. UI shows
    /// "too many open queries — close a tab to continue".
    case poolExhausted(String)
    case notConnected(String)
    /// A server-side error carrying PostgreSQL's structured fields.
    case database(PostgresServerError)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .connect(let m):              return "Connection failed: \(m)"
        case .auth(let m):                 return "Authentication failed: \(m)"
        case .tls(let m):                  return "TLS error: \(m)"
        case .tunnel(let m):               return "SSH tunnel error: \(m)"
        case .tunnelSourceMissing(let m):  return "SSH connection is not open: \(m)"
        case .cursorExpired(let m):        return "Result no longer available: \(m)"
        case .poolExhausted(let m):        return "Too many open queries (\(m)). Close a tab to free up a connection."
        case .notConnected(let m):         return "Not connected: \(m)"
        case .database(let e):
            var lines = ["ERROR \(e.sqlstate): \(e.message)"]
            if let c = e.constraint { lines.append("Constraint: \(c)") }
            if let d = e.detail { lines.append("Detail: \(d)") }
            if let h = e.hint { lines.append("Hint: \(h)") }
            return lines.joined(separator: "\n")
        case .other(let m):                return m
        }
    }

    /// The structured server error, when this is a `.database` failure.
    var serverError: PostgresServerError? {
        if case .database(let e) = self { return e }
        return nil
    }

    var isCursorExpired: Bool {
        if case .cursorExpired = self { return true }
        return false
    }

    static func from(_ err: FfiPgError) -> PostgresBridgeError {
        // uniffi 0.28 generates PascalCase Swift cases from Rust variant names
        // — keep these aligned if a variant is added on the Rust side.
        switch err {
        case .Connect(let detail):              return .connect(detail)
        case .Auth(let detail):                 return .auth(detail)
        case .Tls(let detail):                  return .tls(detail)
        case .Tunnel(let detail):               return .tunnel(detail)
        case .TunnelSourceMissing(let detail):  return .tunnelSourceMissing(detail)
        case .CursorExpired(let detail):        return .cursorExpired(detail)
        case .PoolExhausted(let detail):        return .poolExhausted(detail)
        case .NotConnected(let detail):         return .notConnected(detail)
        case let .Database(sqlstate, message, detail, hint, position, constraint, column, table, schema):
            return .database(PostgresServerError(
                sqlstate: sqlstate, message: message, detail: detail, hint: hint,
                position: position, constraint: constraint, column: column,
                table: table, schema: schema
            ))
        case .Other(let detail):                return .other(detail)
        }
    }
}

extension BridgeManager {
    /// Connect to a Postgres server. Resolves the keychain password if the
    /// profile uses `.keychain` auth and no entry is found — the caller is
    /// responsible for prompting the user and saving before retrying.
    func pgConnect(profile: PostgresProfile) async throws -> String {
        let config = profile.toFfiConfig()

        do {
            let connectionId: String = try await runOnUtilityQueuePg {
                try rshellPgConnect(config: config)
            }
            return connectionId
        } catch let err as FfiPgError {
            throw PostgresBridgeError.from(err)
        } catch {
            throw PostgresBridgeError.other(error.localizedDescription)
        }
    }

    func pgDisconnect(connectionId: String) async {
        // Disconnect always returns `FfiResult` (never throws). Errors are
        // already logged on the Rust side; we run it for the side effect.
        await runOnUtilityQueuePgVoid {
            _ = rshellPgDisconnect(connectionId: connectionId)
        }
    }

    func pgListDatabases(connectionId: String) async throws -> [FfiPgDatabase] {
        try await pgWrapping {
            try rshellPgListDatabases(connectionId: connectionId)
        }
    }

    /// `database == nil` queries the connection's default DB.
    /// Pass a non-nil database to browse schemas in another DB on
    /// the same server — the core opens (and caches) a side
    /// connection for each non-default database.
    func pgListSchemas(
        connectionId: String,
        database: String? = nil
    ) async throws -> [FfiPgSchema] {
        try await pgWrapping {
            try rshellPgListSchemas(connectionId: connectionId, database: database)
        }
    }

    func pgListRelations(
        connectionId: String,
        schema: String,
        database: String? = nil
    ) async throws -> [FfiPgRelation] {
        try await pgWrapping {
            try rshellPgListRelations(
                connectionId: connectionId,
                schema: schema,
                database: database
            )
        }
    }

    /// Unified DataGrip-style schema-contents fetch. Returns
    /// tables / views / matviews / sequences / routines / object
    /// types in one call.
    func pgListSchemaContents(
        connectionId: String,
        schema: String,
        database: String? = nil
    ) async throws -> FfiPgSchemaContents {
        try await pgWrapping {
            try rshellPgListSchemaContents(
                connectionId: connectionId,
                schema: schema,
                database: database
            )
        }
    }

    /// Describe a relation's columns for the INSERT sheet. Reads
    /// `pg_attribute` + `pg_attrdef` so the form knows which
    /// columns are NOT NULL, which have defaults, and which are
    /// generated (skip on INSERT).
    func pgDescribeColumns(
        connectionId: String,
        schema: String,
        table: String
    ) async throws -> [FfiPgColumnDetail] {
        try await pgWrapping {
            try rshellPgDescribeColumns(
                connectionId: connectionId,
                schema: schema,
                table: table
            )
        }
    }

    /// Run a SQL statement on `sessionId`'s connection. The session
    /// id is opaque — the UI typically uses the query tab's UUID
    /// string. Sessions are isolated: opening a cursor in session A
    /// doesn't affect session B's cursor on the same profile.
    func pgExecute(
        connectionId: String,
        sessionId: String,
        sql: String,
        pageSize: UInt32
    ) async throws -> FfiPgExecutionResult {
        try await pgWrapping {
            try rshellPgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: sql,
                pageSize: pageSize
            )
        }
    }

    /// Fetch the next page from a cursor opened by `pgExecute` in the
    /// same session. Throws `cursorExpired` if the session was
    /// released or opened a different cursor.
    func pgFetchPage(
        connectionId: String,
        sessionId: String,
        cursorId: String,
        count: UInt32
    ) async throws -> FfiPgPageResult {
        try await pgWrapping {
            try rshellPgFetchPage(
                connectionId: connectionId,
                sessionId: sessionId,
                cursorId: cursorId,
                count: count
            )
        }
    }

    /// Close a cursor on `sessionId`. Idempotent — closing a stale
    /// cursor is a silent success. Doesn't throw.
    @discardableResult
    func pgCloseQuery(
        connectionId: String,
        sessionId: String,
        cursorId: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            postgresQueue.async {
                let result = rshellPgCloseQuery(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    cursorId: cursorId
                )
                continuation.resume(returning: result.success)
            }
        }
    }

    /// Release `sessionId`'s lease on its pooled connection. Closes
    /// any active cursor first, then returns the connection to idle
    /// so other sessions can use it. Call on tab close.
    @discardableResult
    func pgReleaseSession(
        connectionId: String,
        sessionId: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            postgresQueue.async {
                let result = rshellPgReleaseSession(
                    connectionId: connectionId,
                    sessionId: sessionId
                )
                continuation.resume(returning: result.success)
            }
        }
    }

    /// Update a single cell on `(schema, table)` identified by ctid.
    /// `newValue == nil` writes NULL. Returns the FFI result so the
    /// caller can branch on `rowsAffected == 0` (concurrent edit /
    /// row deleted).
    func pgUpdateCell(
        connectionId: String,
        sessionId: String,
        schema: String,
        table: String,
        column: String,
        columnType: String,
        newValue: String?,
        rowId: String
    ) async throws -> FfiPgUpdateResult {
        try await pgWrapping {
            try rshellPgUpdateCell(
                connectionId: connectionId,
                sessionId: sessionId,
                schema: schema,
                table: table,
                column: column,
                columnType: columnType,
                newValue: newValue,
                rowId: rowId
            )
        }
    }

    /// Open a Parquet writer at `path` with the given column names.
    /// All columns are stored as Utf8. Returns an opaque writer id.
    func pgParquetOpen(path: String, columns: [String]) async throws -> UInt64 {
        try await pgWrapping {
            try rshellPgParquetOpen(path: path, columns: columns)
        }
    }

    /// Append a batch of rows to the Parquet writer.
    func pgParquetAppend(writerId: UInt64, rows: [FfiPgRow]) async throws {
        try await pgWrapping {
            try rshellPgParquetAppend(writerId: writerId, rows: rows)
        }
    }

    /// Close the Parquet writer; flushes the metadata footer.
    func pgParquetClose(writerId: UInt64) async throws {
        try await pgWrapping {
            try rshellPgParquetClose(writerId: writerId)
        }
    }

    /// Insert one row. The `inputs` list covers only the columns
    /// the caller wants to set explicitly — omit a column to use
    /// its server-side `DEFAULT` (sequences, generated columns,
    /// `pg_attrdef` defaults). `returnColumns` drives the
    /// `RETURNING` clause; pass the same visible-column names the
    /// existing grid uses (including `__pg_rowid__`) so the new
    /// row slots straight in.
    func pgInsertRow(
        connectionId: String,
        sessionId: String,
        schema: String,
        table: String,
        inputs: [FfiPgInsertColumn],
        returnColumns: [String]
    ) async throws -> FfiPgInsertedRow {
        try await pgWrapping {
            try rshellPgInsertRow(
                connectionId: connectionId,
                sessionId: sessionId,
                schema: schema,
                table: table,
                inputs: inputs,
                returnColumns: returnColumns
            )
        }
    }

    /// Delete one or more rows by ctid. Returns the FFI result so
    /// the caller can spot "some rows already gone" by comparing
    /// `rowsAffected` against the count it asked to delete.
    func pgDeleteRows(
        connectionId: String,
        sessionId: String,
        schema: String,
        table: String,
        rowIds: [String]
    ) async throws -> FfiPgUpdateResult {
        try await pgWrapping {
            try rshellPgDeleteRows(
                connectionId: connectionId,
                sessionId: sessionId,
                schema: schema,
                table: table,
                rowIds: rowIds
            )
        }
    }

    /// Cancel whatever query is in flight on `sessionId`'s
    /// connection. Other sessions are unaffected.
    @discardableResult
    func pgCancel(connectionId: String, sessionId: String) async -> Bool {
        await withCheckedContinuation { continuation in
            postgresQueue.async {
                let result = rshellPgCancel(
                    connectionId: connectionId,
                    sessionId: sessionId
                )
                continuation.resume(returning: result.success)
            }
        }
    }

    func pgListSessions(connectionId: String) async throws -> [FfiPgSessionDetail] {
        try await pgWrapping {
            try rshellPgListSessions(connectionId: connectionId)
        }
    }

    func pgCancelBackend(connectionId: String, pid: Int32) async throws -> Bool {
        try await pgWrapping {
            try rshellPgCancelBackend(connectionId: connectionId, pid: pid)
        }
    }

    func pgTerminateBackend(connectionId: String, pid: Int32) async throws -> Bool {
        try await pgWrapping {
            try rshellPgTerminateBackend(connectionId: connectionId, pid: pid)
        }
    }

    func pgListLocks(connectionId: String) async throws -> [FfiPgLockDetail] {
        try await pgWrapping {
            try rshellPgListLocks(connectionId: connectionId)
        }
    }

    /// Begin / commit / roll back a transaction on the tab's session. The
    /// session pins its pooled connection across the transaction, so the same
    /// `sessionId` must run the statements inside it.
    func pgBegin(connectionId: String, sessionId: String) async throws {
        try await pgWrapping {
            try rshellPgBegin(connectionId: connectionId, sessionId: sessionId)
        }
    }

    func pgCommit(connectionId: String, sessionId: String) async throws {
        try await pgWrapping {
            try rshellPgCommit(connectionId: connectionId, sessionId: sessionId)
        }
    }

    func pgRollback(connectionId: String, sessionId: String) async throws {
        try await pgWrapping {
            try rshellPgRollback(connectionId: connectionId, sessionId: sessionId)
        }
    }

    // MARK: - Internal helpers

    /// Run a throwing FFI call on the bridge's utility queue and convert
    /// `FfiPgError` to `PostgresBridgeError` at the boundary. Keeps the
    /// pattern out of every method.
    private func pgWrapping<T>(_ work: @escaping () throws -> T) async throws -> T {
        do {
            return try await runOnUtilityQueuePg(work)
        } catch let err as FfiPgError {
            throw PostgresBridgeError.from(err)
        } catch {
            throw PostgresBridgeError.other(error.localizedDescription)
        }
    }

    /// Bridge between the file-private `runOnUtilityQueue` in `BridgeManager`
    /// and this extension. Re-implemented inline because the original is
    /// `private`; mirroring the queue semantics keeps Postgres traffic on
    /// the same low-priority lane as monitor and SFTP probes.
    fileprivate func runOnUtilityQueuePg<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            postgresQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    fileprivate func runOnUtilityQueuePgVoid(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            postgresQueue.async {
                work()
                continuation.resume()
            }
        }
    }
}

// =============================================================================
// Dedicated Postgres dispatch queue
// =============================================================================
// Why not reuse the existing utility queue? The utility queue lives inside
// `BridgeManager` as a `private` property, and exposing it would widen the
// surface for unrelated consumers. A separate queue also keeps Postgres
// FFI traffic from competing with monitor polls — useful when a slow
// schema introspection runs while the monitor is sampling stats.
// =============================================================================

private nonisolated(unsafe) let postgresQueue: DispatchQueue = {
    DispatchQueue(
        label: "com.mc-ssh.bridge.postgres",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
}()
