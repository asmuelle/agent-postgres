// ---------------------------------------------------------------------------
// Postgres FFI — exposes the database explorer surface (Sprint 1: connect +
// introspect). Query execution and cursor paging land in later sprints.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Debug)]
pub enum FfiPgTlsMode {
    Disable,
    Prefer,
    Require,
    VerifyFull,
}

impl From<FfiPgTlsMode> for ssh_commander_core::PgTlsMode {
    fn from(m: FfiPgTlsMode) -> Self {
        match m {
            FfiPgTlsMode::Disable => Self::Disable,
            FfiPgTlsMode::Prefer => Self::Prefer,
            FfiPgTlsMode::Require => Self::Require,
            FfiPgTlsMode::VerifyFull => Self::VerifyFull,
        }
    }
}

/// How the Swift layer authenticates to Postgres. The two variants map 1:1
/// to `PgAuthMethod`. `Keychain` defers password lookup to the keychain at
/// connect time so the secret never crosses the FFI boundary.
// No `Debug` derive — `Password` carries a plaintext secret and nothing
// in this crate needs to format it; avoid a foot-gun for future callers.
#[derive(uniffi::Enum)]
pub enum FfiPgAuthMethod {
    Password { password: String },
    Keychain { account: String },
}

impl From<FfiPgAuthMethod> for ssh_commander_core::PgAuthMethod {
    fn from(a: FfiPgAuthMethod) -> Self {
        match a {
            FfiPgAuthMethod::Password { password } => Self::Password { password },
            FfiPgAuthMethod::Keychain { account } => Self::Keychain { account },
        }
    }
}

/// Optional SSH tunnel descriptor. Carries the `connection_id` of an
/// already-open SSH connection (managed by `ConnectionManager`) plus the
/// remote endpoint to forward to. Wired up in Sprint 2; Sprint 1 returns
/// `TunnelUnsupported` if this is supplied.
#[derive(uniffi::Record, Debug)]
pub struct FfiPgTunnel {
    pub ssh_connection_id: String,
    pub remote_host: String,
    pub remote_port: u16,
}

// No `Debug` derive — embeds `FfiPgAuthMethod`, which may hold a
// plaintext password; matches `FfiConnectConfig` above.
#[derive(uniffi::Record)]
pub struct FfiPgConfig {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub user: String,
    pub auth: FfiPgAuthMethod,
    pub tls: FfiPgTlsMode,
    pub application_name: Option<String>,
    pub tunnel: Option<FfiPgTunnel>,
    /// Connection timeout in seconds. `None` falls back to the driver default.
    pub connect_timeout_secs: Option<u64>,
    /// Per-profile connection-pool tuning. All `None` to inherit
    /// the built-in defaults (5 max, 5 min idle timeout, 1 min
    /// idle); the macOS edit form surfaces these in an Advanced
    /// section.
    pub max_pool_size: Option<u32>,
    pub idle_timeout_secs: Option<u64>,
    pub min_idle_connections: Option<u32>,
    /// Optional app-owned profile/session identity. When supplied, it
    /// scopes the manager connection id so saved profiles sharing the
    /// same endpoint do not collide.
    pub profile_id: Option<String>,
}

impl From<FfiPgConfig> for ssh_commander_core::PgConfig {
    fn from(c: FfiPgConfig) -> Self {
        Self {
            host: c.host,
            port: c.port,
            database: c.database,
            user: c.user,
            auth: c.auth.into(),
            tls: c.tls.into(),
            application_name: c.application_name,
            connect_timeout_secs: c.connect_timeout_secs,
            max_pool_size: c.max_pool_size,
            idle_timeout_secs: c.idle_timeout_secs,
            min_idle_connections: c.min_idle_connections,
        }
    }
}

/// Typed Postgres errors surfaced to Swift. Matches the `PgError`
/// classifications the core layer produces; pattern-matchable from Swift
/// without substring-checking error strings.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiPgError {
    #[error("postgres connect failed: {detail}")]
    Connect { detail: String },
    #[error("postgres auth failed: {detail}")]
    Auth { detail: String },
    #[error("postgres tls setup failed: {detail}")]
    Tls { detail: String },
    #[error("ssh tunnel error: {detail}")]
    Tunnel { detail: String },
    /// Tunnel was requested but the SSH connection it depends on isn't
    /// registered in the manager. Distinct from `Tunnel { _ }` so the
    /// UI can offer the right remediation: open the SSH connection
    /// first, then retry.
    #[error("ssh tunnel source missing: {detail}")]
    TunnelSourceMissing { detail: String },
    /// The cursor handle no longer references the connection's
    /// active result set — a subsequent `execute` superseded it.
    /// UI shows "result no longer available" and pins what was
    /// already fetched.
    #[error("cursor no longer available: {detail}")]
    CursorExpired { detail: String },
    /// The pool is at its `max_size` and all connections are leased
    /// to other sessions. UI can show "too many open queries — close
    /// a tab to continue".
    #[error("connection pool exhausted: {detail}")]
    PoolExhausted { detail: String },
    #[error("postgres not connected: {detail}")]
    NotConnected { detail: String },
    /// A server-side error carrying PostgreSQL's structured fields, so the UI
    /// can show the SQLSTATE, the failing constraint, an editor position to
    /// underline, and the server's detail/hint instead of one opaque string.
    /// A `sqlstate` in class 25 (e.g. `25P02`) means the session's transaction
    /// is aborted and needs ROLLBACK.
    #[error("ERROR [{sqlstate}]: {message}")]
    Database {
        sqlstate: String,
        message: String,
        detail: Option<String>,
        hint: Option<String>,
        /// 1-based character offset into the submitted SQL, when reported.
        position: Option<u32>,
        constraint: Option<String>,
        column: Option<String>,
        table: Option<String>,
        schema: Option<String>,
    },
    #[error("{detail}")]
    Other { detail: String },
}

impl From<ssh_commander_core::PgError> for FfiPgError {
    fn from(e: ssh_commander_core::PgError) -> Self {
        match e {
            ssh_commander_core::PgError::Connect(detail) => Self::Connect { detail },
            ssh_commander_core::PgError::Auth(detail) => Self::Auth { detail },
            ssh_commander_core::PgError::Tls(detail) => Self::Tls { detail },
            // Client-side validation failures (e.g. an invalid type name or
            // identifier in an edit op), added to PgError in core 0.2. Surface
            // as a generic error — no dedicated FFI variant needed.
            ssh_commander_core::PgError::InvalidInput(detail) => Self::Other { detail },
            ssh_commander_core::PgError::Tunnel(detail) => Self::Tunnel { detail },
            ssh_commander_core::PgError::TunnelSourceMissing(detail) => {
                Self::TunnelSourceMissing { detail }
            }
            ssh_commander_core::PgError::CursorExpired(detail) => Self::CursorExpired { detail },
            ssh_commander_core::PgError::PoolExhausted(used, max) => Self::PoolExhausted {
                detail: format!("{used} of {max} connections leased"),
            },
            ssh_commander_core::PgError::Driver(driver_err) => match driver_err.as_db_error() {
                Some(db) => Self::Database {
                    sqlstate: db.code().code().to_string(),
                    message: db.message().to_string(),
                    detail: db.detail().map(str::to_string),
                    hint: db.hint().map(str::to_string),
                    position: match db.position() {
                        Some(tokio_postgres::error::ErrorPosition::Original(p)) => Some(*p),
                        Some(tokio_postgres::error::ErrorPosition::Internal {
                            position, ..
                        }) => Some(*position),
                        None => None,
                    },
                    constraint: db.constraint().map(str::to_string),
                    column: db.column().map(str::to_string),
                    table: db.table().map(str::to_string),
                    schema: db.schema().map(str::to_string),
                },
                None => Self::Other {
                    detail: driver_err.to_string(),
                },
            },
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgDatabase {
    pub name: String,
    pub owner: String,
    pub is_template: bool,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgSchema {
    pub name: String,
    pub owner: String,
    pub is_system: bool,
}

#[derive(uniffi::Enum, Debug)]
pub enum FfiPgRelationKind {
    Table,
    View,
    MaterializedView,
    PartitionedTable,
    ForeignTable,
}

impl From<ssh_commander_core::RelationKind> for FfiPgRelationKind {
    fn from(k: ssh_commander_core::RelationKind) -> Self {
        match k {
            ssh_commander_core::RelationKind::Table => Self::Table,
            ssh_commander_core::RelationKind::View => Self::View,
            ssh_commander_core::RelationKind::MaterializedView => Self::MaterializedView,
            ssh_commander_core::RelationKind::PartitionedTable => Self::PartitionedTable,
            ssh_commander_core::RelationKind::ForeignTable => Self::ForeignTable,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgRelation {
    pub schema: String,
    pub name: String,
    pub kind: FfiPgRelationKind,
    pub owner: String,
    /// Estimated rows from `pg_class.reltuples`. Negative when statistics
    /// have not been gathered.
    pub estimated_rows: f32,
}

/// Build a stable connection id for the macOS connection map. Mirrors the
/// SSH form `user@host:port` but namespaces with `pg:` so a Postgres and
/// SSH connection sharing host/user/port can coexist in the same map.
fn pg_connection_id(cfg: &ssh_commander_core::PgConfig, profile_id: Option<&str>) -> String {
    let base = format!("pg:{}@{}:{}/{}", cfg.user, cfg.host, cfg.port, cfg.database);
    match profile_id.filter(|id| !id.is_empty()) {
        Some(id) => format!("{base}#{id}"),
        None => base,
    }
}

/// Establish a Postgres connection. Returns the canonical connection id
/// (`"pg:user@host:port/db"`) on success.
#[uniffi::export]
pub fn rshell_pg_connect(config: FfiPgConfig) -> Result<String, FfiPgError> {
    let bridge = MacOsBridge::global();
    let profile_id = config.profile_id.clone();
    // ssh-commander-core 0.2: the SSH tunnel is no longer a field on
    // PgConfig — the ConnectionManager owns the tunnel seam and takes it
    // as a separate argument. Extract it before consuming `config`.
    let tunnel = config
        .tunnel
        .as_ref()
        .map(|t| ssh_commander_core::SshTunnelRef {
            ssh_connection_id: t.ssh_connection_id.clone(),
            remote_host: t.remote_host.clone(),
            remote_port: t.remote_port,
        });
    let core_cfg: ssh_commander_core::PgConfig = config.into();
    let connection_id = pg_connection_id(&core_cfg, profile_id.as_deref());
    let conn_id = connection_id.clone();
    let cm = bridge.connection_manager.clone();

    bridge
        .runtime
        .block_on(async move {
            cm.create_postgres_connection(conn_id, core_cfg, tunnel)
                .await
        })
        .map_err(|e| {
            // The manager wraps PgError in anyhow; downcast back so we
            // keep the typed classification through to Swift.
            match e.downcast::<ssh_commander_core::PgError>() {
                Ok(pg_err) => FfiPgError::from(pg_err),
                Err(other) => FfiPgError::Other {
                    detail: sanitize_error(other),
                },
            }
        })?;

    if let Some(tx) = ssh_commander_core::event_bus::event_sender() {
        let _ = tx.send(ssh_commander_core::event_bus::CoreEvent::ConnectionStatus {
            connection_id: connection_id.clone(),
            status: ssh_commander_core::event_bus::ConnectionStatus::Connected,
        });
    }
    Ok(connection_id)
}

#[uniffi::export]
pub fn rshell_pg_disconnect(connection_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id_for_close = connection_id.clone();
    let result = bridge
        .runtime
        .block_on(async move { cm.close_postgres_connection(&conn_id_for_close).await });

    if let Some(tx) = ssh_commander_core::event_bus::event_sender() {
        let _ = tx.send(ssh_commander_core::event_bus::CoreEvent::ConnectionStatus {
            connection_id: connection_id.clone(),
            status: ssh_commander_core::event_bus::ConnectionStatus::Disconnected,
        });
    }

    match result {
        Ok(_) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(sanitize_error(e)),
            value: None,
        },
    }
}

async fn with_pg_pool<F, Fut, T>(connection_id: &str, op: F) -> Result<T, FfiPgError>
where
    F: FnOnce(std::sync::Arc<ssh_commander_core::PgPool>) -> Fut,
    Fut: std::future::Future<Output = Result<T, ssh_commander_core::PgError>>,
{
    let bridge = MacOsBridge::global();
    let pool = bridge
        .connection_manager
        .get_postgres_pool(connection_id)
        .await
        .ok_or_else(|| FfiPgError::NotConnected {
            detail: format!("no postgres connection registered as {connection_id}"),
        })?;
    op(pool).await.map_err(FfiPgError::from)
}

#[uniffi::export]
pub fn rshell_pg_list_databases(connection_id: String) -> Result<Vec<FfiPgDatabase>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(
            &connection_id,
            |pool| async move { pool.list_databases().await },
        )
        .await
        .map(|dbs| {
            dbs.into_iter()
                .map(|d| FfiPgDatabase {
                    name: d.name,
                    owner: d.owner,
                    is_template: d.is_template,
                })
                .collect()
        })
    })
}

#[uniffi::export]
pub fn rshell_pg_list_schemas(
    connection_id: String,
    database: Option<String>,
) -> Result<Vec<FfiPgSchema>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.list_schemas_in(database.as_deref()).await
        })
        .await
        .map(|schemas| {
            schemas
                .into_iter()
                .map(|s| FfiPgSchema {
                    name: s.name,
                    owner: s.owner,
                    is_system: s.is_system,
                })
                .collect()
        })
    })
}

// -----------------------------------------------------------------------
// Live-Postgres integration tier (opt-in).
//
// These exercise the real query/edit/export path end-to-end against a
// running Postgres. They are OFF by default: `it_config` returns `None`
// unless `PG_AGENT_IT=1` is set, so `cargo test` stays green on machines
// without a database. CI sets `PG_AGENT_IT=1` plus the standard `PG*`
// libpq env vars and runs them on a fresh server.
//
//   PG_AGENT_IT=1 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres \
//       cargo test --lib pg_it_ -- --test-threads=1 --nocapture
// -----------------------------------------------------------------------
#[cfg(test)]
/// Build a connection config for the live tier, or `None` to skip. Each
/// test passes a distinct `profile` so its manager connection id (and pool)
/// is isolated from the others even under parallel execution.
fn it_config(profile: &str) -> Option<FfiPgConfig> {
    if std::env::var("PG_AGENT_IT").ok().as_deref() != Some("1") {
        return None;
    }
    let port = std::env::var("PGPORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(5432);
    Some(FfiPgConfig {
        host: std::env::var("PGHOST").unwrap_or_else(|_| "127.0.0.1".into()),
        port,
        database: std::env::var("PGDATABASE").unwrap_or_else(|_| "postgres".into()),
        user: std::env::var("PGUSER").unwrap_or_else(|_| "postgres".into()),
        auth: FfiPgAuthMethod::Password {
            password: std::env::var("PGPASSWORD").unwrap_or_default(),
        },
        // Prefer (not Require) so the tier works against a plain test server
        // with no TLS while still exercising the negotiation path.
        tls: FfiPgTlsMode::Prefer,
        application_name: Some("pg-agent-it".into()),
        tunnel: None,
        connect_timeout_secs: Some(10),
        max_pool_size: None,
        idle_timeout_secs: None,
        min_idle_connections: None,
        profile_id: Some(profile.into()),
    })
}

#[cfg(test)]
mod pg_connect_tests {
    use super::*;

    #[test]
    fn pg_connection_id_is_profile_scoped_when_profile_id_is_supplied() {
        let cfg = ssh_commander_core::PgConfig {
            host: "db.example.com".into(),
            port: 5432,
            database: "app".into(),
            user: "u".into(),
            auth: ssh_commander_core::PgAuthMethod::Password {
                password: "pw".into(),
            },
            tls: ssh_commander_core::PgTlsMode::Disable,
            application_name: None,
            connect_timeout_secs: None,
            max_pool_size: None,
            idle_timeout_secs: None,
            min_idle_connections: None,
        };

        assert_eq!(
            pg_connection_id(&cfg, Some("profile-a")),
            "pg:u@db.example.com:5432/app#profile-a"
        );
        assert_eq!(pg_connection_id(&cfg, None), "pg:u@db.example.com:5432/app");
        assert_eq!(
            pg_connection_id(&cfg, Some("")),
            "pg:u@db.example.com:5432/app"
        );
    }

    #[test]
    fn pg_connect_with_tunnel_to_unknown_ssh_returns_source_missing() {
        // A tunnel ref pointing at an SSH connection that isn't open
        // surfaces a typed `TunnelSourceMissing` so the UI can prompt
        // the user to open SSH first instead of opaquely failing.
        rshell_init();
        let cfg = FfiPgConfig {
            host: "127.0.0.1".into(),
            port: 5432,
            database: "test".into(),
            user: "u".into(),
            auth: FfiPgAuthMethod::Password {
                password: String::new(),
            },
            tls: FfiPgTlsMode::Disable,
            application_name: None,
            tunnel: Some(FfiPgTunnel {
                ssh_connection_id: "ghost-ssh-id".into(),
                remote_host: "db".into(),
                remote_port: 5432,
            }),
            connect_timeout_secs: Some(1),
            max_pool_size: None,
            idle_timeout_secs: None,
            min_idle_connections: None,
            profile_id: None,
        };
        match rshell_pg_connect(cfg) {
            Err(FfiPgError::TunnelSourceMissing { detail }) => {
                assert!(detail.contains("ghost-ssh-id"));
            }
            Err(other) => panic!("expected TunnelSourceMissing, got {other:?}"),
            Ok(id) => panic!("expected error, got connection id {id}"),
        }
    }

    // Live tunnel tier: SSH to localhost, then Postgres through the
    // tunnel. Opt-in via PG_AGENT_IT_SSH_KEY (path to a passphrase-less
    // private key authorized for the current user on localhost) on top
    // of the usual PG_AGENT_IT=1. Exercises the exact path the app
    // uses: rshell_connect → rshell_pg_connect with the *returned*
    // connection id in the tunnel ref — the id contract the Swift
    // layer historically violated by passing its profile UUID instead.
    #[test]
    fn pg_it_connect_through_ssh_tunnel() {
        let Some(mut cfg) = it_config("it-tunnel") else {
            return;
        };
        let Ok(key_path) = std::env::var("PG_AGENT_IT_SSH_KEY") else {
            return;
        };
        rshell_init();

        let ssh_user = std::env::var("USER").unwrap_or_default();
        let ssh_id = rshell_connect(FfiConnectConfig {
            host: "127.0.0.1".into(),
            port: 22,
            username: ssh_user,
            password: None,
            key_path: Some(key_path),
            passphrase: None,
            use_agent: false,
            agent_identity_hint: None,
            session_id: Some("it-tunnel".into()),
        })
        .expect("ssh connect to localhost");

        // Tunnel to the Postgres the plain tier already targets. The
        // direct host/port are deliberately bogus — everything must
        // flow through the forward.
        let pg_port = cfg.port;
        cfg.tunnel = Some(FfiPgTunnel {
            ssh_connection_id: ssh_id.clone(),
            remote_host: "127.0.0.1".into(),
            remote_port: pg_port,
        });
        cfg.host = "tunnel-required.invalid".into();
        cfg.port = 1;

        let conn = rshell_pg_connect(cfg).expect("pg connect through tunnel");
        let res = rshell_pg_execute(conn.clone(), "it-tunnel".into(), "SELECT 41 + 1".into(), 1)
            .expect("query through tunnel");
        assert_eq!(res.rows[0].cells[0].as_deref(), Some("42"));

        let _ = rshell_pg_release_session(conn.clone(), "it-tunnel".into());
        let _ = rshell_pg_disconnect(conn);
        let _ = rshell_disconnect(ssh_id);
    }

    #[test]
    fn pg_disconnect_unknown_id_is_ok() {
        rshell_init();
        let result = rshell_pg_disconnect("pg:nobody@nowhere:5432/none".into());
        assert!(result.success);
    }
}
