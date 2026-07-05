// Live-activity monitoring: pg_stat_activity sessions, pg_locks, and
// backend cancel/terminate. Part of `crate::ffi` via include!.

#[derive(uniffi::Record, Debug)]
pub struct FfiPgSessionDetail {
    pub pid: i32,
    pub datname: String,
    pub usename: String,
    pub client_addr: Option<String>,
    pub state: String,
    pub query: Option<String>,
    pub wait_event: Option<String>,
    pub query_start: Option<u64>,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgLockDetail {
    pub pid: i32,
    pub relation: Option<String>,
    pub mode: String,
    pub granted: bool,
    pub blocked_by_pid: Option<i32>,
}

#[uniffi::export]
pub fn rshell_pg_list_sessions(
    connection_id: String,
) -> Result<Vec<FfiPgSessionDetail>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            let session_id = "pg-activity-sessions".to_string();
            let sql = "
                SELECT pid, datname, usename, client_addr::text, state, query, wait_event,
                       EXTRACT(epoch FROM query_start)::int8
                FROM pg_stat_activity
                WHERE state IS NOT NULL AND pid <> pg_backend_pid()
                ORDER BY query_start DESC
            ";
            let outcome = pool.execute(&session_id, sql, 1000).await?;
            let mut sessions = Vec::new();
            for row in outcome.rows {
                if row.len() >= 8 {
                    let pid = row[0].as_deref().unwrap_or("0").parse::<i32>().unwrap_or(0);
                    let datname = row[1].clone().unwrap_or_default();
                    let usename = row[2].clone().unwrap_or_default();
                    let client_addr = row[3].clone();
                    let state = row[4].clone().unwrap_or_default();
                    let query = row[5].clone();
                    let wait_event = row[6].clone();
                    let query_start = row[7].as_deref().and_then(|s| s.parse::<u64>().ok());
                    sessions.push(FfiPgSessionDetail {
                        pid,
                        datname,
                        usename,
                        client_addr,
                        state,
                        query,
                        wait_event,
                        query_start,
                    });
                }
            }
            Ok(sessions)
        })
        .await
    })
}

#[uniffi::export]
pub fn rshell_pg_cancel_backend(connection_id: String, pid: i32) -> Result<bool, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            let session_id = "pg-triage-cancel".to_string();
            // `pid` is a typed i32 sourced from pg_stat_activity; its decimal
            // form cannot carry SQL metacharacters, so direct formatting is
            // injection-safe. (The core pool exposes no bound-parameter execute;
            // if that changes, prefer `pg_cancel_backend($1)`.)
            let sql = format!("SELECT pg_cancel_backend({pid})");
            let outcome = pool.execute(&session_id, &sql, 1).await?;
            let mut success = false;
            if let Some(row) = outcome.rows.first()
                && let Some(cell) = row.first()
            {
                success = cell.as_deref() == Some("t") || cell.as_deref() == Some("true");
            }
            Ok(success)
        })
        .await
    })
}

#[uniffi::export]
pub fn rshell_pg_terminate_backend(connection_id: String, pid: i32) -> Result<bool, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            let session_id = "pg-triage-terminate".to_string();
            // `pid` is a typed i32 sourced from pg_stat_activity; its decimal
            // form cannot carry SQL metacharacters, so direct formatting is
            // injection-safe. (The core pool exposes no bound-parameter execute;
            // if that changes, prefer `pg_terminate_backend($1)`.)
            let sql = format!("SELECT pg_terminate_backend({pid})");
            let outcome = pool.execute(&session_id, &sql, 1).await?;
            let mut success = false;
            if let Some(row) = outcome.rows.first()
                && let Some(cell) = row.first()
            {
                success = cell.as_deref() == Some("t") || cell.as_deref() == Some("true");
            }
            Ok(success)
        })
        .await
    })
}

#[uniffi::export]
pub fn rshell_pg_list_locks(connection_id: String) -> Result<Vec<FfiPgLockDetail>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            let session_id = "pg-activity-locks".to_string();
            let sql = "
                SELECT
                    l.pid,
                    l.relation::regclass::text,
                    l.mode,
                    l.granted,
                    (SELECT blocking.pid 
                     FROM pg_locks blocking 
                     WHERE blocking.locktype = l.locktype
                       AND blocking.database IS NOT DISTINCT FROM l.database
                       AND blocking.relation IS NOT DISTINCT FROM l.relation
                       AND blocking.page IS NOT DISTINCT FROM l.page
                       AND blocking.tuple IS NOT DISTINCT FROM l.tuple
                       AND blocking.virtualxid IS NOT DISTINCT FROM l.virtualxid
                       AND blocking.transactionid IS NOT DISTINCT FROM l.transactionid
                       AND blocking.classid IS NOT DISTINCT FROM l.classid
                       AND blocking.objid IS NOT DISTINCT FROM l.objid
                       AND blocking.objsubid IS NOT DISTINCT FROM l.objsubid
                       AND blocking.pid <> l.pid
                       AND blocking.granted
                     LIMIT 1) AS blocked_by_pid
                FROM pg_locks l
                WHERE l.relation IS NOT NULL AND l.pid <> pg_backend_pid()
            ";
            let outcome = pool.execute(&session_id, sql, 1000).await?;
            let mut locks = Vec::new();
            for row in outcome.rows {
                if row.len() >= 5 {
                    let pid = row[0].as_deref().unwrap_or("0").parse::<i32>().unwrap_or(0);
                    let relation = row[1].clone();
                    let mode = row[2].clone().unwrap_or_default();
                    let granted_raw = row[3].as_deref().unwrap_or("f");
                    let granted = granted_raw == "t" || granted_raw == "true";
                    let blocked_by_pid = row[4].as_deref().and_then(|s| s.parse::<i32>().ok());
                    locks.push(FfiPgLockDetail {
                        pid,
                        relation,
                        mode,
                        granted,
                        blocked_by_pid,
                    });
                }
            }
            Ok(locks)
        })
        .await
    })
}
