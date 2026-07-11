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
    /// Blocked locally: the profile is marked read-only and the statement
    /// (or grid DML) would write. Never reaches the server.
    case readOnlyConnection
    case other(String)

    var errorDescription: String? {
        switch self {
        case .readOnlyConnection:
            return "This connection is read-only (set in connection settings)."
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
        var config = profile.toFfiConfig()

        #if os(iOS)
        // The Rust core's keychain integration is macOS-only (it links the
        // macOS Security framework); on iOS that path is a no-op stub that
        // always reports "no keychain entry". The password actually lives in
        // the native iOS Keychain, saved via `KeychainManager`. Resolve it
        // here and pass it to the FFI as an explicit password so connecting
        // never reaches the stub.
        if case .keychain = profile.auth {
            let account = profile.keychainAccount
            let stored = await MainActor.run {
                KeychainManager.shared.loadPassword(kind: .postgresPassword, account: account)
            }
            guard let password = stored, !password.isEmpty else {
                throw PostgresBridgeError.other(
                    "No saved password for \(profile.user)@\(profile.host). Edit the connection and re-enter it."
                )
            }
            config.auth = .password(password: password)
        }
        #endif

        // The profile stores either a saved SSH profile id (macOS) or an
        // inline SSH endpoint (iOS); the FFI needs the *live connection id*
        // the Rust manager holds. Resolve (auto-opening the SSH connection
        // with stored credentials if needed) and substitute before connecting.
        if let tunnel = profile.tunnel {
            let liveId: String
            do {
                liveId = try await SSHTunnelResolver.liveConnectionId(for: tunnel)
            } catch {
                throw PostgresBridgeError.tunnel(
                    (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
            config.tunnel = FfiPgTunnel(
                sshConnectionId: liveId,
                remoteHost: tunnel.remoteHost,
                remotePort: tunnel.remotePort
            )
        }

        do {
            let connectionId: String = try await runOnUtilityQueuePg {
                try rshellPgConnect(config: config)
            }
            // Remember which profile owns this connection so the read-only
            // guard and the write audit log can resolve it later — every
            // Postgres connection on both platforms passes through here.
            PostgresConnectionAuditRegistry.shared.register(
                connectionId: connectionId,
                profile: profile
            )
            // Track this Postgres connection's use of the shared SSH tunnel so
            // the underlying SSH connection is reclaimed once the last Postgres
            // consumer of it disconnects (see pgDisconnect).
            if let tunnel = profile.tunnel {
                await SSHTunnelResolver.registerTunnelUse(
                    pgConnectionId: connectionId, tunnel: tunnel
                )
            }
            do {
                try await validateMinimumServerVersion(connectionId: connectionId)
            } catch {
                await pgDisconnect(connectionId: connectionId)
                throw error
            }
            return connectionId
        } catch let err as PostgresBridgeError {
            throw err
        } catch let err as FfiPgError {
            throw PostgresBridgeError.from(err)
        } catch {
            throw PostgresBridgeError.other(error.localizedDescription)
        }
    }

    private func validateMinimumServerVersion(connectionId: String) async throws {
        let sessionId = "pgagent-version-check"
        defer {
            Task {
                await self.pgReleaseSession(
                    connectionId: connectionId, sessionId: sessionId)
            }
        }
        let result = try await pgExecute(
            connectionId: connectionId,
            sessionId: sessionId,
            sql: "SHOW server_version_num",
            pageSize: 1)
        guard let text = result.rows.first?.cells.first ?? nil,
              let versionNum = Int(text) else {
            throw PostgresBridgeError.other(
                "Could not determine the PostgreSQL server version. pgAgent requires PostgreSQL 14 or newer.")
        }
        do {
            try PostgresServerVersionPolicy.validate(versionNum: versionNum)
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
        PostgresConnectionAuditRegistry.shared.unregister(connectionId: connectionId)
        // Reclaim the SSH tunnel connection if this was its last Postgres user.
        await SSHTunnelResolver.releaseTunnelUse(pgConnectionId: connectionId)
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
    ///
    /// Write statements (per `PostgresStatementClassifier`) are refused
    /// here when the owning profile is marked read-only — defense in
    /// depth under whatever the UI shows — and recorded in the local
    /// write audit log either way (fire-and-forget; SELECTs are not
    /// recorded to keep the log low-noise).
    func pgExecute(
        connectionId: String,
        sessionId: String,
        sql: String,
        pageSize: UInt32
    ) async throws -> FfiPgExecutionResult {
        let audit = PostgresConnectionAuditRegistry.shared.context(for: connectionId)
        let isWrite = !PostgresStatementClassifier.isReadOnly(sql)
        if isWrite {
            try await Self.throwIfReadOnly(
                connectionId: connectionId,
                auditing: audit, action: .execute, statement: sql
            )
        }
        // Keep the server-side default aligned with the live profile on every
        // leased session. This protects against side-effecting SELECT
        // functions and user-defined functions that a lexical classifier
        // cannot prove safe. The core's smart multi-statement path executes
        // this preamble before the user's statement on the same wire.
        let effectiveSQL: String
        if let audit {
            let readOnly = await Self.liveReadOnlyState(for: audit)
            effectiveSQL = "SET default_transaction_read_only = \(readOnly ? "on" : "off");\n\(sql)"
        } else {
            effectiveSQL = sql
        }
        do {
            let result = try await pgWrapping {
                try rshellPgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: effectiveSQL,
                    pageSize: pageSize
                )
            }
            Self.audit(audit, action: .execute, statement: sql,
                       error: nil, rowsAffected: result.rowsAffected)
            return result
        } catch {
            Self.audit(audit, action: .execute, statement: sql,
                       error: Self.message(for: error), rowsAffected: nil)
            throw error
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
        let audit = PostgresConnectionAuditRegistry.shared.context(for: connectionId)
        let described =
            "UPDATE \(schema).\(table) SET \(column) = \(newValue ?? "NULL") -- ctid \(rowId)"
        try await Self.throwIfReadOnly(
            connectionId: connectionId,
            auditing: audit, action: .updateCell, statement: described
        )
        do {
            let result = try await pgWrapping {
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
            Self.audit(audit, action: .updateCell, statement: described,
                       error: nil, rowsAffected: result.rowsAffected)
            return result
        } catch {
            Self.audit(audit, action: .updateCell, statement: described,
                       error: Self.message(for: error), rowsAffected: nil)
            throw error
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
        let audit = PostgresConnectionAuditRegistry.shared.context(for: connectionId)
        let described =
            "INSERT INTO \(schema).\(table) (\(inputs.map(\.name).joined(separator: ", ")))"
        try await Self.throwIfReadOnly(
            connectionId: connectionId,
            auditing: audit, action: .insertRow, statement: described
        )
        do {
            let result = try await pgWrapping {
                try rshellPgInsertRow(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    schema: schema,
                    table: table,
                    inputs: inputs,
                    returnColumns: returnColumns
                )
            }
            Self.audit(audit, action: .insertRow, statement: described,
                       error: nil, rowsAffected: 1)
            return result
        } catch {
            Self.audit(audit, action: .insertRow, statement: described,
                       error: Self.message(for: error), rowsAffected: nil)
            throw error
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
        let audit = PostgresConnectionAuditRegistry.shared.context(for: connectionId)
        let described = "DELETE FROM \(schema).\(table) -- \(rowIds.count) row(s) by ctid"
        try await Self.throwIfReadOnly(
            connectionId: connectionId,
            auditing: audit, action: .deleteRows, statement: described
        )
        do {
            let result = try await pgWrapping {
                try rshellPgDeleteRows(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    schema: schema,
                    table: table,
                    rowIds: rowIds
                )
            }
            Self.audit(audit, action: .deleteRows, statement: described,
                       error: nil, rowsAffected: result.rowsAffected)
            return result
        } catch {
            Self.audit(audit, action: .deleteRows, statement: described,
                       error: Self.message(for: error), rowsAffected: nil)
            throw error
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
    ///
    /// Transaction control is audited but *not* blocked on read-only
    /// profiles: BEGIN/COMMIT around SELECTs is harmless, and any write
    /// inside the transaction is refused per-statement by `pgExecute`.
    func pgBegin(connectionId: String, sessionId: String) async throws {
        try await auditedTransaction(connectionId: connectionId, sessionId: sessionId, statement: "BEGIN") {
            try rshellPgBegin(connectionId: connectionId, sessionId: sessionId)
        }
    }

    func pgCommit(connectionId: String, sessionId: String) async throws {
        try await auditedTransaction(connectionId: connectionId, sessionId: sessionId, statement: "COMMIT") {
            try rshellPgCommit(connectionId: connectionId, sessionId: sessionId)
        }
    }

    func pgRollback(connectionId: String, sessionId: String) async throws {
        try await auditedTransaction(connectionId: connectionId, sessionId: sessionId, statement: "ROLLBACK") {
            try rshellPgRollback(connectionId: connectionId, sessionId: sessionId)
        }
    }

    private func auditedTransaction(
        connectionId: String,
        sessionId: String,
        statement: String,
        _ work: @escaping () throws -> Void
    ) async throws {
        let audit = PostgresConnectionAuditRegistry.shared.context(for: connectionId)
        do {
            if statement == "BEGIN", let audit {
                let readOnly = await Self.liveReadOnlyState(for: audit)
                _ = try await pgWrapping {
                    try rshellPgExecute(
                        connectionId: connectionId,
                        sessionId: sessionId,
                        sql: "SET default_transaction_read_only = \(readOnly ? "on" : "off")",
                        pageSize: 1
                    )
                }
            }
            try await pgWrapping(work)
            Self.audit(audit, action: .transaction, statement: statement,
                       error: nil, rowsAffected: nil)
        } catch {
            Self.audit(audit, action: .transaction, statement: statement,
                       error: Self.message(for: error), rowsAffected: nil)
            throw error
        }
    }

    // MARK: - Read-only enforcement + write audit

    /// Throws `PostgresBridgeError.readOnlyConnection` when the profile
    /// that owns `connectionId` is currently marked read-only, recording
    /// the refused attempt in the audit log first. The check reads the
    /// *live* profile from `PostgresProfileStore`, so toggling read-only
    /// in the editor applies to open connections immediately; if the
    /// profile was deleted mid-session, the snapshot taken at connect
    /// time decides. Unknown connections (not registered — shouldn't
    /// happen, every connect passes through `pgConnect`) are not blocked:
    /// failing closed here would break all query traffic on a bookkeeping
    /// bug rather than protect anything.
    fileprivate static func throwIfReadOnly(
        connectionId: String,
        auditing audit: PostgresConnectionAuditContext?,
        action: PostgresAuditRecord.Action,
        statement: String
    ) async throws {
        guard let ctx = PostgresConnectionAuditRegistry.shared.context(for: connectionId)
        else { return }
        let isReadOnly = await Self.liveReadOnlyState(for: ctx)
        if isReadOnly {
            Self.audit(audit ?? ctx, action: action, statement: statement,
                       error: "blocked: connection is read-only", rowsAffected: nil)
            throw PostgresBridgeError.readOnlyConnection
        }
    }

    private static func liveReadOnlyState(
        for context: PostgresConnectionAuditContext
    ) async -> Bool {
        await MainActor.run {
            PostgresProfileStore.shared.profile(withId: context.profileId)?.isReadOnly
                ?? context.isReadOnlyAtConnect
        }
    }

    /// Fire-and-forget audit append. Never blocks or fails the query
    /// path — `PostgresAuditLog.record` logs its own failures.
    fileprivate static func audit(
        _ ctx: PostgresConnectionAuditContext?,
        action: PostgresAuditRecord.Action,
        statement: String,
        error: String?,
        rowsAffected: UInt64?
    ) {
        guard let ctx else { return }
        Task.detached(priority: .utility) {
            await PostgresAuditLog.shared.record(
                profileName: ctx.profileName,
                host: ctx.host,
                database: ctx.database,
                user: ctx.user,
                action: action,
                statement: statement,
                error: error,
                rowsAffected: rowsAffected
            )
        }
    }

    fileprivate static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

// =============================================================================
// Connection → profile registry (read-only guard + audit metadata)
// =============================================================================
// The FFI surface identifies connections by opaque `connectionId`, but
// read-only enforcement and the audit log need the owning profile. Every
// connect on both platforms passes through `pgConnect(profile:)`, so this
// registry is populated there and cleared on `pgDisconnect`. Lock-based
// (not an actor) because lookups happen on the hot query path and must
// not force an executor hop before the FFI call is even dispatched.
// =============================================================================

/// Immutable metadata snapshot taken at connect time. `isReadOnlyAtConnect`
/// is only a fallback — the live profile store wins when the profile
/// still exists (see `BridgeManager.throwIfReadOnly`).
struct PostgresConnectionAuditContext: Sendable {
    let profileId: String
    let profileName: String
    let host: String
    let database: String
    let user: String
    let isReadOnlyAtConnect: Bool
}

final class PostgresConnectionAuditRegistry: @unchecked Sendable {
    static let shared = PostgresConnectionAuditRegistry()

    private let lock = NSLock()
    private var contexts: [String: PostgresConnectionAuditContext] = [:]

    private init() {}

    func register(connectionId: String, profile: PostgresProfile) {
        let ctx = PostgresConnectionAuditContext(
            profileId: profile.id,
            profileName: profile.name,
            host: profile.host,
            database: profile.database,
            user: profile.user,
            isReadOnlyAtConnect: profile.isReadOnly
        )
        lock.lock()
        defer { lock.unlock() }
        contexts[connectionId] = ctx
    }

    func unregister(connectionId: String) {
        lock.lock()
        defer { lock.unlock() }
        contexts.removeValue(forKey: connectionId)
    }

    func context(for connectionId: String) -> PostgresConnectionAuditContext? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[connectionId]
    }
}
