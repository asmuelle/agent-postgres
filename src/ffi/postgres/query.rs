// Query execution, cursor paging, transactions, and session-scoped
// statements. Part of `crate::ffi` via include! — see mod.rs.

#[derive(uniffi::Record, Debug)]
pub struct FfiPgColumn {
    pub name: String,
    /// Postgres type OID. Stable across server versions; the UI uses
    /// it to classify the column for alignment / formatting (numeric
    /// columns right-align, booleans render as ✓/✗, timestamps get
    /// special tooltips).
    pub type_oid: u32,
    /// Human-readable type name (`int4`, `timestamptz`, `jsonb`, …).
    /// Surfaces in tooltips and acts as a fallback label for OIDs
    /// the affinity decoder doesn't classify.
    pub type_name: String,
}

/// Single row of a query result. `cells.len() == columns.len()`.
/// Each cell is the server's text representation of the value, or
/// `None` for SQL NULL.
#[derive(uniffi::Record, Debug)]
pub struct FfiPgRow {
    pub cells: Vec<Option<String>>,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgExecutionResult {
    pub columns: Vec<FfiPgColumn>,
    pub rows: Vec<FfiPgRow>,
    /// `RowsAffected` from the last completed statement, when the
    /// server reports one.
    pub rows_affected: Option<u64>,
    /// Opaque handle to the server-side cursor. `Some(_)` when more
    /// rows remain — call `rshell_pg_fetch_page` with this id to
    /// stream more, then `rshell_pg_close_query` when done. `None`
    /// when the result is fully contained or the statement does
    /// not return rows.
    pub cursor_id: Option<String>,
}

impl From<ssh_commander_core::ExecutionOutcome> for FfiPgExecutionResult {
    fn from(r: ssh_commander_core::ExecutionOutcome) -> Self {
        Self {
            columns: r
                .columns
                .into_iter()
                .map(|c| FfiPgColumn {
                    name: c.name,
                    type_oid: c.type_oid,
                    type_name: c.type_name,
                })
                .collect(),
            rows: r.rows.into_iter().map(|cells| FfiPgRow { cells }).collect(),
            rows_affected: r.rows_affected,
            cursor_id: r.cursor_id,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgPageResult {
    pub rows: Vec<FfiPgRow>,
    /// `true` when the page filled to the requested count (more may
    /// be available); `false` when the cursor exhausted on this fetch.
    pub has_more: bool,
}

impl From<ssh_commander_core::PageResult> for FfiPgPageResult {
    fn from(p: ssh_commander_core::PageResult) -> Self {
        Self {
            rows: p.rows.into_iter().map(|cells| FfiPgRow { cells }).collect(),
            has_more: p.has_more,
        }
    }
}

/// Run a SQL statement against the pool's connection assigned to
/// `session_id`, leasing one if the session is new. When more rows
/// remain server-side, the result carries a `cursor_id` for use with
/// `rshell_pg_fetch_page`. Sessions are isolated: opening a cursor
/// in session A doesn't affect session B's cursor.
#[uniffi::export]
pub fn rshell_pg_execute(
    connection_id: String,
    session_id: String,
    sql: String,
    page_size: u32,
) -> Result<FfiPgExecutionResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.execute(&session_id, &sql, page_size as usize).await
        })
        .await
        .map(FfiPgExecutionResult::from)
    })
}

/// Fetch the next page from a cursor opened by `rshell_pg_execute`
/// in the same session. Returns `CursorExpired` if the same session
/// opened a different cursor in between, or if the session was
/// released.
#[uniffi::export]
pub fn rshell_pg_fetch_page(
    connection_id: String,
    session_id: String,
    cursor_id: String,
    count: u32,
) -> Result<FfiPgPageResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.fetch_page(&session_id, &cursor_id, count as usize)
                .await
        })
        .await
        .map(FfiPgPageResult::from)
    })
}

/// Close a cursor on the given session. Idempotent — closing a stale
/// cursor is a silent success.
#[uniffi::export]
pub fn rshell_pg_close_query(
    connection_id: String,
    session_id: String,
    cursor_id: String,
) -> FfiResult {
    let bridge = MacOsBridge::global();
    let result: Result<(), FfiPgError> = bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.close_query(&session_id, &cursor_id).await
        })
        .await
    });
    match result {
        Ok(()) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

/// Begin an explicit transaction on the session's pinned connection. The
/// session keeps its connection leased until `rshell_pg_commit` /
/// `rshell_pg_rollback` (and a final `rshell_pg_release_session`); statements
/// run on the same `session_id` in between share the transaction.
#[uniffi::export]
pub fn rshell_pg_begin(connection_id: String, session_id: String) -> Result<(), FfiPgError> {
    pg_session_statement(connection_id, session_id, "BEGIN")
}

/// Commit the session's open transaction. Committing a transaction that has
/// already failed (SQLSTATE class 25) rolls it back instead — standard
/// Postgres behavior.
#[uniffi::export]
pub fn rshell_pg_commit(connection_id: String, session_id: String) -> Result<(), FfiPgError> {
    pg_session_statement(connection_id, session_id, "COMMIT")
}

/// Roll back the session's open (or failed) transaction.
#[uniffi::export]
pub fn rshell_pg_rollback(connection_id: String, session_id: String) -> Result<(), FfiPgError> {
    pg_session_statement(connection_id, session_id, "ROLLBACK")
}

/// Run a single fixed transaction-control statement on the session's pooled
/// connection. Shares the lease/cursor machinery of `rshell_pg_execute`.
fn pg_session_statement(
    connection_id: String,
    session_id: String,
    sql: &str,
) -> Result<(), FfiPgError> {
    let bridge = MacOsBridge::global();
    let sql = sql.to_string();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.execute(&session_id, &sql, 1).await.map(|_| ())
        })
        .await
    })
}

/// Result of a single-cell UPDATE. Surfaced as a typed record so the
/// UI can branch on `rows_affected == 0` (row was modified or deleted
/// by a concurrent session) without parsing strings.
#[derive(uniffi::Record, Debug)]
pub struct FfiPgUpdateResult {
    pub rows_affected: u64,
}

#[cfg(test)]
mod pg_query_tests {
    use super::*;

    #[test]
    fn pg_execute_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_execute(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "SELECT 1".into(),
            100,
        ) {
            Err(FfiPgError::NotConnected { detail }) => {
                assert!(detail.contains("postgres"));
            }
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_fetch_page_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_fetch_page(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "c_does_not_matter".into(),
            100,
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_close_query_on_unknown_id_is_failure_result() {
        rshell_init();
        let result = rshell_pg_close_query(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "c_irrelevant".into(),
        );
        assert!(!result.success);
    }

    #[test]
    fn pg_cancel_on_unknown_id_returns_failure_result() {
        rshell_init();
        let result = rshell_pg_cancel("pg:nobody@nowhere:5432/none".into(), "session-1".into());
        assert!(!result.success);
        assert!(result.error.unwrap_or_default().contains("postgres"));
    }

    #[test]
    fn pg_release_session_on_unknown_id_is_failure_result() {
        rshell_init();
        let result =
            rshell_pg_release_session("pg:nobody@nowhere:5432/none".into(), "session-1".into());
        assert!(!result.success);
    }

    #[test]
    fn pg_it_connect_execute_cursor_roundtrip() {
        let Some(cfg) = it_config("it-cursor") else {
            return;
        };
        rshell_init();
        let conn = rshell_pg_connect(cfg).expect("connect to live postgres");
        let sid = "it-cursor".to_string();

        // Fresh table with five rows.
        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DROP TABLE IF EXISTS pg_agent_it_cursor".into(),
            1,
        )
        .expect("drop");
        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "CREATE TABLE pg_agent_it_cursor (id int primary key, label text)".into(),
            1,
        )
        .expect("create");
        let ins = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "INSERT INTO pg_agent_it_cursor SELECT g, 'row-' || g FROM generate_series(1, 5) g"
                .into(),
            1,
        )
        .expect("insert");
        assert_eq!(ins.rows_affected, Some(5));

        // A page smaller than the result forces the server to open a cursor.
        let first = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "SELECT id, label FROM pg_agent_it_cursor ORDER BY id".into(),
            2,
        )
        .expect("select");
        assert_eq!(first.columns.len(), 2);
        assert_eq!(first.columns[0].name, "id");
        assert_eq!(first.columns[1].name, "label");
        assert_eq!(first.rows.len(), 2, "first page holds page_size rows");
        assert_eq!(first.rows[0].cells[0].as_deref(), Some("1"));
        let cursor = first
            .cursor_id
            .clone()
            .expect("cursor opened for a result larger than the page");

        // Drain across the cursor boundary.
        let page2 = rshell_pg_fetch_page(conn.clone(), sid.clone(), cursor.clone(), 2)
            .expect("fetch page 2");
        assert_eq!(page2.rows.len(), 2);
        assert!(page2.has_more, "a full page means more may remain");
        let page3 = rshell_pg_fetch_page(conn.clone(), sid.clone(), cursor.clone(), 2)
            .expect("fetch page 3");
        assert_eq!(page3.rows.len(), 1, "final row");
        assert!(!page3.has_more, "cursor exhausted");

        let _ = rshell_pg_close_query(conn.clone(), sid.clone(), cursor);
        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DROP TABLE IF EXISTS pg_agent_it_cursor".into(),
            1,
        )
        .expect("drop teardown");
        let _ = rshell_pg_release_session(conn.clone(), sid);
        let _ = rshell_pg_disconnect(conn);
    }

    #[test]
    fn pg_it_dml_and_parquet_roundtrip() {
        let Some(cfg) = it_config("it-dml") else {
            return;
        };
        rshell_init();
        let conn = rshell_pg_connect(cfg).expect("connect to live postgres");
        let sid = "it-dml".to_string();

        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DROP TABLE IF EXISTS pg_agent_it_dml".into(),
            1,
        )
        .expect("drop");
        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "CREATE TABLE pg_agent_it_dml (id int primary key, label text)".into(),
            1,
        )
        .expect("create");

        // INSERT / UPDATE / DELETE through the execute path, asserting the
        // server-reported rows_affected on each — the write surface a query
        // tab actually uses.
        let ins = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "INSERT INTO pg_agent_it_dml VALUES (1, 'orig'), (2, 'keep')".into(),
            1,
        )
        .expect("insert");
        assert_eq!(ins.rows_affected, Some(2));

        let upd = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "UPDATE pg_agent_it_dml SET label = 'edited' WHERE id = 1".into(),
            1,
        )
        .expect("update");
        assert_eq!(upd.rows_affected, Some(1));

        let sel = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "SELECT id, label FROM pg_agent_it_dml ORDER BY id".into(),
            100,
        )
        .expect("select");
        assert_eq!(sel.rows.len(), 2);
        assert_eq!(sel.rows[0].cells[1].as_deref(), Some("edited"));
        assert!(
            sel.cursor_id.is_none(),
            "a result that fits the page should not open a cursor"
        );

        // Parquet export round-trip of the full result set.
        let path = std::env::temp_dir()
            .join(format!("pg_agent_it_{}.parquet", std::process::id()))
            .to_string_lossy()
            .into_owned();
        let writer = rshell_pg_parquet_open(path.clone(), vec!["id".into(), "label".into()])
            .expect("parquet open");
        rshell_pg_parquet_append(writer, sel.rows).expect("parquet append");
        rshell_pg_parquet_close(writer).expect("parquet close");
        assert!(
            std::fs::metadata(&path)
                .map(|m| m.len() > 0)
                .unwrap_or(false),
            "parquet file should be written and non-empty"
        );
        let _ = std::fs::remove_file(&path);

        let del = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DELETE FROM pg_agent_it_dml WHERE id = 2".into(),
            1,
        )
        .expect("delete");
        assert_eq!(del.rows_affected, Some(1));

        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DROP TABLE IF EXISTS pg_agent_it_dml".into(),
            1,
        )
        .expect("drop teardown");
        let _ = rshell_pg_release_session(conn.clone(), sid);
        let _ = rshell_pg_disconnect(conn);
    }
}
