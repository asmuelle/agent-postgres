// `FfiPgError` intentionally carries PostgreSQL's structured fields (SQLSTATE,
// constraint, position, detail, hint, …), which pushes the enum past clippy's
// large-Err threshold. UniFFI marshals errors across the FFI boundary by value
// regardless, and these `block_on` FFI calls are not hot paths, so the
// stack-size of `Result<_, FfiPgError>` is irrelevant here.
#![allow(clippy::result_large_err)]

use crate::bridge::MacOsBridge;
use crate::doctor;
use crate::security_patch;

// ---------------------------------------------------------------------------
// Protocol types — shared between Rust and Swift via uniffi-generated bindings.
// These are the wire-format records for every FFI operation.
// ---------------------------------------------------------------------------

/// Parameters for creating an SSH connection.
/// Maps to a uniffi `dictionary` in Swift; generated bindings produce
/// a native Swift struct that callers construct inline.
#[derive(uniffi::Record)]
pub struct FfiConnectConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    /// Password for password-based auth. May be `None` when using key-based auth.
    pub password: Option<String>,
    /// Filesystem path to a private key for key-based auth. May be `None`
    /// when using password auth.
    pub key_path: Option<String>,
    /// Optional passphrase to decrypt the private key.
    pub passphrase: Option<String>,
    /// Use identities from SSH_AUTH_SOCK instead of a password or key file.
    pub use_agent: bool,
    /// Optional public-key-base64 substring used to select one agent identity.
    pub agent_identity_hint: Option<String>,
    /// Optional unique suffix that lets the same `(user, host, port)` triple
    /// be opened more than once (e.g., one terminal tab per session). When
    /// `Some("abc")`, the connection is keyed as `"user@host:port#abc"` in
    /// `pty_sessions`. When `None`, the bare key is used (suitable for the
    /// simple "single connection per host" case).
    pub session_id: Option<String>,
}

/// Universal result struct for FFI operations.
///
/// `success` indicates whether the operation completed. When `success` is
/// `false`, `error` contains a human-readable description of what went wrong.
/// When `success` is `true`, `value` may carry extra payload (e.g. a PTY
/// generation counter as a JSON string).
#[derive(uniffi::Record)]
pub struct FfiResult {
    pub success: bool,
    pub error: Option<String>,
    /// JSON-encoded extra payload (e.g. `{"generation": 3}` for PTY start)
    pub value: Option<String>,
}

/// An event emitted by the Rust core and delivered to the Swift layer via
/// the registered `FfiEventCallback`.
///
/// `ty` identifies the event kind: `"pty_output"`, `"connection_status"`,
/// `"transfer_progress"`, or `"action_complete"`.
///
/// `connection_id` is the connection this event relates to.
///
/// `payload` is a JSON-encoded string with the event-specific data.
#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiEvent {
    pub ty: String,
    pub connection_id: String,
    pub payload: String,
}

// ---------------------------------------------------------------------------
// Callback interface — the Swift side implements this to receive events.
// ---------------------------------------------------------------------------

/// Callback trait that the Swift layer implements to receive asynchronous
/// events from the Rust core. Registered once via `rshell_set_event_callback`.
///
/// `FfiEventCallback` is `Send + Sync` so it can be invoked from any Tokio
/// task spawned by the bridge.
#[uniffi::export(callback_interface)]
pub trait FfiEventCallback: Send + Sync {
    fn on_event(&self, event: FfiEvent);
}

// ---------------------------------------------------------------------------
// Event bus wiring — forwards ssh-commander-core events to the registered Swift
// callback. Runs inside the bridge's Tokio runtime, so the callback must be
// Send + Sync.
// ---------------------------------------------------------------------------

/// Spawn a background Tokio task on the bridge runtime that drains the
/// core event bus and forwards every event to the registered callback.
/// The task lives until the bridge runtime is dropped (process exit).
fn start_event_listener(callback: Box<dyn FfiEventCallback>) {
    let bridge = MacOsBridge::global();
    let mut rx = ssh_commander_core::event_bus::subscribe();
    bridge.runtime.spawn(async move {
        use tokio::sync::broadcast::error::RecvError;
        loop {
            match rx.recv().await {
                Ok(core_event) => {
                    use ssh_commander_core::event_bus::{ConnectionStatus, CoreEvent};
                    let (ty, connection_id, payload) = match core_event {
                        CoreEvent::PtyOutput {
                            connection_id,
                            generation,
                            data,
                        } => (
                            "pty_output".into(),
                            connection_id,
                            // `{"generation": N, "bytes": [...]}` so the
                            // consumer can drop stale frames whose
                            // generation no longer matches the active
                            // session. Bare-array payloads are gone.
                            serde_json::json!({
                                "generation": generation,
                                "bytes": data,
                            })
                            .to_string(),
                        ),
                        CoreEvent::ConnectionStatus {
                            connection_id,
                            status,
                        } => {
                            let status_str = match status {
                                ConnectionStatus::Connected => "connected",
                                ConnectionStatus::Disconnected => "disconnected",
                                ConnectionStatus::Error { .. } => "error",
                            };
                            (
                                "connection_status".into(),
                                connection_id,
                                format!("{{\"status\":\"{}\"}}", status_str),
                            )
                        }
                        CoreEvent::TransferProgress {
                            connection_id,
                            path,
                            bytes_transferred,
                            total_bytes,
                        } => (
                            "transfer_progress".into(),
                            connection_id,
                            serde_json::json!({
                                "path": path,
                                "bytesTransferred": bytes_transferred,
                                "totalBytes": total_bytes,
                            })
                            .to_string(),
                        ),
                        CoreEvent::TcpdumpLine {
                            capture_id,
                            line,
                            is_stderr,
                        } => (
                            "tcpdump_line".into(),
                            // Tcpdump captures aren't bound to a per-
                            // connection routing key on the Swift side;
                            // they're keyed by `capture_id` inside the
                            // payload. Use a stable sentinel for the
                            // connection_id field so the listener can
                            // dispatch based on `ty` alone.
                            "tcpdump".into(),
                            serde_json::json!({
                                "captureId": capture_id,
                                "line": line,
                                "isStderr": is_stderr,
                            })
                            .to_string(),
                        ),
                    };
                    let ffi_event = FfiEvent {
                        ty,
                        connection_id,
                        payload,
                    };
                    callback.on_event(ffi_event);
                }
                Err(RecvError::Lagged(n)) => {
                    tracing::warn!("macOS bridge event bus lagged by {} events", n);
                }
                Err(RecvError::Closed) => {
                    tracing::info!("macOS bridge event bus closed, listener exiting");
                    break;
                }
            }
        }
    });
}

// ---------------------------------------------------------------------------
// FFI-exported functions — the native bridge contract.
// ---------------------------------------------------------------------------

/// Initialise the macOS bridge. Must be called once before any other
/// `rshell_*` function. Creates the Tokio runtime and connection manager.
/// Safe to call multiple times — subsequent calls are no-ops.
#[uniffi::export]
pub fn rshell_init() -> bool {
    MacOsBridge::init();
    true
}

/// Register an event callback. The callback receives `FfiEvent` messages
/// for PTY output, connection status changes, and transfer progress.
/// The callback is moved into a background Tokio task and forwarded to
/// the Swift layer. Must be called at least once before any event-producing
/// operations (PTY start, file transfer, etc.).
#[uniffi::export]
pub fn rshell_set_event_callback(callback: Box<dyn FfiEventCallback>) {
    start_event_listener(callback);
}

/// Typed connect-time failures so the Swift side can pattern-match instead
/// of substring-checking the error string. Variants are classified from
/// the underlying `anyhow::Error` produced by `ssh-commander-core` based on
/// well-known message phrases — uniffi 0.28 doesn't propagate Rust types
/// through `anyhow`, so this is the natural place for the classification.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ConnectError {
    /// Either no auth method was provided, or the request was missing a
    /// required field. The user can't recover by retrying — they need to
    /// fix the profile.
    #[error("invalid configuration: {detail}")]
    ConfigInvalid { detail: String },

    /// SSH key is encrypted and either no passphrase was supplied or the
    /// supplied one was wrong. The Swift side typically prompts and
    /// retries.
    #[error("SSH key needs a passphrase: {detail}")]
    PassphraseRequired { detail: String },

    /// Server rejected the credential — wrong password, key not in
    /// `authorized_keys`, etc. Distinct from `PassphraseRequired` because
    /// the recovery flow differs (re-prompt password vs unlock key).
    #[error("authentication failed: {detail}")]
    AuthFailed { detail: String },

    /// The stored host fingerprint doesn't match the offered one. Caller
    /// must surface the mismatch so the user can decide whether to
    /// re-trust the host (and removes the old TOFU entry).
    #[error("host key verification failed: {detail}")]
    HostKeyMismatch { detail: String },

    /// TCP-level failure: timeout, refused, reset, allow-list block.
    #[error("network error: {detail}")]
    Network { detail: String },

    /// Anything else — unknown error string from ssh-commander-core. Swift falls
    /// through to a generic alert.
    #[error("{detail}")]
    Other { detail: String },
}

/// Classify an `anyhow::Error` from ssh-commander-core into a typed `ConnectError`.
/// The match order matters: passphrase / encrypted-key failures must be
/// caught before the generic "authentication failed" check, since a wrong
/// key passphrase is user-correctable (re-prompt) whereas a remote auth
/// rejection means the credential itself is wrong.
fn classify_connect_error(e: &anyhow::Error) -> ConnectError {
    let msg = e.to_string();
    let lower = msg.to_lowercase();

    if lower.contains("passphrase") || lower.contains("encrypted") {
        ConnectError::PassphraseRequired { detail: msg }
    } else if lower.contains("authentication failed") {
        ConnectError::AuthFailed { detail: msg }
    } else if lower.contains("host key")
        || lower.contains("fingerprint")
        || lower.contains("verification failed")
    {
        ConnectError::HostKeyMismatch { detail: msg }
    } else if lower.contains("timed out")
        || lower.contains("reset")
        || lower.contains("refused")
        || lower.contains("connection")
    {
        ConnectError::Network { detail: msg }
    } else {
        ConnectError::Other { detail: msg }
    }
}

/// Strip redundant segments from `anyhow` error chains. When an
/// outer context and inner cause produce identical text (common
/// with SFTP "Permission denied" → "Permission denied" chains),
/// return a single clean message. Otherwise collapse adjacent
/// duplicate segments joined by `": "`.
fn sanitize_error(e: anyhow::Error) -> String {
    let full = e.to_string();
    let root = e.root_cause().to_string();
    if full == format!("{}: {}", root, root) {
        return root;
    }
    // Collapse adjacent identical segments.
    let parts: Vec<&str> = full.split(": ").collect();
    let mut deduped: Vec<&str> = Vec::new();
    for part in parts {
        if deduped.last() == Some(&part) {
            continue;
        }
        deduped.push(part);
    }
    deduped.join(": ")
}

fn command_failure_detail(
    output: &ssh_commander_core::ssh::CommandOutput,
    fallback: &str,
) -> String {
    let detail = output.combined().trim().to_string();
    if detail.is_empty() {
        fallback.to_string()
    } else {
        detail
    }
}

fn validate_numeric_remote_id(kind: &str, value: &str) -> Result<String, SftpError> {
    let trimmed = value.trim();
    if trimmed.is_empty() || !trimmed.chars().all(|c| c.is_ascii_digit()) {
        return Err(SftpError::Other {
            detail: format!("{kind} must be a numeric id"),
        });
    }
    Ok(trimmed.to_string())
}

fn validate_octal_mode(mode: &str) -> Result<String, SftpError> {
    let trimmed = mode.trim();
    if !(trimmed.len() == 3 || trimmed.len() == 4)
        || !trimmed.chars().all(|c| matches!(c, '0'..='7'))
    {
        return Err(SftpError::Other {
            detail: "mode must be a 3- or 4-digit octal value".into(),
        });
    }
    Ok(trimmed.to_string())
}

/// Establish an SSH connection. Returns the canonical connection id
/// (`"user@host:port"` or `"user@host:port#sessionId"`) on success;
/// throws a typed `ConnectError` on failure.
#[uniffi::export]
pub fn rshell_connect(config: FfiConnectConfig) -> Result<String, ConnectError> {
    let bridge = MacOsBridge::global();
    let mut connection_id = format!("{}@{}:{}", config.username, config.host, config.port);
    if let Some(sid) = config.session_id.as_ref()
        && !sid.is_empty()
    {
        connection_id.push('#');
        connection_id.push_str(sid);
    }

    let auth_method = if config.use_agent {
        ssh_commander_core::ssh::AuthMethod::Agent {
            identity_hint: config.agent_identity_hint,
        }
    } else {
        match (config.password, config.key_path) {
            (Some(password), _) => ssh_commander_core::ssh::AuthMethod::Password { password },
            (None, Some(key_path)) => ssh_commander_core::ssh::AuthMethod::PublicKey {
                key_path,
                passphrase: config.passphrase,
            },
            (None, None) => {
                return Err(ConnectError::ConfigInvalid {
                    detail: "Either password, key_path, or SSH agent authentication is required"
                        .into(),
                });
            }
        }
    };

    let ssh_config = ssh_commander_core::ssh::SshConfig {
        host: config.host,
        port: config.port,
        username: config.username,
        auth_method,
    };

    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();

    bridge
        .runtime
        .block_on(async move { cm.create_connection(conn_id, ssh_config).await })
        .map(|_| {
            // Surface the new state so the UI can light up the
            // connected indicator. Status events are best-effort —
            // a future network blip won't be detected unless the SSH
            // layer surfaces it (TODO sprint 10).
            if let Some(tx) = ssh_commander_core::event_bus::event_sender() {
                let _ = tx.send(ssh_commander_core::event_bus::CoreEvent::ConnectionStatus {
                    connection_id: connection_id.clone(),
                    status: ssh_commander_core::event_bus::ConnectionStatus::Connected,
                });
            }
            connection_id
        })
        .map_err(|e| classify_connect_error(&e))
}

/// Query whether a connection exists.
#[uniffi::export]
pub fn rshell_is_connected(connection_id: String) -> bool {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move { cm.get_connection(&connection_id).await.is_some() })
}

/// Disconnect an SSH connection and tear down any associated PTY session.
#[uniffi::export]
pub fn rshell_disconnect(connection_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id_for_close = connection_id.clone();
    let result = bridge.runtime.block_on(async move {
        crate::port_forward::registry()
            .stop_for_connection(&conn_id_for_close)
            .await;
        cm.close_connection(&conn_id_for_close).await
    });

    // Always publish disconnected — close_connection is idempotent on the
    // ssh-commander-core side, so even an error path here means the session is
    // effectively gone. UI status reflects observable state.
    if let Some(tx) = ssh_commander_core::event_bus::event_sender() {
        let _ = tx.send(ssh_commander_core::event_bus::CoreEvent::ConnectionStatus {
            connection_id: connection_id.clone(),
            status: ssh_commander_core::event_bus::ConnectionStatus::Disconnected,
        });
    }
    // Drop the cached OS detection so a future reconnect to the same
    // host re-runs `uname -s`. Cheap and bounded — wrong cached state
    // would cause the parser to apply Linux logic to a Darwin host
    // (or vice versa) for the lifetime of the next session.
    crate::monitor::evict(&connection_id);

    result
        .map(|_| FfiResult {
            success: true,
            error: None,
            value: None,
        })
        .unwrap_or_else(|e| FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        })
}

/// Start an interactive PTY session on an already-connected SSH connection.
/// Returns the generation counter in `value` (as a JSON string) so the
/// frontend can pass it back in `rshell_pty_close` to prevent stale closes.
///
/// Spawns a background task that drains the PTY's `output_rx` channel and
/// publishes each chunk as a `CoreEvent::PtyOutput` on the event bus, so the
/// Swift event callback receives terminal output. The macOS app is the only
/// consumer of `output_rx` (Tauri uses `read_pty_burst` in its own process),
/// so there is no contention.
#[uniffi::export]
pub fn rshell_pty_start(connection_id: String, cols: u32, rows: u32) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id_for_start = connection_id.clone();

    let result = bridge.runtime.block_on(async move {
        cm.start_pty_connection(&conn_id_for_start, cols, rows)
            .await
    });

    match result {
        Ok(generation) => {
            spawn_pty_output_forwarder(connection_id.clone(), generation, bridge);
            FfiResult {
                success: true,
                error: None,
                value: Some(serde_json::json!({"generation": generation}).to_string()),
            }
        }
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

/// Drain the active PTY's `output_rx` and publish each chunk on the event
/// bus, tagged with `generation`. Captures the `Arc<PtySession>` once so
/// a subsequent restart of the PTY for the same `connection_id` doesn't
/// redirect this loop to the new session's receiver — when the captured
/// session is cancelled or its channel closes, the loop exits.
///
/// Stamping every published event with `generation` lets the consumer
/// drop frames from an old PTY session that's tearing down: the new
/// session has a higher generation counter, the consumer remembers it,
/// and any straggler events from before the swap are recognisable as
/// stale.
fn spawn_pty_output_forwarder(connection_id: String, generation: u64, bridge: &MacOsBridge) {
    let cm = bridge.connection_manager.clone();
    bridge.runtime.spawn(async move {
        let pty = match cm.get_pty_session(&connection_id).await {
            Some(p) => p,
            None => {
                tracing::warn!("PTY forwarder: no session for {}", connection_id);
                return;
            }
        };
        let cancel = pty.cancel.clone();
        let output_rx = pty.output_rx.clone();
        // Drop our strong handle to PtySession; the captured `output_rx` Arc
        // keeps the receiver alive for as long as we need it.
        drop(pty);

        let tx = match ssh_commander_core::event_bus::event_sender() {
            Some(t) => t,
            None => {
                tracing::error!("PTY forwarder: event bus unavailable");
                return;
            }
        };

        loop {
            tokio::select! {
                biased;
                _ = cancel.cancelled() => {
                    tracing::debug!("PTY forwarder for {} cancelled", connection_id);
                    break;
                }
                msg = async {
                    let mut rx = output_rx.lock().await;
                    rx.recv().await
                } => {
                    match msg {
                        Some(data) if !data.is_empty() => {
                            // Send may fail if all subscribers dropped — that's
                            // fine, just keep draining so the channel doesn't
                            // back-pressure the SSH reader.
                            let _ = tx.send(ssh_commander_core::event_bus::CoreEvent::PtyOutput {
                                connection_id: connection_id.clone(),
                                generation,
                                data,
                            });
                        }
                        Some(_) => continue, // empty chunk, ignore
                        None => {
                            tracing::debug!("PTY forwarder for {} channel closed", connection_id);
                            break;
                        }
                    }
                }
            }
        }

        // The PTY for this connection is gone. This covers both clean
        // teardown (close_pty_connection cancels the token) and dirty
        // disconnects (network drop, server kill — `output_rx.recv()`
        // returns None when the SSH reader task exits). The Swift side
        // observes `connection_status: disconnected` and lights up the
        // reconnect affordance. Idempotent vs. the explicit publish in
        // rshell_disconnect — TerminalTabsStore.setStatus dedupes.
        let _ = tx.send(ssh_commander_core::event_bus::CoreEvent::ConnectionStatus {
            connection_id: connection_id.clone(),
            status: ssh_commander_core::event_bus::ConnectionStatus::Disconnected,
        });
    });
}

/// Write data (user input) to a running PTY session.
#[uniffi::export]
pub fn rshell_pty_write(connection_id: String, data: Vec<u8>) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move { cm.write_to_pty(&connection_id, data).await })
        .map(|_| FfiResult {
            success: true,
            error: None,
            value: None,
        })
        .unwrap_or_else(|e| FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        })
}

/// Resize a running PTY session's terminal dimensions.
#[uniffi::export]
pub fn rshell_pty_resize(connection_id: String, cols: u32, rows: u32) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move { cm.resize_pty(&connection_id, cols, rows).await })
        .map(|_| FfiResult {
            success: true,
            error: None,
            value: None,
        })
        .unwrap_or_else(|e| FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        })
}

/// Close a PTY session. The `expected_generation` is the generation counter
/// returned by `rshell_pty_start`; if it doesn't match the current session,
/// the close is ignored (prevents stale-close races from component remounts).
#[uniffi::export]
pub fn rshell_pty_close(connection_id: String, expected_generation: u64) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move {
            cm.close_pty_connection(&connection_id, Some(expected_generation))
                .await
        })
        .map(|_| FfiResult {
            success: true,
            error: None,
            value: None,
        })
        .unwrap_or_else(|e| FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        })
}

/// Execute a remote command on an SSH connection and return the output.
/// Blocks until the command completes or fails.
#[uniffi::export]
pub fn rshell_execute_command(connection_id: String, command: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();
    let result = bridge.runtime.block_on(async move {
        let client = cm.get_connection(&conn_id).await;
        match client {
            Some(c) => {
                let client = c.read().await;
                client.execute_command(&command).await
            }
            None => Err(anyhow::anyhow!("Connection not found: {}", conn_id)),
        }
    });
    match result {
        Ok(output) => FfiResult {
            success: true,
            error: None,
            value: Some(output),
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

// ---------------------------------------------------------------------------
// SFTP — list_dir for the file browser MVP. Upload / download / mkdir /
// delete / rename land in the next slice.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Copy)]
pub enum FfiFileKind {
    File,
    Directory,
    Symlink,
}

#[derive(uniffi::Record)]
pub struct FfiFileEntry {
    pub name: String,
    pub size: u64,
    /// Pre-formatted timestamp string from ssh-commander-core. `None` when
    /// the SFTP server doesn't supply mtime.
    pub modified: Option<String>,
    /// Raw modification time as Unix epoch seconds — surfaced so the
    /// macOS file table can sort numerically and reformat per-locale
    /// instead of relying on lexical comparison of the formatted
    /// `modified` string.
    pub modified_unix: Option<i64>,
    /// Pre-formatted POSIX permission string (e.g. `rwxr-xr-x`).
    pub permissions: Option<String>,
    /// Numeric owner uid (e.g. `"501"`). Resolved to a name on demand
    /// via `rshell_sftp_resolve_uid`.
    pub owner: Option<String>,
    /// Numeric group gid (e.g. `"20"`). Resolved to a name on demand
    /// via `rshell_sftp_resolve_gid`.
    pub group: Option<String>,
    pub kind: FfiFileKind,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SftpError {
    #[error("not connected: {connection_id}")]
    NotConnected { connection_id: String },
    /// User-initiated cancellation via `rshell_sftp_cancel`. Distinct
    /// from `Other` so the UI can mark the transfer cancelled rather
    /// than failed and skip the error toast.
    #[error("cancelled")]
    Cancelled,
    #[error("{detail}")]
    Other { detail: String },
}

/// Per-transfer cancellation registry. A transfer registers its token
/// keyed by the Swift-side UUID; `rshell_sftp_cancel` looks the entry
/// up and triggers it. The download/upload loop checks the token on
/// every chunk.
///
/// `OnceLock<Mutex<...>>` rather than RwLock because writes (register
/// / deregister / cancel) are short and infrequent — no readers to
/// optimise for.
static TRANSFER_CANCELS: std::sync::OnceLock<
    std::sync::Mutex<std::collections::HashMap<String, tokio_util::sync::CancellationToken>>,
> = std::sync::OnceLock::new();

fn transfer_registry()
-> &'static std::sync::Mutex<std::collections::HashMap<String, tokio_util::sync::CancellationToken>>
{
    TRANSFER_CANCELS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// Register a fresh `CancellationToken` for `transfer_id` and return
/// it. The matching `unregister_transfer` call removes the entry on
/// completion or failure so `rshell_sftp_cancel` can't leak past a
/// transfer's lifetime.
fn register_transfer(transfer_id: &str) -> tokio_util::sync::CancellationToken {
    let token = tokio_util::sync::CancellationToken::new();
    transfer_registry()
        .lock()
        .unwrap()
        .insert(transfer_id.to_string(), token.clone());
    token
}

fn unregister_transfer(transfer_id: &str) {
    transfer_registry().lock().unwrap().remove(transfer_id);
}

/// Cancel an in-flight transfer by its Swift-side UUID. Returns true
/// if a transfer was found and cancelled, false if the id wasn't
/// registered (already finished, never started, or unknown). The
/// running transfer's loop notices on its next chunk boundary and
/// returns `SftpError::Cancelled`.
#[uniffi::export]
pub fn rshell_sftp_cancel(transfer_id: String) -> bool {
    if let Some(token) = transfer_registry().lock().unwrap().get(&transfer_id) {
        token.cancel();
        true
    } else {
        false
    }
}

/// Stream a remote file to a local path. Returns the byte count on
/// success. Publishes `TransferProgress` events on every SFTP chunk so
/// the UI can drive a progress bar — the consumer (Swift
/// `TransferQueueStore`) matches events back to the in-flight transfer
/// by `path`. `expected_size` lets the consumer compute a percentage;
/// pass `0` if unknown.
///
/// `transfer_id` is the caller's stable handle (Swift uses the
/// per-transfer UUID). It's registered in a cancellation registry on
/// entry and removed on exit; `rshell_sftp_cancel(transfer_id)` walks
/// the registry to flip the token, and the chunk loop notices on the
/// next iteration.
#[uniffi::export]
pub fn rshell_sftp_download(
    transfer_id: String,
    connection_id: String,
    remote_path: String,
    local_path: String,
    expected_size: u64,
) -> Result<u64, SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();
    let remote_for_event = remote_path.clone();
    let token = register_transfer(&transfer_id);
    let transfer_id_for_cleanup = transfer_id.clone();

    let result = bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&conn_id)
            .await
            .ok_or_else(|| SftpError::NotConnected {
                connection_id: conn_id.clone(),
            })?;

        let event_tx = ssh_commander_core::event_bus::event_sender();
        let conn_id_for_progress = conn_id.clone();
        let remote_for_progress = remote_for_event.clone();

        let outcome = {
            let guard = client.read().await;
            guard
                .download_file_with_progress(
                    &remote_path,
                    &local_path,
                    |bytes| {
                        if let Some(tx) = event_tx.as_ref() {
                            let _ = tx.send(
                                ssh_commander_core::event_bus::CoreEvent::TransferProgress {
                                    connection_id: conn_id_for_progress.clone(),
                                    path: remote_for_progress.clone(),
                                    bytes_transferred: bytes,
                                    total_bytes: expected_size,
                                },
                            );
                        }
                    },
                    Some(&token),
                )
                .await
        };

        match outcome {
            Ok(bytes) => Ok(bytes),
            Err(_) if token.is_cancelled() => Err(SftpError::Cancelled),
            Err(e) => Err(SftpError::Other {
                detail: sanitize_error(e),
            }),
        }
    });

    unregister_transfer(&transfer_id_for_cleanup);
    result
}

/// Stream a local file to a remote path. See `rshell_sftp_download` for
/// the progress-event contract and the cancellation registry. The
/// local file is `stat`'d once before the transfer so progress events
/// carry a meaningful total.
#[uniffi::export]
pub fn rshell_sftp_upload(
    transfer_id: String,
    connection_id: String,
    local_path: String,
    remote_path: String,
) -> Result<u64, SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();
    let remote_for_event = remote_path.clone();

    let total_bytes = std::fs::metadata(&local_path).map(|m| m.len()).unwrap_or(0);
    let token = register_transfer(&transfer_id);
    let transfer_id_for_cleanup = transfer_id.clone();

    let result = bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&conn_id)
            .await
            .ok_or_else(|| SftpError::NotConnected {
                connection_id: conn_id.clone(),
            })?;

        let event_tx = ssh_commander_core::event_bus::event_sender();
        let conn_id_for_progress = conn_id.clone();
        let remote_for_progress = remote_for_event.clone();

        let outcome = {
            let guard = client.read().await;
            guard
                .upload_file_with_progress(
                    &local_path,
                    &remote_path,
                    |bytes| {
                        if let Some(tx) = event_tx.as_ref() {
                            let _ = tx.send(
                                ssh_commander_core::event_bus::CoreEvent::TransferProgress {
                                    connection_id: conn_id_for_progress.clone(),
                                    path: remote_for_progress.clone(),
                                    bytes_transferred: bytes,
                                    total_bytes,
                                },
                            );
                        }
                    },
                    Some(&token),
                )
                .await
        };

        match outcome {
            Ok(bytes) => Ok(bytes),
            Err(_) if token.is_cancelled() => Err(SftpError::Cancelled),
            Err(e) => Err(SftpError::Other {
                detail: sanitize_error(e),
            }),
        }
    });

    unregister_transfer(&transfer_id_for_cleanup);
    result
}

/// Create a directory on the remote. Fails if the parent doesn't
/// exist or the name is already taken.
#[uniffi::export]
pub fn rshell_sftp_create_dir(connection_id: String, path: String) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        guard.create_dir(&path).await.map_err(|e| SftpError::Other {
            detail: sanitize_error(e),
        })
    })
}

/// Rename or move a file or directory.
#[uniffi::export]
pub fn rshell_sftp_rename(
    connection_id: String,
    old_path: String,
    new_path: String,
) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        guard
            .rename(&old_path, &new_path)
            .await
            .map_err(|e| SftpError::Other {
                detail: sanitize_error(e),
            })
    })
}

/// Delete a regular file. For directories, use `rshell_sftp_delete_dir`.
#[uniffi::export]
pub fn rshell_sftp_delete_file(connection_id: String, path: String) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        guard
            .delete_file(&path)
            .await
            .map_err(|e| SftpError::Other {
                detail: sanitize_error(e),
            })
    })
}

/// Delete an empty directory. Recursive removal is the UI's
/// responsibility — list_dir + per-entry delete in a loop with progress.
#[uniffi::export]
pub fn rshell_sftp_delete_dir(connection_id: String, path: String) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        guard.delete_dir(&path).await.map_err(|e| SftpError::Other {
            detail: sanitize_error(e),
        })
    })
}

/// Change file permissions on the remote. `mode` is an octal string
/// e.g. `"755"`, `"644"`, `"700"`.
#[uniffi::export]
pub fn rshell_sftp_chmod(
    connection_id: String,
    path: String,
    mode: String,
) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let mode = validate_octal_mode(&mode)?;
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        let cmd = format!(
            "chmod {} {}",
            shell_escape::unix::escape(std::borrow::Cow::Borrowed(&mode)),
            shell_escape::unix::escape(std::borrow::Cow::Borrowed(&path))
        );
        let output = guard
            .execute_command_full(&cmd)
            .await
            .map_err(|e| SftpError::Other {
                detail: sanitize_error(e),
            })?;
        if output.exit_code == Some(0) {
            Ok(())
        } else {
            Err(SftpError::Other {
                detail: command_failure_detail(&output, "chmod failed"),
            })
        }
    })
}

/// Change file owner on the remote. `uid` is a numeric uid string
/// (e.g. `"501"`) or a username.
#[uniffi::export]
pub fn rshell_sftp_chown(
    connection_id: String,
    path: String,
    uid: String,
) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        let cmd = format!(
            "chown {} {}",
            shell_escape::unix::escape(std::borrow::Cow::Borrowed(&uid)),
            shell_escape::unix::escape(std::borrow::Cow::Borrowed(&path))
        );
        let output = guard
            .execute_command_full(&cmd)
            .await
            .map_err(|e| SftpError::Other {
                detail: sanitize_error(e),
            })?;
        if output.exit_code == Some(0) {
            Ok(())
        } else {
            Err(SftpError::Other {
                detail: command_failure_detail(&output, "chown failed"),
            })
        }
    })
}

/// Change file group on the remote. `gid` is a numeric gid string
/// (e.g. `"20"`) or a group name.
#[uniffi::export]
pub fn rshell_sftp_chgrp(
    connection_id: String,
    path: String,
    gid: String,
) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        let cmd = format!(
            "chgrp {} {}",
            shell_escape::unix::escape(std::borrow::Cow::Borrowed(&gid)),
            shell_escape::unix::escape(std::borrow::Cow::Borrowed(&path))
        );
        let output = guard
            .execute_command_full(&cmd)
            .await
            .map_err(|e| SftpError::Other {
                detail: sanitize_error(e),
            })?;
        if output.exit_code == Some(0) {
            Ok(())
        } else {
            Err(SftpError::Other {
                detail: command_failure_detail(&output, "chgrp failed"),
            })
        }
    })
}

/// Resolve a numeric uid to a username on the remote. Returns the
/// raw output of `id -nu <uid>` (the name) or an error.
#[uniffi::export]
pub fn rshell_sftp_resolve_uid(connection_id: String, uid: String) -> Result<String, SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        let uid = validate_numeric_remote_id("uid", &uid)?;
        let cmd = format!("id -nu {}", uid);
        let output = guard
            .execute_command_full(&cmd)
            .await
            .map_err(|e| SftpError::Other {
                detail: sanitize_error(e),
            })?;
        if output.is_success() {
            Ok(output.stdout.trim().to_string())
        } else {
            Err(SftpError::Other {
                detail: command_failure_detail(&output, "uid lookup failed"),
            })
        }
    })
}

/// Resolve a numeric gid to a group name on the remote. Returns the
/// raw output of `id -ng <gid>` (the name) or an error.
#[uniffi::export]
pub fn rshell_sftp_resolve_gid(connection_id: String, gid: String) -> Result<String, SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        let gid = validate_numeric_remote_id("gid", &gid)?;
        let cmd = format!("id -ng {}", gid);
        let output = guard
            .execute_command_full(&cmd)
            .await
            .map_err(|e| SftpError::Other {
                detail: sanitize_error(e),
            })?;
        if output.is_success() {
            Ok(output.stdout.trim().to_string())
        } else {
            Err(SftpError::Other {
                detail: command_failure_detail(&output, "gid lookup failed"),
            })
        }
    })
}

#[uniffi::export]
pub fn rshell_sftp_list_dir(
    connection_id: String,
    path: String,
) -> Result<Vec<FfiFileEntry>, SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();

    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&conn_id)
            .await
            .ok_or_else(|| SftpError::NotConnected {
                connection_id: conn_id.clone(),
            })?;

        let entries = {
            let guard = client.read().await;
            guard.list_dir(&path).await.map_err(|e| SftpError::Other {
                detail: sanitize_error(e),
            })?
        };

        Ok(entries
            .into_iter()
            .map(|e| FfiFileEntry {
                name: e.name,
                size: e.size,
                modified: e.modified,
                modified_unix: e.modified_unix,
                permissions: e.permissions,
                owner: e.owner,
                group: e.group,
                kind: match e.file_type {
                    ssh_commander_core::sftp_client::FileEntryType::File => FfiFileKind::File,
                    ssh_commander_core::sftp_client::FileEntryType::Directory => {
                        FfiFileKind::Directory
                    }
                    ssh_commander_core::sftp_client::FileEntryType::Symlink => FfiFileKind::Symlink,
                },
            })
            .collect())
    })
}

// ---------------------------------------------------------------------------
// System monitoring — multi-OS. The first call to a new connection runs
// `uname -s`, caches the result, and routes subsequent stats requests to
// the matching parser. Unknown OSes surface as `MonitorError::Unsupported`
// so the UI can render a friendly placeholder. Adding a new OS means
// extending `crate::monitor::OsKind` and writing a new parser module.
// ---------------------------------------------------------------------------

use crate::monitor::{self, OsKind};

/// One row in the disk-usage table.
#[derive(uniffi::Record, Clone)]
pub struct FfiDiskMount {
    /// Device or backing source (e.g. `/dev/disk1s1`, `tmpfs`).
    pub source: String,
    /// Mount point on the host.
    pub mount: String,
    /// Filesystem type. `"—"` when the source command (e.g. macOS
    /// default `df`) doesn't surface it.
    pub fs_type: String,
    pub total: u64,
    pub used: u64,
}

#[derive(uniffi::Record)]
pub struct FfiSystemStats {
    /// CPU utilisation 0..100 averaged across all cores during a
    /// brief sampling window inside the call.
    pub cpu_percent: f64,
    pub memory_total: u64,
    pub memory_used: u64,
    pub memory_available: u64,
    pub swap_total: u64,
    pub swap_used: u64,
    /// Every non-pseudo mount — typically `/`, `/home`, external
    /// volumes. Empty when `df` returned nothing parseable.
    pub disks: Vec<FfiDiskMount>,
    /// System uptime in seconds.
    pub uptime_seconds: u64,
    /// 1-minute load average.
    pub load_average_1m: f64,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum MonitorError {
    #[error("not connected: {connection_id}")]
    NotConnected { connection_id: String },
    /// Output didn't match the expected per-OS shape. Almost always
    /// transient (a command timed out, was truncated) — the UI may
    /// retry on the next poll.
    #[error("could not parse host stats: {detail}")]
    ParseError { detail: String },
    /// Host reported an OS we don't have parsers for yet (BSD,
    /// Solaris, AIX, …). The UI surfaces this as a placeholder so
    /// users know support is missing rather than broken.
    #[error("unsupported host OS: {os}")]
    Unsupported { os: String },
    #[error("{detail}")]
    Other { detail: String },
}

/// Snapshot host stats over the active SSH connection. Detects the OS
/// on the first call (cached), then routes to the matching parser.
#[uniffi::export]
pub fn rshell_get_system_stats(connection_id: String) -> Result<FfiSystemStats, MonitorError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();

    bridge.runtime.block_on(async move {
        let client =
            cm.get_connection(&connection_id)
                .await
                .ok_or_else(|| MonitorError::NotConnected {
                    connection_id: connection_id.clone(),
                })?;

        let os = match monitor::cached(&connection_id) {
            Some(os) => os,
            None => {
                let uname = {
                    let guard = client.read().await;
                    guard
                        .execute_command("uname -s")
                        .await
                        .map_err(|e| MonitorError::Other {
                            detail: sanitize_error(e),
                        })?
                };
                let detected = monitor::classify_uname(&uname);
                monitor::store(&connection_id, detected.clone());
                detected
            }
        };

        match os {
            OsKind::Linux => {
                let output = {
                    let guard = client.read().await;
                    guard
                        .execute_command(monitor::linux::STATS_COMMAND)
                        .await
                        .map_err(|e| MonitorError::Other {
                            detail: sanitize_error(e),
                        })?
                };
                parse_linux_stats(&output).map_err(|e| MonitorError::ParseError { detail: e })
            }
            OsKind::Darwin => {
                let output = {
                    let guard = client.read().await;
                    guard
                        .execute_command(monitor::darwin::STATS_COMMAND)
                        .await
                        .map_err(|e| MonitorError::Other {
                            detail: sanitize_error(e),
                        })?
                };
                parse_darwin_stats(&output).map_err(|e| MonitorError::ParseError { detail: e })
            }
            OsKind::Other(name) => Err(MonitorError::Unsupported { os: name }),
        }
    })
}

/// Split a sentinel-separated stream into named sections. The slice
/// `keys` is one longer than `sentinels`: the buffer before the first
/// sentinel goes under `keys[0]`, the buffer between sentinels[i] and
/// sentinels[i+1] goes under `keys[i+1]`, and the tail under
/// `keys[keys.len()-1]`.
fn split_sections<'a>(
    output: &str,
    sentinels: &[&str],
    keys: &'a [&'a str],
) -> std::collections::HashMap<&'a str, String> {
    debug_assert_eq!(sentinels.len() + 1, keys.len());
    let mut result = std::collections::HashMap::<&str, String>::new();
    let mut current = 0usize;
    let mut buf = String::new();
    for line in output.lines() {
        if current < sentinels.len() && line == sentinels[current] {
            result.insert(keys[current], std::mem::take(&mut buf));
            current += 1;
        } else {
            buf.push_str(line);
            buf.push('\n');
        }
    }
    result.insert(keys[current], buf);
    result
}

fn disk_mount_to_ffi(d: monitor::DiskMount) -> FfiDiskMount {
    FfiDiskMount {
        source: d.source,
        mount: d.mount,
        fs_type: d.fs_type,
        total: d.total,
        used: d.used,
    }
}

fn parse_linux_stats(output: &str) -> Result<FfiSystemStats, String> {
    use monitor::linux;
    let sections = split_sections(
        output,
        &[
            "---SLEEP---",
            "---MEM---",
            "---DISKS---",
            "---UPTIME---",
            "---LOAD---",
        ],
        &["CPU1", "CPU2", "MEM", "DISKS", "UPTIME", "LOAD"],
    );

    let cpu_percent = linux::parse_cpu_diff(
        sections.get("CPU1").ok_or("missing cpu1")?,
        sections.get("CPU2").ok_or("missing cpu2")?,
    )?;
    let mem = linux::parse_meminfo(sections.get("MEM").ok_or("missing memory")?)?;
    let disks = linux::parse_df_rows(sections.get("DISKS").ok_or("missing disks")?);
    let uptime = linux::parse_uptime(sections.get("UPTIME").ok_or("missing uptime")?)?;
    let load = linux::parse_loadavg(sections.get("LOAD").ok_or("missing load")?)?;

    Ok(FfiSystemStats {
        cpu_percent,
        memory_total: mem.total,
        memory_used: mem.used,
        memory_available: mem.available,
        swap_total: mem.swap_total,
        swap_used: mem.swap_used,
        disks: disks.into_iter().map(disk_mount_to_ffi).collect(),
        uptime_seconds: uptime,
        load_average_1m: load,
    })
}

fn parse_darwin_stats(output: &str) -> Result<FfiSystemStats, String> {
    use monitor::darwin;
    let sections = split_sections(
        output,
        &[
            "---MEM---",
            "---DISKS---",
            "---PAGESIZE---",
            "---MEMSIZE---",
            "---SWAP---",
            "---BOOTTIME---",
            "---LOAD---",
        ],
        &[
            "CPU", "MEM", "DISKS", "PAGESIZE", "MEMSIZE", "SWAP", "BOOTTIME", "LOAD",
        ],
    );

    let cpu_percent = darwin::parse_cpu_top(sections.get("CPU").ok_or("missing cpu")?)?;
    let pagesize = darwin::parse_u64(sections.get("PAGESIZE").ok_or("missing pagesize")?)?;
    let memsize = darwin::parse_u64(sections.get("MEMSIZE").ok_or("missing memsize")?)?;
    let (_free, active, wired) =
        darwin::parse_vm_stat(sections.get("MEM").ok_or("missing memory")?, pagesize)?;
    let memory_used = active + wired;
    let memory_available = memsize.saturating_sub(memory_used);
    let (swap_total, swap_used) =
        darwin::parse_swapusage(sections.get("SWAP").ok_or("missing swap")?);
    let uptime = darwin::parse_boottime(sections.get("BOOTTIME").ok_or("missing boottime")?)?;
    let load = darwin::parse_loadavg(sections.get("LOAD").ok_or("missing load")?)?;
    let disks = darwin::parse_df_rows(sections.get("DISKS").ok_or("missing disks")?);

    Ok(FfiSystemStats {
        cpu_percent,
        memory_total: memsize,
        memory_used,
        memory_available,
        swap_total,
        swap_used,
        disks: disks.into_iter().map(disk_mount_to_ffi).collect(),
        uptime_seconds: uptime,
        load_average_1m: load,
    })
}

// ---------------------------------------------------------------------------
// Process list + signalling — same OS routing as the system-stats path.
// ---------------------------------------------------------------------------

#[derive(uniffi::Record, Clone)]
pub struct FfiProcess {
    pub pid: u32,
    pub user: String,
    pub cpu_percent: f64,
    pub memory_percent: f64,
    /// Executable basename (matches `ps comm`).
    pub command: String,
    /// Full command line (matches `ps args`). Empty when the OS
    /// didn't report any.
    pub args: String,
}

/// POSIX signal number. Limited to the two cases the UI actually
/// surfaces today; widening this means the signal-routing match in
/// `rshell_signal_process` can stay exhaustive (no wildcard arm)
/// instead of accepting arbitrary integers from Swift.
#[derive(uniffi::Enum, Clone, Copy)]
pub enum FfiSignal {
    /// SIGTERM — request graceful shutdown.
    Term,
    /// SIGKILL — non-catchable, non-ignorable termination.
    Kill,
}

impl FfiSignal {
    fn as_kill_arg(self) -> &'static str {
        match self {
            FfiSignal::Term => "TERM",
            FfiSignal::Kill => "KILL",
        }
    }
}

/// List running processes on the connected host. Same OS-detect
/// path as `rshell_get_system_stats` — first call runs `uname -s`,
/// later calls reuse the cached value.
#[uniffi::export]
pub fn rshell_get_processes(connection_id: String) -> Result<Vec<FfiProcess>, MonitorError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();

    bridge.runtime.block_on(async move {
        let client =
            cm.get_connection(&connection_id)
                .await
                .ok_or_else(|| MonitorError::NotConnected {
                    connection_id: connection_id.clone(),
                })?;

        let os = match monitor::cached(&connection_id) {
            Some(os) => os,
            None => {
                let uname = {
                    let guard = client.read().await;
                    guard
                        .execute_command("uname -s")
                        .await
                        .map_err(|e| MonitorError::Other {
                            detail: sanitize_error(e),
                        })?
                };
                let detected = monitor::classify_uname(&uname);
                monitor::store(&connection_id, detected.clone());
                detected
            }
        };

        let cmd = match os {
            OsKind::Linux => monitor::linux::PROCESSES_COMMAND,
            OsKind::Darwin => monitor::darwin::PROCESSES_COMMAND,
            OsKind::Other(name) => return Err(MonitorError::Unsupported { os: name }),
        };

        let output = {
            let guard = client.read().await;
            guard
                .execute_command(cmd)
                .await
                .map_err(|e| MonitorError::Other {
                    detail: sanitize_error(e),
                })?
        };

        let rows = match os {
            OsKind::Linux => monitor::linux::parse_processes(&output),
            OsKind::Darwin => monitor::darwin::parse_processes(&output),
            OsKind::Other(_) => unreachable!(),
        };

        Ok(rows
            .into_iter()
            .map(|p| FfiProcess {
                pid: p.pid,
                user: p.user,
                cpu_percent: p.cpu_percent,
                memory_percent: p.memory_percent,
                command: p.command,
                args: p.args,
            })
            .collect())
    })
}

/// Send a signal to a remote process. Runs `kill -SIGNAME PID` on
/// the host. Privilege errors (`Operation not permitted`) propagate
/// through `MonitorError::Other` with the remote's stderr line.
#[uniffi::export]
pub fn rshell_signal_process(
    connection_id: String,
    pid: u32,
    signal: FfiSignal,
) -> Result<(), MonitorError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();

    bridge.runtime.block_on(async move {
        let client =
            cm.get_connection(&connection_id)
                .await
                .ok_or_else(|| MonitorError::NotConnected {
                    connection_id: connection_id.clone(),
                })?;

        // `kill` accepts the signal as both number and name. Names
        // are portable across BSD/Linux and read better in logs.
        let cmd = format!("kill -{} {}", signal.as_kill_arg(), pid);
        let guard = client.read().await;
        let output = guard
            .execute_command_full(&cmd)
            .await
            .map_err(|e| MonitorError::Other {
                detail: sanitize_error(e),
            })?;
        if output.is_success() {
            Ok(())
        } else {
            Err(MonitorError::Other {
                detail: command_failure_detail(&output, "kill failed"),
            })
        }
    })
}

#[cfg(test)]
mod system_stats_tests {
    use super::*;

    #[test]
    fn parses_linux_stats_end_to_end() {
        let output = "\
cpu  100 0 50 850 0 0 0 0 0 0
---SLEEP---
cpu  150 0 75 875 0 0 0 0 0 0
---MEM---
MemTotal:       16000000 kB
MemFree:         2000000 kB
MemAvailable:    8000000 kB
SwapTotal:       4000000 kB
SwapFree:        3000000 kB
---DISKS---
/dev/sda1 ext4 100000000000 60000000000 40000000000 60% /
tmpfs tmpfs 4096 0 4096 0% /run
---UPTIME---
12345.67 7891.23
---LOAD---
0.50 0.40 0.30 1/234 5678
";
        let stats = parse_linux_stats(output).unwrap();
        assert!((stats.cpu_percent - 75.0).abs() < 0.01);
        assert_eq!(stats.memory_total, 16_000_000 * 1024);
        assert_eq!(stats.swap_used, 1_000_000 * 1024);
        // tmpfs row dropped, real disk kept.
        assert_eq!(stats.disks.len(), 1);
        assert_eq!(stats.disks[0].mount, "/");
        assert_eq!(stats.uptime_seconds, 12345);
        assert!((stats.load_average_1m - 0.50).abs() < 0.001);
    }

    #[test]
    fn parses_darwin_stats_end_to_end() {
        // Build a synthetic boottime so uptime ≈ 200s.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let boottime_line = format!("{{ sec = {}, usec = 0 }} Sat Apr 29", now - 200);
        let output = format!(
            "\
CPU usage: 12.34% user, 5.66% sys, 82.0% idle
---MEM---
Pages free:                          100000.
Pages active:                        200000.
Pages wired down:                    150000.
---DISKS---
/dev/disk1s1 100000000 50000000 50000000 50% /
/dev/disk1s2 100000000 1000000 99000000 1% /System/Volumes/Preboot
---PAGESIZE---
16384
---MEMSIZE---
17179869184
---SWAP---
total = 4096.00M  used = 123.45M  free = 3972.55M
---BOOTTIME---
{boottime_line}
---LOAD---
{{ 1.23 0.98 0.76 }}
"
        );
        let stats = parse_darwin_stats(&output).unwrap();
        assert!((stats.cpu_percent - 18.0).abs() < 0.5);
        assert_eq!(stats.memory_total, 17_179_869_184);
        // used = (active + wired) * pagesize = 350000 * 16384
        assert_eq!(stats.memory_used, 350_000 * 16_384);
        assert_eq!(stats.swap_total, (4096.00 * 1024.0 * 1024.0) as u64);
        assert_eq!(stats.disks.len(), 1);
        assert_eq!(stats.disks[0].mount, "/");
        assert!((200..=210).contains(&stats.uptime_seconds));
        assert!((stats.load_average_1m - 1.23).abs() < 0.01);
    }
}

/// Forget a stored host-key entry. Called from the Swift "Trust new key"
/// flow after a `HostKeyMismatch` so the next connect TOFU-trusts the
/// new fingerprint. Returns `success: true, value: "true"` if an entry
/// was removed, `success: true, value: "false"` if there was nothing
/// to remove, or `success: false, error: ...` on disk I/O failure.
#[uniffi::export]
pub fn rshell_forget_host_key(host: String, port: u16) -> FfiResult {
    let bridge = MacOsBridge::global();
    let store = bridge.connection_manager.host_keys();
    match bridge
        .runtime
        .block_on(async move { store.forget(&host, port).await })
    {
        Ok(removed) => FfiResult {
            success: true,
            error: None,
            value: Some(removed.to_string()),
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

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
#[derive(uniffi::Enum, Debug)]
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

#[derive(uniffi::Record, Debug)]
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
            ssh_tunnel: c.tunnel.map(|t| ssh_commander_core::SshTunnelRef {
                ssh_connection_id: t.ssh_connection_id,
                remote_host: t.remote_host,
                remote_port: t.remote_port,
            }),
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
    let core_cfg: ssh_commander_core::PgConfig = config.into();
    let connection_id = pg_connection_id(&core_cfg, profile_id.as_deref());
    let conn_id = connection_id.clone();
    let cm = bridge.connection_manager.clone();

    bridge
        .runtime
        .block_on(async move { cm.create_postgres_connection(conn_id, core_cfg).await })
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

// ---------------------------------------------------------------------------
// Grid DML — UPDATE / INSERT / DELETE built as SQL text.
//
// ssh-commander-core 0.1.0's editor API (`update_cell` / `insert_row` /
// `delete_rows`) binds every parameter as `String` while writing
// `$N::<type>` placeholders. Postgres infers the parameter to BE that
// type, so tokio-postgres fails to serialize the text for any non-text
// target — including the `tid` ctid every statement keys on, which
// breaks all three calls unconditionally ("error serializing parameter").
// Until a fixed core ships, these functions render the statement as SQL
// text (quoted identifiers, safely-quoted literals, explicit casts) and
// run it through the same `pool.execute` path query tabs use.
// ---------------------------------------------------------------------------

/// Magic alias the generated browse SELECT gives `ctid`; mirrored by
/// `POSTGRES_ROWID_COLUMN` on the Swift side.
const PG_ROWID_COLUMN: &str = "__pg_rowid__";

/// Quote an identifier for direct embedding in SQL text.
fn pg_quote_ident(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "\"\""))
}

/// Quote a text value as a SQL string literal. Values containing a
/// backslash are emitted as an `E''` string with backslashes doubled,
/// which is correct regardless of the server's
/// `standard_conforming_strings` setting; plain values use `''`
/// doubling only.
fn pg_quote_literal(s: &str) -> String {
    if s.contains('\\') {
        format!("E'{}'", s.replace('\\', "\\\\").replace('\'', "''"))
    } else {
        format!("'{}'", s.replace('\'', "''"))
    }
}

/// Render an optional cell value as a SQL expression: `NULL`, a cast
/// literal when the column type is known, or a bare (untyped) literal
/// otherwise — Postgres coerces an unknown literal to the target
/// column's type on its own.
fn pg_value_expr(value: Option<&str>, type_name: &str) -> String {
    match value {
        None => "NULL".to_string(),
        Some(v) if type_name.is_empty() => pg_quote_literal(v),
        Some(v) => format!(
            "CAST({} AS {})",
            pg_quote_literal(v),
            pg_quote_ident(type_name)
        ),
    }
}

fn build_update_cell_sql(
    schema: &str,
    table: &str,
    column: &str,
    column_type: &str,
    new_value: Option<&str>,
    row_id: &str,
) -> String {
    format!(
        "UPDATE {}.{} SET {} = {} WHERE ctid = {}::tid",
        pg_quote_ident(schema),
        pg_quote_ident(table),
        pg_quote_ident(column),
        pg_value_expr(new_value, column_type),
        pg_quote_literal(row_id),
    )
}

/// One RETURNING entry: the magic rowid alias maps back to `ctid`
/// (as text, matching the browse SELECT's shape); everything else is
/// the quoted column itself.
fn pg_returning_expr(name: &str) -> String {
    if name == PG_ROWID_COLUMN {
        format!("ctid::text AS {}", pg_quote_ident(PG_ROWID_COLUMN))
    } else {
        pg_quote_ident(name)
    }
}

fn build_insert_row_sql(
    schema: &str,
    table: &str,
    inputs: &[FfiPgInsertColumn],
    return_columns: &[String],
) -> String {
    let target = format!("{}.{}", pg_quote_ident(schema), pg_quote_ident(table));
    let body = if inputs.is_empty() {
        format!("INSERT INTO {target} DEFAULT VALUES")
    } else {
        let columns: Vec<String> = inputs.iter().map(|c| pg_quote_ident(&c.name)).collect();
        let values: Vec<String> = inputs
            .iter()
            .map(|c| pg_value_expr(c.value.as_deref(), &c.type_name))
            .collect();
        format!(
            "INSERT INTO {target} ({}) VALUES ({})",
            columns.join(", "),
            values.join(", ")
        )
    };
    if return_columns.is_empty() {
        body
    } else {
        let returning: Vec<String> = return_columns
            .iter()
            .map(|c| pg_returning_expr(c))
            .collect();
        // The trailing `; --` suffix is load-bearing: core 0.1.0's
        // execute path cursor-wraps any statement whose prepared form
        // has result columns, and `DECLARE … CURSOR FOR INSERT` is a
        // syntax error. A semicolon followed by only a comment makes
        // core's `is_multi_statement` true while its statement
        // splitter bails (comment-only main), routing the whole
        // statement through the simple_query bulk path — which
        // executes INSERT … RETURNING correctly and surfaces its
        // rows. Pinned by the grid-DML integration test.
        format!(
            "{body} RETURNING {}; -- simple_query route",
            returning.join(", ")
        )
    }
}

/// `None` when `row_ids` is empty — there is nothing to delete and
/// `WHERE ctid IN ()` would be a syntax error.
fn build_delete_rows_sql(schema: &str, table: &str, row_ids: &[String]) -> Option<String> {
    if row_ids.is_empty() {
        return None;
    }
    let ids: Vec<String> = row_ids
        .iter()
        .map(|id| format!("{}::tid", pg_quote_literal(id)))
        .collect();
    Some(format!(
        "DELETE FROM {}.{} WHERE ctid IN ({})",
        pg_quote_ident(schema),
        pg_quote_ident(table),
        ids.join(", ")
    ))
}

/// Update a single cell. `new_value: None` means SET NULL; a non-null
/// value is rendered as a quoted literal with an explicit cast to
/// `column_type`. Identifiers are quoted here — callers don't need to
/// escape `schema` / `table` / `column`.
// Flat argument lists are idiomatic for the UniFFI surface; bundling these
// into a record would force a binding regen + every Swift call site to change
// for no real readability gain, so the lint is allowed here deliberately.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn rshell_pg_update_cell(
    connection_id: String,
    session_id: String,
    schema: String,
    table: String,
    column: String,
    column_type: String,
    new_value: Option<String>,
    row_id: String,
) -> Result<FfiPgUpdateResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    let sql = build_update_cell_sql(
        &schema,
        &table,
        &column,
        &column_type,
        new_value.as_deref(),
        &row_id,
    );
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.execute(&session_id, &sql, 1).await
        })
        .await
        .map(|outcome| FfiPgUpdateResult {
            rows_affected: outcome.rows_affected.unwrap_or(0),
        })
    })
}

/// Open a Parquet writer at `path` with the given column names.
/// All columns serialize as Utf8 (matches the explorer's text-only
/// model). Returns an opaque writer id; pass it to subsequent
/// `rshell_pg_parquet_append` calls and finally `rshell_pg_parquet_close`.
#[uniffi::export]
pub fn rshell_pg_parquet_open(path: String, columns: Vec<String>) -> Result<u64, FfiPgError> {
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .open(std::path::Path::new(&path), &columns)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet open failed: {e}"),
        })
}

/// Append a batch of rows to an open Parquet writer. `rows` is a
/// list of `FfiPgRow`; each row's `cells` must match the column
/// list passed to `rshell_pg_parquet_open` in length.
#[uniffi::export]
pub fn rshell_pg_parquet_append(writer_id: u64, rows: Vec<FfiPgRow>) -> Result<(), FfiPgError> {
    let row_vecs: Vec<Vec<Option<String>>> = rows.into_iter().map(|r| r.cells).collect();
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .append(writer_id, &row_vecs)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet append failed: {e}"),
        })
}

/// Close a Parquet writer. Flushes the metadata footer to disk;
/// the file isn't readable as Parquet until this returns. Idempotent
/// against the same id (subsequent calls return UnknownWriter; the
/// caller surfaces that as a no-op since the file is already valid).
#[uniffi::export]
pub fn rshell_pg_parquet_close(writer_id: u64) -> Result<(), FfiPgError> {
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .close(writer_id)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet close failed: {e}"),
        })
}

// ---------------------------------------------------------------------------
// Schema contents — DataGrip-style six-category groupings.
// ---------------------------------------------------------------------------

#[derive(uniffi::Record, Debug)]
pub struct FfiPgSequence {
    pub schema: String,
    pub name: String,
    pub owner: String,
}

#[derive(uniffi::Enum, Debug)]
pub enum FfiPgRoutineKind {
    Function,
    Procedure,
    Aggregate,
    Window,
}

impl From<ssh_commander_core::RoutineKind> for FfiPgRoutineKind {
    fn from(k: ssh_commander_core::RoutineKind) -> Self {
        match k {
            ssh_commander_core::RoutineKind::Function => Self::Function,
            ssh_commander_core::RoutineKind::Procedure => Self::Procedure,
            ssh_commander_core::RoutineKind::Aggregate => Self::Aggregate,
            ssh_commander_core::RoutineKind::Window => Self::Window,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgRoutine {
    pub schema: String,
    pub name: String,
    pub kind: FfiPgRoutineKind,
    pub owner: String,
    /// Pretty-printed `(integer, text)` argument list.
    pub argument_signature: String,
    /// `nil` for procedures.
    pub return_type: Option<String>,
}

#[derive(uniffi::Enum, Debug)]
pub enum FfiPgObjectTypeKind {
    Composite,
    Enum,
    Domain,
    Range,
}

impl From<ssh_commander_core::ObjectTypeKind> for FfiPgObjectTypeKind {
    fn from(k: ssh_commander_core::ObjectTypeKind) -> Self {
        match k {
            ssh_commander_core::ObjectTypeKind::Composite => Self::Composite,
            ssh_commander_core::ObjectTypeKind::Enum => Self::Enum,
            ssh_commander_core::ObjectTypeKind::Domain => Self::Domain,
            ssh_commander_core::ObjectTypeKind::Range => Self::Range,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgObjectType {
    pub schema: String,
    pub name: String,
    pub kind: FfiPgObjectTypeKind,
    pub owner: String,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgSchemaContents {
    pub tables: Vec<FfiPgRelation>,
    pub views: Vec<FfiPgRelation>,
    pub materialized_views: Vec<FfiPgRelation>,
    pub sequences: Vec<FfiPgSequence>,
    pub routines: Vec<FfiPgRoutine>,
    pub object_types: Vec<FfiPgObjectType>,
}

impl From<ssh_commander_core::SchemaContents> for FfiPgSchemaContents {
    fn from(c: ssh_commander_core::SchemaContents) -> Self {
        fn map_rel(r: ssh_commander_core::Relation) -> FfiPgRelation {
            FfiPgRelation {
                schema: r.schema,
                name: r.name,
                kind: r.kind.into(),
                owner: r.owner,
                estimated_rows: r.estimated_rows,
            }
        }
        Self {
            tables: c.tables.into_iter().map(map_rel).collect(),
            views: c.views.into_iter().map(map_rel).collect(),
            materialized_views: c.materialized_views.into_iter().map(map_rel).collect(),
            sequences: c
                .sequences
                .into_iter()
                .map(|s| FfiPgSequence {
                    schema: s.schema,
                    name: s.name,
                    owner: s.owner,
                })
                .collect(),
            routines: c
                .routines
                .into_iter()
                .map(|r| FfiPgRoutine {
                    schema: r.schema,
                    name: r.name,
                    kind: r.kind.into(),
                    owner: r.owner,
                    argument_signature: r.argument_signature,
                    return_type: r.return_type,
                })
                .collect(),
            object_types: c
                .object_types
                .into_iter()
                .map(|t| FfiPgObjectType {
                    schema: t.schema,
                    name: t.name,
                    kind: t.kind.into(),
                    owner: t.owner,
                })
                .collect(),
        }
    }
}

/// Unified expand-a-schema fetch. Replaces the older
/// `rshell_pg_list_relations`-only path with a six-category result.
/// `database == nil` queries the connection's default DB.
#[uniffi::export]
pub fn rshell_pg_list_schema_contents(
    connection_id: String,
    schema: String,
    database: Option<String>,
) -> Result<FfiPgSchemaContents, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.list_schema_contents_in(&schema, database.as_deref())
                .await
        })
        .await
        .map(FfiPgSchemaContents::from)
    })
}

/// Per-column metadata for the INSERT form. Read from
/// `pg_attribute` + `pg_attrdef`. UI uses this to pre-set
/// the form's per-column toggles + skip generated columns.
#[derive(uniffi::Record, Debug)]
pub struct FfiPgColumnDetail {
    pub name: String,
    pub type_name: String,
    pub not_null: bool,
    pub has_default: bool,
    pub is_generated: bool,
}

impl From<ssh_commander_core::ColumnDetail> for FfiPgColumnDetail {
    fn from(c: ssh_commander_core::ColumnDetail) -> Self {
        Self {
            name: c.name,
            type_name: c.type_name,
            not_null: c.not_null,
            has_default: c.has_default,
            is_generated: c.is_generated,
        }
    }
}

#[uniffi::export]
pub fn rshell_pg_describe_columns(
    connection_id: String,
    schema: String,
    table: String,
) -> Result<Vec<FfiPgColumnDetail>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.describe_columns(&schema, &table).await
        })
        .await
        .map(|cols| cols.into_iter().map(FfiPgColumnDetail::from).collect())
    })
}

/// One column's worth of input for an INSERT row. Caller emits a
/// list of these for the columns it sets explicitly; columns not in
/// the list are left to the server's `DEFAULT` (sequence values,
/// generated columns, attrdef defaults).
#[derive(uniffi::Record, Debug)]
pub struct FfiPgInsertColumn {
    pub name: String,
    pub type_name: String,
    /// `None` = SQL NULL. `Some(text)` = bound + cast server-side.
    pub value: Option<String>,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgInsertedRow {
    /// Cells in the order the caller specified via `return_columns`.
    /// Matches `FfiPgRow.cells` shape so the UI can append directly.
    pub cells: Vec<Option<String>>,
}

/// Insert one row, returning the requested columns of the new row.
/// `return_columns` should typically be the visible-column names
/// from the existing result (including the magic `__pg_rowid__`)
/// so the new row slots straight into the UI's in-memory grid.
#[uniffi::export]
pub fn rshell_pg_insert_row(
    connection_id: String,
    session_id: String,
    schema: String,
    table: String,
    inputs: Vec<FfiPgInsertColumn>,
    return_columns: Vec<String>,
) -> Result<FfiPgInsertedRow, FfiPgError> {
    let bridge = MacOsBridge::global();
    let sql = build_insert_row_sql(&schema, &table, &inputs, &return_columns);
    let expects_row = !return_columns.is_empty();
    bridge.runtime.block_on(async move {
        let outcome = with_pg_pool(&connection_id, |pool| async move {
            // Page size covers the single RETURNING row; anything more
            // means the statement wasn't the INSERT we built.
            pool.execute(&session_id, &sql, 2).await
        })
        .await?;
        match outcome.rows.into_iter().next() {
            Some(cells) => Ok(FfiPgInsertedRow { cells }),
            None if !expects_row => Ok(FfiPgInsertedRow { cells: Vec::new() }),
            None => Err(FfiPgError::Other {
                detail: "INSERT reported success but returned no row".into(),
            }),
        }
    })
}

/// Delete one or more rows by ctid. Returns the actual rows-deleted
/// count; the UI compares against the requested count and surfaces
/// "some rows already gone" when they don't match.
#[uniffi::export]
pub fn rshell_pg_delete_rows(
    connection_id: String,
    session_id: String,
    schema: String,
    table: String,
    row_ids: Vec<String>,
) -> Result<FfiPgUpdateResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    let Some(sql) = build_delete_rows_sql(&schema, &table, &row_ids) else {
        return Ok(FfiPgUpdateResult { rows_affected: 0 });
    };
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.execute(&session_id, &sql, 1).await
        })
        .await
        .map(|outcome| FfiPgUpdateResult {
            rows_affected: outcome.rows_affected.unwrap_or(0),
        })
    })
}

/// Cancel whatever query is in flight on the session's connection.
/// Other sessions are unaffected. The connection stays open for the
/// next query in this session.
#[uniffi::export]
pub fn rshell_pg_cancel(connection_id: String, session_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let result: Result<(), FfiPgError> = bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.cancel(&session_id).await
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

/// Release a session's lease on its pooled connection. Closes any
/// active cursor first, then returns the connection to idle so other
/// sessions can use it. Best-effort — never throws to the FFI caller.
#[uniffi::export]
pub fn rshell_pg_release_session(connection_id: String, session_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let result: Result<(), FfiPgError> = bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.release_session(&session_id).await;
            Ok(())
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

#[uniffi::export]
pub fn rshell_pg_list_relations(
    connection_id: String,
    schema: String,
    database: Option<String>,
) -> Result<Vec<FfiPgRelation>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.list_relations_in(&schema, database.as_deref()).await
        })
        .await
        .map(|relations| {
            relations
                .into_iter()
                .map(|r| FfiPgRelation {
                    schema: r.schema,
                    name: r.name,
                    kind: r.kind.into(),
                    owner: r.owner,
                    estimated_rows: r.estimated_rows,
                })
                .collect()
        })
    })
}

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

// ---------------------------------------------------------------------------
// Keychain FFI — wraps ssh-commander-core keychain for Swift access.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum)]
pub enum FfiCredentialKind {
    SshPassword,
    SshKeyPassphrase,
    SftpPassword,
    SftpKeyPassphrase,
    FtpPassword,
    PostgresPassword,
}

impl From<FfiCredentialKind> for ssh_commander_core::keychain::CredentialKind {
    fn from(k: FfiCredentialKind) -> Self {
        match k {
            FfiCredentialKind::SshPassword => Self::SshPassword,
            FfiCredentialKind::SshKeyPassphrase => Self::SshKeyPassphrase,
            FfiCredentialKind::SftpPassword => Self::SftpPassword,
            FfiCredentialKind::SftpKeyPassphrase => Self::SftpKeyPassphrase,
            FfiCredentialKind::FtpPassword => Self::FtpPassword,
            FfiCredentialKind::PostgresPassword => Self::PostgresPassword,
        }
    }
}

#[uniffi::export]
pub fn rshell_keychain_is_supported() -> bool {
    ssh_commander_core::keychain::is_supported()
}

#[uniffi::export]
pub fn rshell_keychain_save(kind: FfiCredentialKind, account: String, secret: String) -> FfiResult {
    let core_kind: ssh_commander_core::keychain::CredentialKind = kind.into();
    match ssh_commander_core::keychain::save_password(core_kind, &account, &secret) {
        Ok(_) => FfiResult {
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

#[uniffi::export]
pub fn rshell_keychain_load(kind: FfiCredentialKind, account: String) -> FfiResult {
    let core_kind: ssh_commander_core::keychain::CredentialKind = kind.into();
    match ssh_commander_core::keychain::load_password(core_kind, &account) {
        Ok(Some(secret)) => FfiResult {
            success: true,
            error: None,
            value: Some(secret),
        },
        Ok(None) => FfiResult {
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

#[uniffi::export]
pub fn rshell_keychain_delete(kind: FfiCredentialKind, account: String) -> FfiResult {
    let core_kind: ssh_commander_core::keychain::CredentialKind = kind.into();
    match ssh_commander_core::keychain::delete_password(core_kind, &account) {
        Ok(_) => FfiResult {
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

#[uniffi::export]
pub fn rshell_keychain_list(kind: FfiCredentialKind) -> Vec<String> {
    let core_kind: ssh_commander_core::keychain::CredentialKind = kind.into();
    ssh_commander_core::keychain::list_accounts(core_kind).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// SSH port forwarding — local `direct-tcpip` forwards and dynamic SOCKS are
// backed by the bridge-owned registry in `port_forward.rs`. Remote forwards are
// represented in the UI/persistence model, but return a typed unsupported
// error until ssh-commander-core exposes server-side `tcpip-forward`.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiPortForwardKind {
    Local,
    Remote,
    DynamicSocks,
}

impl From<FfiPortForwardKind> for crate::port_forward::PortForwardKind {
    fn from(kind: FfiPortForwardKind) -> Self {
        match kind {
            FfiPortForwardKind::Local => Self::Local,
            FfiPortForwardKind::Remote => Self::Remote,
            FfiPortForwardKind::DynamicSocks => Self::DynamicSocks,
        }
    }
}

impl From<crate::port_forward::PortForwardKind> for FfiPortForwardKind {
    fn from(kind: crate::port_forward::PortForwardKind) -> Self {
        match kind {
            crate::port_forward::PortForwardKind::Local => Self::Local,
            crate::port_forward::PortForwardKind::Remote => Self::Remote,
            crate::port_forward::PortForwardKind::DynamicSocks => Self::DynamicSocks,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiPortForwardConfig {
    pub id: String,
    pub profile_id: String,
    pub connection_id: String,
    pub name: String,
    pub kind: FfiPortForwardKind,
    pub bind_host: String,
    pub bind_port: u16,
    pub destination_host: Option<String>,
    pub destination_port: Option<u16>,
}

impl From<FfiPortForwardConfig> for crate::port_forward::PortForwardConfig {
    fn from(config: FfiPortForwardConfig) -> Self {
        Self {
            id: config.id,
            profile_id: config.profile_id,
            connection_id: config.connection_id,
            name: config.name,
            kind: config.kind.into(),
            bind_host: config.bind_host,
            bind_port: config.bind_port,
            destination_host: config.destination_host,
            destination_port: config.destination_port,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiPortForwardStatus {
    pub id: String,
    pub profile_id: String,
    pub connection_id: String,
    pub name: String,
    pub kind: FfiPortForwardKind,
    pub bind_host: String,
    pub bind_port: u16,
    pub bound_port: u16,
    pub destination_host: Option<String>,
    pub destination_port: Option<u16>,
    pub started_at_unix: u64,
    pub duration_secs: u64,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub connection_count: u64,
    pub last_error: Option<String>,
}

impl From<crate::port_forward::PortForwardStatus> for FfiPortForwardStatus {
    fn from(status: crate::port_forward::PortForwardStatus) -> Self {
        Self {
            id: status.id,
            profile_id: status.profile_id,
            connection_id: status.connection_id,
            name: status.name,
            kind: status.kind.into(),
            bind_host: status.bind_host,
            bind_port: status.bind_port,
            bound_port: status.bound_port,
            destination_host: status.destination_host,
            destination_port: status.destination_port,
            started_at_unix: status.started_at_unix,
            duration_secs: status.duration_secs,
            bytes_in: status.bytes_in,
            bytes_out: status.bytes_out,
            connection_count: status.connection_count,
            last_error: status.last_error,
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiPortForwardError {
    #[error("connection not found: {id}")]
    ConnectionNotFound { id: String },
    #[error("invalid forward configuration: {message}")]
    InvalidConfig { message: String },
    #[error("remote forwarding is not supported: {message}")]
    Unsupported { message: String },
    #[error("port forward not found: {id}")]
    NotFound { id: String },
    #[error("bind failed: {message}")]
    Bind { message: String },
}

impl From<crate::port_forward::PortForwardError> for FfiPortForwardError {
    fn from(error: crate::port_forward::PortForwardError) -> Self {
        use crate::port_forward::PortForwardError as E;
        match error {
            E::ConnectionNotFound(id) => Self::ConnectionNotFound { id },
            E::InvalidConfig(message) => Self::InvalidConfig { message },
            E::Unsupported(message) => Self::Unsupported { message },
            E::NotFound(id) => Self::NotFound { id },
            E::Bind(message) => Self::Bind { message },
        }
    }
}

#[uniffi::export]
pub fn rshell_port_forward_start(
    config: FfiPortForwardConfig,
) -> Result<FfiPortForwardStatus, FfiPortForwardError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move {
            crate::port_forward::registry()
                .start(cm, config.into())
                .await
        })
        .map(Into::into)
        .map_err(Into::into)
}

#[uniffi::export]
pub fn rshell_port_forward_stop(id: String) -> Result<(), FfiPortForwardError> {
    let bridge = MacOsBridge::global();
    bridge
        .runtime
        .block_on(async move { crate::port_forward::registry().stop(&id).await })
        .map_err(Into::into)
}

#[uniffi::export]
pub fn rshell_port_forward_status(id: String) -> Result<FfiPortForwardStatus, FfiPortForwardError> {
    let bridge = MacOsBridge::global();
    bridge
        .runtime
        .block_on(async move { crate::port_forward::registry().status(&id).await })
        .map(Into::into)
        .map_err(Into::into)
}

#[uniffi::export]
pub fn rshell_port_forward_list(connection_id: Option<String>) -> Vec<FfiPortForwardStatus> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        crate::port_forward::registry()
            .list(connection_id.as_deref())
            .await
            .into_iter()
            .map(Into::into)
            .collect()
    })
}

// ---------------------------------------------------------------------------
// Server Doctor — bounded, read-only diagnostic collection. The model layer
// stays in Swift; Rust owns the SSH collection allowlist and output caps.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiDoctorCollectorProfile {
    Host,
    Systemd,
    Nginx,
    Disk,
}

impl From<FfiDoctorCollectorProfile> for doctor::DoctorCollectorProfile {
    fn from(value: FfiDoctorCollectorProfile) -> Self {
        match value {
            FfiDoctorCollectorProfile::Host => doctor::DoctorCollectorProfile::Host,
            FfiDoctorCollectorProfile::Systemd => doctor::DoctorCollectorProfile::Systemd,
            FfiDoctorCollectorProfile::Nginx => doctor::DoctorCollectorProfile::Nginx,
            FfiDoctorCollectorProfile::Disk => doctor::DoctorCollectorProfile::Disk,
        }
    }
}

impl From<doctor::DoctorCollectorProfile> for FfiDoctorCollectorProfile {
    fn from(value: doctor::DoctorCollectorProfile) -> Self {
        match value {
            doctor::DoctorCollectorProfile::Host => FfiDoctorCollectorProfile::Host,
            doctor::DoctorCollectorProfile::Systemd => FfiDoctorCollectorProfile::Systemd,
            doctor::DoctorCollectorProfile::Nginx => FfiDoctorCollectorProfile::Nginx,
            doctor::DoctorCollectorProfile::Disk => FfiDoctorCollectorProfile::Disk,
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiDoctorEvidenceKind {
    CommandOutput,
    LogExcerpt,
    ServiceStatus,
    MetricSample,
}

impl From<doctor::DoctorEvidenceKind> for FfiDoctorEvidenceKind {
    fn from(value: doctor::DoctorEvidenceKind) -> Self {
        match value {
            doctor::DoctorEvidenceKind::CommandOutput => FfiDoctorEvidenceKind::CommandOutput,
            doctor::DoctorEvidenceKind::LogExcerpt => FfiDoctorEvidenceKind::LogExcerpt,
            doctor::DoctorEvidenceKind::ServiceStatus => FfiDoctorEvidenceKind::ServiceStatus,
            doctor::DoctorEvidenceKind::MetricSample => FfiDoctorEvidenceKind::MetricSample,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCollectRequest {
    pub connection_id: String,
    pub profiles: Vec<FfiDoctorCollectorProfile>,
    pub service_name: Option<String>,
    pub max_total_bytes: u32,
    pub per_command_timeout_ms: u32,
    pub log_line_limit: u32,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorPlannedCommand {
    pub id: String,
    pub profile: FfiDoctorCollectorProfile,
    pub display_name: String,
    pub command: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCollectionPreview {
    pub planned_commands: Vec<FfiDoctorPlannedCommand>,
    pub possible_file_sources: Vec<String>,
    pub notes: Vec<String>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCommandAudit {
    pub id: String,
    pub collector_id: String,
    pub profile: FfiDoctorCollectorProfile,
    pub display_name: String,
    pub command: String,
    pub started_at_epoch_ms: u64,
    pub duration_ms: u32,
    pub exit_status: Option<i32>,
    pub stdout_bytes: u32,
    pub stderr_bytes: u32,
    pub truncated: bool,
    pub permission_limited: bool,
    pub read_only_risk: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorEvidence {
    pub id: String,
    pub kind: FfiDoctorEvidenceKind,
    pub title: String,
    pub source: String,
    pub collected_at_epoch_ms: u64,
    pub risk: String,
    pub exit_status: Option<i32>,
    pub excerpt: String,
    pub raw_output: String,
    pub raw_ref: String,
    pub byte_count: u32,
    pub line_count: u32,
    pub truncated: bool,
    pub permission_limited: bool,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorWarning {
    pub id: String,
    pub message: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCollectionBundle {
    pub id: String,
    pub collected_at_epoch_ms: u64,
    pub profiles: Vec<FfiDoctorCollectorProfile>,
    pub command_audits: Vec<FfiDoctorCommandAudit>,
    pub evidence: Vec<FfiDoctorEvidence>,
    pub warnings: Vec<FfiDoctorWarning>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiDoctorError {
    #[error("connection not found: {id}")]
    ConnectionNotFound { id: String },
    #[error("invalid request: {message}")]
    InvalidRequest { message: String },
    #[error("collector failed: {message}")]
    CollectorFailed { message: String },
}

#[uniffi::export]
pub fn rshell_doctor_preview(
    request: FfiDoctorCollectRequest,
) -> Result<FfiDoctorCollectionPreview, FfiDoctorError> {
    let profiles = doctor_profiles_or_default(&request.profiles);
    let planned_commands = doctor::commands_for_profiles(&profiles)
        .into_iter()
        .map(|command| FfiDoctorPlannedCommand {
            id: command.id.to_string(),
            profile: command.profile.into(),
            display_name: command.display_name.to_string(),
            command: command.command.to_string(),
        })
        .collect();
    Ok(FfiDoctorCollectionPreview {
        planned_commands,
        possible_file_sources: doctor::possible_file_sources(&profiles),
        notes: doctor::preview_notes(),
    })
}

#[uniffi::export]
pub fn rshell_doctor_collect(
    request: FfiDoctorCollectRequest,
) -> Result<FfiDoctorCollectionBundle, FfiDoctorError> {
    let profiles = doctor_profiles_or_default(&request.profiles);
    let commands = doctor::commands_for_profiles(&profiles);
    if commands.is_empty() {
        return Err(FfiDoctorError::InvalidRequest {
            message: "no collector profiles selected".to_string(),
        });
    }
    for command in &commands {
        if !doctor::command_is_read_only(command.command) {
            return Err(FfiDoctorError::InvalidRequest {
                message: format!("collector command is not read-only: {}", command.id),
            });
        }
    }

    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let connection_id = request.connection_id.clone();
    bridge.runtime.block_on(async move {
        let client = cm.get_connection(&connection_id).await.ok_or_else(|| {
            FfiDoctorError::ConnectionNotFound {
                id: connection_id.clone(),
            }
        })?;
        let guard = client.read().await;
        let bundle_id = format!("doctor-{}", doctor_now_ms());
        let collected_at = doctor_now_ms();
        let max_total_bytes = request.max_total_bytes.max(16 * 1024) as usize;
        let per_command_cap = (max_total_bytes / commands.len().max(1)).clamp(8 * 1024, 256 * 1024);
        let line_limit = request.log_line_limit.max(40) as usize;
        let timeout = std::time::Duration::from_millis(u64::from(
            request.per_command_timeout_ms.clamp(500, 30_000),
        ));

        let mut command_audits = Vec::with_capacity(commands.len());
        let mut evidence = Vec::with_capacity(commands.len());
        let mut warnings = Vec::new();

        for (index, command) in commands.iter().enumerate() {
            let started_at = doctor_now_ms();
            let started = std::time::Instant::now();
            let result =
                tokio::time::timeout(timeout, guard.execute_command_full(command.command)).await;
            let duration_ms = started.elapsed().as_millis().min(u128::from(u32::MAX)) as u32;
            let evidence_id = format!("evidence-{}-{}", command.id, index);
            let audit_id = format!("audit-{}-{}", command.id, index);

            match result {
                Ok(Ok(output)) => {
                    let stdout = output.stdout;
                    let stderr = output.stderr;
                    let mut combined = stdout.clone();
                    if !stderr.is_empty() {
                        if !combined.is_empty() {
                            combined.push('\n');
                        }
                        combined.push_str(&stderr);
                    }
                    let (capped, truncated, byte_count, line_count) =
                        doctor::cap_text(&combined, per_command_cap, line_limit);
                    let permission_limited = doctor::permission_limited(&combined);
                    let exit_status = output
                        .exit_code
                        .map(|code| code.min(i32::MAX as u32) as i32);

                    command_audits.push(FfiDoctorCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status,
                        stdout_bytes: stdout.len().min(u32::MAX as usize) as u32,
                        stderr_bytes: stderr.len().min(u32::MAX as usize) as u32,
                        truncated,
                        permission_limited,
                        read_only_risk: "read_only".to_string(),
                    });

                    evidence.push(FfiDoctorEvidence {
                        id: evidence_id.clone(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status,
                        excerpt: capped.clone(),
                        raw_output: capped,
                        raw_ref: format!("doctor://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count,
                        line_count,
                        truncated,
                        permission_limited,
                    });
                }
                Ok(Err(error)) => {
                    let message = error.to_string();
                    let permission_limited = doctor::permission_limited(&message);
                    command_audits.push(FfiDoctorCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status: None,
                        stdout_bytes: 0,
                        stderr_bytes: message.len().min(u32::MAX as usize) as u32,
                        truncated: false,
                        permission_limited,
                        read_only_risk: "read_only".to_string(),
                    });
                    warnings.push(FfiDoctorWarning {
                        id: format!("warning-{}-{}", command.id, index),
                        message: format!("{} failed: {}", command.display_name, message),
                    });
                    evidence.push(FfiDoctorEvidence {
                        id: evidence_id.clone(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status: None,
                        excerpt: message.clone(),
                        raw_output: message.clone(),
                        raw_ref: format!("doctor://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count: message.len().min(u32::MAX as usize) as u32,
                        line_count: message.lines().count().min(u32::MAX as usize) as u32,
                        truncated: false,
                        permission_limited,
                    });
                }
                Err(_) => {
                    let message = format!(
                        "{} timed out after {} ms",
                        command.display_name,
                        timeout.as_millis()
                    );
                    command_audits.push(FfiDoctorCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status: None,
                        stdout_bytes: 0,
                        stderr_bytes: 0,
                        truncated: false,
                        permission_limited: false,
                        read_only_risk: "read_only".to_string(),
                    });
                    warnings.push(FfiDoctorWarning {
                        id: format!("warning-{}-{}", command.id, index),
                        message: message.clone(),
                    });
                    evidence.push(FfiDoctorEvidence {
                        id: evidence_id.clone(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status: None,
                        excerpt: message.clone(),
                        raw_output: message.clone(),
                        raw_ref: format!("doctor://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count: message.len().min(u32::MAX as usize) as u32,
                        line_count: 1,
                        truncated: false,
                        permission_limited: false,
                    });
                }
            }
        }

        Ok(FfiDoctorCollectionBundle {
            id: bundle_id,
            collected_at_epoch_ms: collected_at,
            profiles: profiles.into_iter().map(Into::into).collect(),
            command_audits,
            evidence,
            warnings,
        })
    })
}

fn doctor_profiles_or_default(
    profiles: &[FfiDoctorCollectorProfile],
) -> Vec<doctor::DoctorCollectorProfile> {
    if profiles.is_empty() {
        vec![
            doctor::DoctorCollectorProfile::Host,
            doctor::DoctorCollectorProfile::Systemd,
            doctor::DoctorCollectorProfile::Nginx,
            doctor::DoctorCollectorProfile::Disk,
        ]
    } else {
        profiles.iter().copied().map(Into::into).collect()
    }
}

fn doctor_now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Security Patch Monitor — bounded, read-only package/update and sshd checks.
// Rust owns command allowlisting; Swift owns parsing, scoring, and UI.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiSecurityPatchCollectorProfile {
    Os,
    PackageManager,
    Reboot,
    Sshd,
    NetworkExposure,
}

impl From<FfiSecurityPatchCollectorProfile> for security_patch::SecurityPatchCollectorProfile {
    fn from(value: FfiSecurityPatchCollectorProfile) -> Self {
        match value {
            FfiSecurityPatchCollectorProfile::Os => {
                security_patch::SecurityPatchCollectorProfile::Os
            }
            FfiSecurityPatchCollectorProfile::PackageManager => {
                security_patch::SecurityPatchCollectorProfile::PackageManager
            }
            FfiSecurityPatchCollectorProfile::Reboot => {
                security_patch::SecurityPatchCollectorProfile::Reboot
            }
            FfiSecurityPatchCollectorProfile::Sshd => {
                security_patch::SecurityPatchCollectorProfile::Sshd
            }
            FfiSecurityPatchCollectorProfile::NetworkExposure => {
                security_patch::SecurityPatchCollectorProfile::NetworkExposure
            }
        }
    }
}

impl From<security_patch::SecurityPatchCollectorProfile> for FfiSecurityPatchCollectorProfile {
    fn from(value: security_patch::SecurityPatchCollectorProfile) -> Self {
        match value {
            security_patch::SecurityPatchCollectorProfile::Os => {
                FfiSecurityPatchCollectorProfile::Os
            }
            security_patch::SecurityPatchCollectorProfile::PackageManager => {
                FfiSecurityPatchCollectorProfile::PackageManager
            }
            security_patch::SecurityPatchCollectorProfile::Reboot => {
                FfiSecurityPatchCollectorProfile::Reboot
            }
            security_patch::SecurityPatchCollectorProfile::Sshd => {
                FfiSecurityPatchCollectorProfile::Sshd
            }
            security_patch::SecurityPatchCollectorProfile::NetworkExposure => {
                FfiSecurityPatchCollectorProfile::NetworkExposure
            }
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiSecurityPatchEvidenceKind {
    CommandOutput,
    OsRelease,
    PackageStatus,
    RebootStatus,
    SshdConfig,
    NetworkExposure,
}

impl From<security_patch::SecurityPatchEvidenceKind> for FfiSecurityPatchEvidenceKind {
    fn from(value: security_patch::SecurityPatchEvidenceKind) -> Self {
        match value {
            security_patch::SecurityPatchEvidenceKind::CommandOutput => {
                FfiSecurityPatchEvidenceKind::CommandOutput
            }
            security_patch::SecurityPatchEvidenceKind::OsRelease => {
                FfiSecurityPatchEvidenceKind::OsRelease
            }
            security_patch::SecurityPatchEvidenceKind::PackageStatus => {
                FfiSecurityPatchEvidenceKind::PackageStatus
            }
            security_patch::SecurityPatchEvidenceKind::RebootStatus => {
                FfiSecurityPatchEvidenceKind::RebootStatus
            }
            security_patch::SecurityPatchEvidenceKind::SshdConfig => {
                FfiSecurityPatchEvidenceKind::SshdConfig
            }
            security_patch::SecurityPatchEvidenceKind::NetworkExposure => {
                FfiSecurityPatchEvidenceKind::NetworkExposure
            }
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchScanRequest {
    pub connection_id: String,
    pub profiles: Vec<FfiSecurityPatchCollectorProfile>,
    pub max_total_bytes: u32,
    pub per_command_timeout_ms: u32,
    pub line_limit: u32,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchPlannedCommand {
    pub id: String,
    pub profile: FfiSecurityPatchCollectorProfile,
    pub display_name: String,
    pub command: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchScanPreview {
    pub planned_commands: Vec<FfiSecurityPatchPlannedCommand>,
    pub notes: Vec<String>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchCommandAudit {
    pub id: String,
    pub collector_id: String,
    pub profile: FfiSecurityPatchCollectorProfile,
    pub display_name: String,
    pub command: String,
    pub started_at_epoch_ms: u64,
    pub duration_ms: u32,
    pub exit_status: Option<i32>,
    pub stdout_bytes: u32,
    pub stderr_bytes: u32,
    pub truncated: bool,
    pub permission_limited: bool,
    pub risk: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchEvidence {
    pub id: String,
    pub collector_id: String,
    pub profile: FfiSecurityPatchCollectorProfile,
    pub kind: FfiSecurityPatchEvidenceKind,
    pub title: String,
    pub source: String,
    pub collected_at_epoch_ms: u64,
    pub risk: String,
    pub exit_status: Option<i32>,
    pub excerpt: String,
    pub raw_output: String,
    pub raw_ref: String,
    pub byte_count: u32,
    pub line_count: u32,
    pub truncated: bool,
    pub permission_limited: bool,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchWarning {
    pub id: String,
    pub message: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchScanBundle {
    pub id: String,
    pub scanned_at_epoch_ms: u64,
    pub profiles: Vec<FfiSecurityPatchCollectorProfile>,
    pub command_audits: Vec<FfiSecurityPatchCommandAudit>,
    pub evidence: Vec<FfiSecurityPatchEvidence>,
    pub warnings: Vec<FfiSecurityPatchWarning>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiSecurityPatchError {
    #[error("connection not found: {id}")]
    ConnectionNotFound { id: String },
    #[error("invalid request: {message}")]
    InvalidRequest { message: String },
    #[error("collector failed: {message}")]
    CollectorFailed { message: String },
}

#[uniffi::export]
pub fn rshell_security_patch_preview(
    request: FfiSecurityPatchScanRequest,
) -> Result<FfiSecurityPatchScanPreview, FfiSecurityPatchError> {
    let profiles = security_patch_profiles_or_default(&request.profiles);
    let planned_commands = security_patch::commands_for_profiles(&profiles)
        .into_iter()
        .map(|command| FfiSecurityPatchPlannedCommand {
            id: command.id.to_string(),
            profile: command.profile.into(),
            display_name: command.display_name.to_string(),
            command: command.command.to_string(),
        })
        .collect();
    Ok(FfiSecurityPatchScanPreview {
        planned_commands,
        notes: security_patch::preview_notes(),
    })
}

#[uniffi::export]
pub fn rshell_security_patch_scan(
    request: FfiSecurityPatchScanRequest,
) -> Result<FfiSecurityPatchScanBundle, FfiSecurityPatchError> {
    let profiles = security_patch_profiles_or_default(&request.profiles);
    let commands = security_patch::commands_for_profiles(&profiles);
    if commands.is_empty() {
        return Err(FfiSecurityPatchError::InvalidRequest {
            message: "no security patch collector profiles selected".to_string(),
        });
    }
    for command in &commands {
        if !security_patch::command_is_read_only(command.command) {
            return Err(FfiSecurityPatchError::InvalidRequest {
                message: format!("collector command is not read-only: {}", command.id),
            });
        }
    }

    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let connection_id = request.connection_id.clone();
    bridge.runtime.block_on(async move {
        let client = cm.get_connection(&connection_id).await.ok_or_else(|| {
            FfiSecurityPatchError::ConnectionNotFound {
                id: connection_id.clone(),
            }
        })?;
        let guard = client.read().await;
        let bundle_id = format!("security-patch-{}", doctor_now_ms());
        let scanned_at = doctor_now_ms();
        let max_total_bytes = request.max_total_bytes.max(16 * 1024) as usize;
        let per_command_cap = (max_total_bytes / commands.len().max(1)).clamp(8 * 1024, 256 * 1024);
        let line_limit = request.line_limit.max(40) as usize;
        let timeout = std::time::Duration::from_millis(u64::from(
            request.per_command_timeout_ms.clamp(500, 45_000),
        ));

        let mut command_audits = Vec::with_capacity(commands.len());
        let mut evidence = Vec::with_capacity(commands.len());
        let mut warnings = Vec::new();

        for (index, command) in commands.iter().enumerate() {
            let started_at = doctor_now_ms();
            let started = std::time::Instant::now();
            let result =
                tokio::time::timeout(timeout, guard.execute_command_full(command.command)).await;
            let duration_ms = started.elapsed().as_millis().min(u128::from(u32::MAX)) as u32;
            let evidence_id = format!("evidence-{}-{}", command.id, index);
            let audit_id = format!("audit-{}-{}", command.id, index);

            match result {
                Ok(Ok(output)) => {
                    let stdout = output.stdout;
                    let stderr = output.stderr;
                    let mut combined = stdout.clone();
                    if !stderr.is_empty() {
                        if !combined.is_empty() {
                            combined.push('\n');
                        }
                        combined.push_str(&stderr);
                    }
                    let (capped, truncated, byte_count, line_count) =
                        security_patch::cap_text(&combined, per_command_cap, line_limit);
                    let permission_limited = security_patch::permission_limited(&combined);
                    let exit_status = output
                        .exit_code
                        .map(|code| code.min(i32::MAX as u32) as i32);

                    command_audits.push(FfiSecurityPatchCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status,
                        stdout_bytes: stdout.len().min(u32::MAX as usize) as u32,
                        stderr_bytes: stderr.len().min(u32::MAX as usize) as u32,
                        truncated,
                        permission_limited,
                        risk: "read_only".to_string(),
                    });

                    evidence.push(FfiSecurityPatchEvidence {
                        id: evidence_id.clone(),
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status,
                        excerpt: capped.clone(),
                        raw_output: capped,
                        raw_ref: format!("security-patch://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count,
                        line_count,
                        truncated,
                        permission_limited,
                    });
                }
                Ok(Err(error)) => {
                    let message = error.to_string();
                    let permission_limited = security_patch::permission_limited(&message);
                    command_audits.push(FfiSecurityPatchCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status: None,
                        stdout_bytes: 0,
                        stderr_bytes: message.len().min(u32::MAX as usize) as u32,
                        truncated: false,
                        permission_limited,
                        risk: "read_only".to_string(),
                    });
                    warnings.push(FfiSecurityPatchWarning {
                        id: format!("warning-{}-{}", command.id, index),
                        message: format!("{} failed: {}", command.display_name, message),
                    });
                    evidence.push(FfiSecurityPatchEvidence {
                        id: evidence_id.clone(),
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status: None,
                        excerpt: message.clone(),
                        raw_output: message.clone(),
                        raw_ref: format!("security-patch://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count: message.len().min(u32::MAX as usize) as u32,
                        line_count: message.lines().count().min(u32::MAX as usize) as u32,
                        truncated: false,
                        permission_limited,
                    });
                }
                Err(_) => {
                    let message = format!(
                        "{} timed out after {} ms",
                        command.display_name,
                        timeout.as_millis()
                    );
                    command_audits.push(FfiSecurityPatchCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status: None,
                        stdout_bytes: 0,
                        stderr_bytes: 0,
                        truncated: false,
                        permission_limited: false,
                        risk: "read_only".to_string(),
                    });
                    warnings.push(FfiSecurityPatchWarning {
                        id: format!("warning-{}-{}", command.id, index),
                        message: message.clone(),
                    });
                    evidence.push(FfiSecurityPatchEvidence {
                        id: evidence_id.clone(),
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status: None,
                        excerpt: message.clone(),
                        raw_output: message.clone(),
                        raw_ref: format!("security-patch://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count: message.len().min(u32::MAX as usize) as u32,
                        line_count: 1,
                        truncated: false,
                        permission_limited: false,
                    });
                }
            }
        }

        Ok(FfiSecurityPatchScanBundle {
            id: bundle_id,
            scanned_at_epoch_ms: scanned_at,
            profiles: profiles.into_iter().map(Into::into).collect(),
            command_audits,
            evidence,
            warnings,
        })
    })
}

fn security_patch_profiles_or_default(
    profiles: &[FfiSecurityPatchCollectorProfile],
) -> Vec<security_patch::SecurityPatchCollectorProfile> {
    if profiles.is_empty() {
        vec![
            security_patch::SecurityPatchCollectorProfile::Os,
            security_patch::SecurityPatchCollectorProfile::PackageManager,
            security_patch::SecurityPatchCollectorProfile::Reboot,
            security_patch::SecurityPatchCollectorProfile::Sshd,
            security_patch::SecurityPatchCollectorProfile::NetworkExposure,
        ]
    } else {
        profiles.iter().copied().map(Into::into).collect()
    }
}

// ---------------------------------------------------------------------------
// Network/dev tools — git deploy-state, multi-perspective DNS, listening
// ports, and live tcpdump captures. All ride on top of an existing SSH
// connection. tcpdump capture lines arrive via the event bus as
// `tcpdump_line` FfiEvents with `connection_id == "tcpdump"`.
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiToolsError {
    #[error("connection not found: {id}")]
    ConnectionNotFound { id: String },
    #[error("connection is not SSH: {id}")]
    NotSshConnection { id: String },
    #[error("remote command failed: {message}")]
    RemoteCommand { message: String },
    #[error("ssh exec failed: {message}")]
    SshExec { message: String },
    #[error("parse error: {message}")]
    Parse { message: String },
    #[error("capture not found: {id}")]
    CaptureNotFound { id: u64 },
    #[error("io: {message}")]
    Io { message: String },
}

impl From<ssh_commander_core::ToolsError> for FfiToolsError {
    fn from(e: ssh_commander_core::ToolsError) -> Self {
        use ssh_commander_core::ToolsError as T;
        match e {
            T::ConnectionNotFound(id) => FfiToolsError::ConnectionNotFound { id },
            T::NotSshConnection(id) => FfiToolsError::NotSshConnection { id },
            T::RemoteCommand { message, .. } => FfiToolsError::RemoteCommand { message },
            T::SshExec(message) => FfiToolsError::SshExec { message },
            T::Parse(message) => FfiToolsError::Parse { message },
            T::CaptureNotFound(id) => FfiToolsError::CaptureNotFound { id },
            T::Io(e) => FfiToolsError::Io {
                message: e.to_string(),
            },
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiGitStatus {
    pub repo_path: String,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub dirty_files: u32,
    pub untracked_files: u32,
    pub last_commit_sha: Option<String>,
    pub last_commit_author: Option<String>,
    pub last_commit_age: Option<String>,
    pub last_commit_subject: Option<String>,
}

impl From<ssh_commander_core::GitStatus> for FfiGitStatus {
    fn from(g: ssh_commander_core::GitStatus) -> Self {
        Self {
            repo_path: g.repo_path,
            branch: g.branch,
            head: g.head,
            upstream: g.upstream,
            ahead: g.ahead,
            behind: g.behind,
            dirty_files: g.dirty_files,
            untracked_files: g.untracked_files,
            last_commit_sha: g.last_commit_sha,
            last_commit_author: g.last_commit_author,
            last_commit_age: g.last_commit_age,
            last_commit_subject: g.last_commit_subject,
        }
    }
}

#[uniffi::export]
pub fn rshell_git_status(
    connection_id: String,
    repo_path: String,
) -> Result<FfiGitStatus, FfiToolsError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client =
            cm.get_connection(&connection_id)
                .await
                .ok_or(FfiToolsError::ConnectionNotFound {
                    id: connection_id.clone(),
                })?;
        let client = client.read().await;
        let status = ssh_commander_core::git_status(&client, &repo_path).await?;
        Ok(status.into())
    })
}

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiDnsRecordType {
    A,
    Aaaa,
    Cname,
    Mx,
    Txt,
    Ns,
}

impl From<FfiDnsRecordType> for ssh_commander_core::tools::dns::DnsRecordType {
    fn from(t: FfiDnsRecordType) -> Self {
        use ssh_commander_core::tools::dns::DnsRecordType as R;
        match t {
            FfiDnsRecordType::A => R::A,
            FfiDnsRecordType::Aaaa => R::AAAA,
            FfiDnsRecordType::Cname => R::CNAME,
            FfiDnsRecordType::Mx => R::MX,
            FfiDnsRecordType::Txt => R::TXT,
            FfiDnsRecordType::Ns => R::NS,
        }
    }
}

impl From<ssh_commander_core::tools::dns::DnsRecordType> for FfiDnsRecordType {
    fn from(t: ssh_commander_core::tools::dns::DnsRecordType) -> Self {
        use ssh_commander_core::tools::dns::DnsRecordType as R;
        match t {
            R::A => FfiDnsRecordType::A,
            R::AAAA => FfiDnsRecordType::Aaaa,
            R::CNAME => FfiDnsRecordType::Cname,
            R::MX => FfiDnsRecordType::Mx,
            R::TXT => FfiDnsRecordType::Txt,
            R::NS => FfiDnsRecordType::Ns,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiDnsAnswer {
    pub perspective: String,
    pub query: String,
    pub record_type: FfiDnsRecordType,
    pub answers: Vec<String>,
    pub error: Option<String>,
    pub elapsed_ms: u64,
}

impl From<ssh_commander_core::DnsAnswer> for FfiDnsAnswer {
    fn from(a: ssh_commander_core::DnsAnswer) -> Self {
        Self {
            perspective: a.perspective,
            query: a.query,
            record_type: a.record_type.into(),
            answers: a.answers,
            error: a.error,
            elapsed_ms: a.elapsed_ms,
        }
    }
}

/// Resolve `name` of `record_type` from each perspective in `perspectives`,
/// in parallel. A perspective is either an SSH connection id or the
/// literal sentinel `"local"`, which uses the Mac's own resolver.
#[uniffi::export]
pub fn rshell_dns_resolve(
    name: String,
    record_type: FfiDnsRecordType,
    perspectives: Vec<String>,
) -> Vec<FfiDnsAnswer> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let query = ssh_commander_core::DnsQuery {
        name,
        record_type: record_type.into(),
    };
    bridge.runtime.block_on(async move {
        let mut handles = Vec::new();
        for p in perspectives {
            let q = query.clone();
            if p == "local" {
                handles.push(tokio::spawn(async move {
                    ssh_commander_core::dns_resolve_local(&q).await
                }));
            } else {
                let cm = cm.clone();
                let label = p.clone();
                handles.push(tokio::spawn(async move {
                    match cm.get_connection(&p).await {
                        Some(client) => {
                            let client = client.read().await;
                            ssh_commander_core::dns_resolve_remote(&client, &label, &q).await
                        }
                        None => ssh_commander_core::DnsAnswer {
                            perspective: label,
                            query: q.name.clone(),
                            record_type: q.record_type,
                            answers: vec![],
                            error: Some("connection not found".into()),
                            elapsed_ms: 0,
                        },
                    }
                }));
            }
        }
        let mut out = Vec::with_capacity(handles.len());
        for h in handles {
            if let Ok(answer) = h.await {
                out.push(answer.into());
            }
        }
        out
    })
}

#[derive(uniffi::Record, Debug)]
pub struct FfiListeningPort {
    pub protocol: String,
    pub local_addr: String,
    pub port: u16,
    pub process: Option<String>,
    pub pid: Option<u32>,
}

impl From<ssh_commander_core::ListeningPort> for FfiListeningPort {
    fn from(p: ssh_commander_core::ListeningPort) -> Self {
        Self {
            protocol: p.protocol,
            local_addr: p.local_addr,
            port: p.port,
            process: p.process,
            pid: p.pid,
        }
    }
}

#[uniffi::export]
pub fn rshell_listening_ports(
    connection_id: String,
) -> Result<Vec<FfiListeningPort>, FfiToolsError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client =
            cm.get_connection(&connection_id)
                .await
                .ok_or(FfiToolsError::ConnectionNotFound {
                    id: connection_id.clone(),
                })?;
        let client = client.read().await;
        let ports = ssh_commander_core::listening_ports(&client).await?;
        Ok(ports.into_iter().map(Into::into).collect())
    })
}

/// Start a tcpdump capture on the given SSH connection. Returns a
/// capture id; lines arrive via the event bus as `tcpdump_line` events
/// (see `start_event_listener` for payload shape).
#[uniffi::export]
pub fn rshell_tcpdump_start(
    connection_id: String,
    interface: String,
    filter: String,
    snaplen: Option<u32>,
) -> Result<u64, FfiToolsError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client =
            cm.get_connection(&connection_id)
                .await
                .ok_or(FfiToolsError::ConnectionNotFound {
                    id: connection_id.clone(),
                })?;
        let client = client.read().await;
        let id = ssh_commander_core::TcpdumpRegistry::global()
            .start(&client, &interface, &filter, snaplen)
            .await?;
        Ok(id)
    })
}

#[uniffi::export]
pub fn rshell_tcpdump_stop(capture_id: u64) -> Result<(), FfiToolsError> {
    ssh_commander_core::TcpdumpRegistry::global()
        .stop(capture_id)
        .map_err(Into::into)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_succeeds() {
        assert!(rshell_init());
    }

    #[test]
    fn connect_without_auth_fails_descriptive() {
        rshell_init();
        let result = rshell_connect(FfiConnectConfig {
            host: "nonexistent.example.com".into(),
            port: 22,
            username: "test".into(),
            password: None,
            key_path: None,
            passphrase: None,
            use_agent: false,
            agent_identity_hint: None,
            session_id: None,
        });
        match result {
            Err(ConnectError::ConfigInvalid { detail }) => {
                assert!(
                    detail.contains("password")
                        && detail.contains("key_path")
                        && detail.contains("agent")
                );
            }
            other => panic!("expected ConfigInvalid, got {:?}", other),
        }
    }

    #[test]
    fn disconnect_unknown_id_is_ok() {
        rshell_init();
        let result = rshell_disconnect("does-not-exist".into());
        assert!(result.success);
    }

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
            ssh_tunnel: None,
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

    #[test]
    fn pg_list_schemas_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_list_schemas("pg:nobody@nowhere:5432/none".into(), None) {
            Err(FfiPgError::NotConnected { detail }) => {
                assert!(detail.contains("postgres"));
            }
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_disconnect_unknown_id_is_ok() {
        rshell_init();
        let result = rshell_pg_disconnect("pg:nobody@nowhere:5432/none".into());
        assert!(result.success);
    }

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
    fn pg_quote_literal_escapes_quotes_and_backslashes() {
        assert_eq!(pg_quote_literal("plain"), "'plain'");
        assert_eq!(pg_quote_literal("it's"), "'it''s'");
        // Backslash forces the E-string form, safe under either
        // standard_conforming_strings setting.
        assert_eq!(pg_quote_literal("a\\b"), "E'a\\\\b'");
        assert_eq!(pg_quote_literal("a\\'b"), "E'a\\\\''b'");
    }

    #[test]
    fn pg_value_expr_renders_null_cast_and_bare_literal() {
        assert_eq!(pg_value_expr(None, "int4"), "NULL");
        assert_eq!(pg_value_expr(Some("5"), "int4"), "CAST('5' AS \"int4\")");
        // Unknown type: bare literal, server coerces to the column type.
        assert_eq!(pg_value_expr(Some("x"), ""), "'x'");
    }

    #[test]
    fn build_update_cell_sql_casts_value_and_keys_on_ctid() {
        assert_eq!(
            build_update_cell_sql("public", "users", "age", "int4", Some("42"), "(0,1)"),
            "UPDATE \"public\".\"users\" SET \"age\" = CAST('42' AS \"int4\") \
             WHERE ctid = '(0,1)'::tid"
        );
        assert_eq!(
            build_update_cell_sql("s", "t", "c", "text", None, "(0,2)"),
            "UPDATE \"s\".\"t\" SET \"c\" = NULL WHERE ctid = '(0,2)'::tid"
        );
        // Hostile identifiers stay inert.
        assert_eq!(
            build_update_cell_sql("pu\"blic", "t", "c", "text", Some("v"), "(0,3)"),
            "UPDATE \"pu\"\"blic\".\"t\" SET \"c\" = CAST('v' AS \"text\") \
             WHERE ctid = '(0,3)'::tid"
        );
    }

    #[test]
    fn build_insert_row_sql_handles_values_defaults_and_rowid_alias() {
        let inputs = vec![
            FfiPgInsertColumn {
                name: "id".into(),
                type_name: "int4".into(),
                value: Some("7".into()),
            },
            FfiPgInsertColumn {
                name: "label".into(),
                type_name: "text".into(),
                value: None,
            },
        ];
        assert_eq!(
            build_insert_row_sql(
                "public",
                "t",
                &inputs,
                &["id".into(), "__pg_rowid__".into()]
            ),
            "INSERT INTO \"public\".\"t\" (\"id\", \"label\") \
             VALUES (CAST('7' AS \"int4\"), NULL) \
             RETURNING \"id\", ctid::text AS \"__pg_rowid__\"; -- simple_query route"
        );
        // No explicit inputs → all server defaults.
        assert_eq!(
            build_insert_row_sql("s", "t", &[], &["id".into()]),
            "INSERT INTO \"s\".\"t\" DEFAULT VALUES RETURNING \"id\"; -- simple_query route"
        );
        // No RETURNING list at all.
        assert_eq!(
            build_insert_row_sql("s", "t", &[], &[]),
            "INSERT INTO \"s\".\"t\" DEFAULT VALUES"
        );
    }

    #[test]
    fn build_delete_rows_sql_lists_ctids_and_rejects_empty() {
        assert_eq!(
            build_delete_rows_sql("s", "t", &["(0,1)".into(), "(0,2)".into()]),
            Some("DELETE FROM \"s\".\"t\" WHERE ctid IN ('(0,1)'::tid, '(0,2)'::tid)".to_string())
        );
        assert_eq!(build_delete_rows_sql("s", "t", &[]), None);
    }

    #[test]
    fn pg_update_cell_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_update_cell(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "public".into(),
            "users".into(),
            "name".into(),
            "text".into(),
            Some("alice".into()),
            "(0,1)".into(),
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_insert_row_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_insert_row(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "public".into(),
            "users".into(),
            vec![FfiPgInsertColumn {
                name: "name".into(),
                type_name: "text".into(),
                value: Some("alice".into()),
            }],
            vec!["__pg_rowid__".into(), "name".into()],
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_delete_rows_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_delete_rows(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "public".into(),
            "users".into(),
            vec!["(0,1)".into()],
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_release_session_on_unknown_id_is_failure_result() {
        rshell_init();
        let result =
            rshell_pg_release_session("pg:nobody@nowhere:5432/none".into(), "session-1".into());
        assert!(!result.success);
    }

    #[test]
    fn port_forward_local_requires_destination() {
        rshell_init();
        let config = FfiPortForwardConfig {
            id: "forward-a".into(),
            profile_id: "profile-a".into(),
            connection_id: "ssh-a".into(),
            name: "Web".into(),
            kind: FfiPortForwardKind::Local,
            bind_host: "127.0.0.1".into(),
            bind_port: 8080,
            destination_host: None,
            destination_port: Some(80),
        };

        match rshell_port_forward_start(config) {
            Err(FfiPortForwardError::InvalidConfig { message }) => {
                assert!(message.contains("destination_host"));
            }
            other => panic!("expected InvalidConfig, got {other:?}"),
        }
    }

    #[test]
    fn port_forward_remote_returns_unsupported() {
        rshell_init();
        let config = FfiPortForwardConfig {
            id: "forward-remote".into(),
            profile_id: "profile-a".into(),
            connection_id: "ssh-a".into(),
            name: "Remote Web".into(),
            kind: FfiPortForwardKind::Remote,
            bind_host: "127.0.0.1".into(),
            bind_port: 8080,
            destination_host: Some("127.0.0.1".into()),
            destination_port: Some(80),
        };

        match rshell_port_forward_start(config) {
            Err(FfiPortForwardError::Unsupported { message }) => {
                assert!(message.contains("tcpip-forward"));
            }
            other => panic!("expected Unsupported, got {other:?}"),
        }
    }

    #[test]
    fn port_forward_local_unknown_connection_is_typed() {
        rshell_init();
        let config = FfiPortForwardConfig {
            id: "forward-missing".into(),
            profile_id: "profile-a".into(),
            connection_id: "ssh-missing".into(),
            name: "Missing SSH".into(),
            kind: FfiPortForwardKind::Local,
            bind_host: "127.0.0.1".into(),
            bind_port: 0,
            destination_host: Some("127.0.0.1".into()),
            destination_port: Some(80),
        };

        match rshell_port_forward_start(config) {
            Err(FfiPortForwardError::ConnectionNotFound { id }) => {
                assert_eq!(id, "ssh-missing");
            }
            other => panic!("expected ConnectionNotFound, got {other:?}"),
        }
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

    // Grid DML through the SQL-text path. Historically this test pinned the
    // opposite behavior: ssh-commander-core 0.1.0's editor API binds every
    // parameter as `String` against `$N::<type>` placeholders, which fails to
    // serialize for any non-text target — including the `tid` ctid — so
    // update_cell / insert_row / delete_rows were broken unconditionally. The
    // FFI now renders those statements as SQL text instead of calling core,
    // and this test requires the full edit cycle to succeed, non-text columns
    // included.
    #[test]
    fn pg_it_grid_dml_roundtrip_by_ctid() {
        let Some(cfg) = it_config("it-grid-dml") else {
            return;
        };
        rshell_init();
        let conn = rshell_pg_connect(cfg).expect("connect to live postgres");
        let sid = "it-grid-dml".to_string();

        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DROP TABLE IF EXISTS pg_agent_it_grid".into(),
            1,
        )
        .expect("drop");
        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "CREATE TABLE pg_agent_it_grid (id int, label text, \"weird \"\"col\" int)".into(),
            1,
        )
        .expect("create");
        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "INSERT INTO pg_agent_it_grid VALUES (1, 'orig', 10)".into(),
            1,
        )
        .expect("insert seed");
        let ctid_of = |conn: &str, sid: &str| -> String {
            rshell_pg_execute(
                conn.to_string(),
                sid.to_string(),
                "SELECT ctid::text FROM pg_agent_it_grid WHERE id = 1".into(),
                1,
            )
            .expect("select ctid")
            .rows[0]
                .cells[0]
                .clone()
                .expect("ctid")
        };

        // Text column — exercises the literal path plus the ctid key.
        let upd = rshell_pg_update_cell(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            "label".into(),
            "text".into(),
            Some("it's \\edited".into()),
            ctid_of(&conn, &sid),
        )
        .expect("update text cell");
        assert_eq!(upd.rows_affected, 1);
        let sel = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "SELECT label FROM pg_agent_it_grid WHERE id = 1".into(),
            1,
        )
        .expect("verify text");
        assert_eq!(
            sel.rows[0].cells[0].as_deref(),
            Some("it's \\edited"),
            "quote/backslash escaping must round-trip"
        );

        // Non-text column with a quoted identifier — the case the old
        // core path could never serialize. ctid moves on UPDATE, so
        // re-read it.
        let upd = rshell_pg_update_cell(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            "weird \"col".into(),
            "int4".into(),
            Some("42".into()),
            ctid_of(&conn, &sid),
        )
        .expect("update int cell");
        assert_eq!(upd.rows_affected, 1);

        // SET NULL.
        let upd = rshell_pg_update_cell(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            "label".into(),
            "text".into(),
            None,
            ctid_of(&conn, &sid),
        )
        .expect("update to NULL");
        assert_eq!(upd.rows_affected, 1);

        let sel = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "SELECT label, \"weird \"\"col\" FROM pg_agent_it_grid WHERE id = 1".into(),
            1,
        )
        .expect("verify");
        assert_eq!(sel.rows[0].cells[0], None, "label should be NULL");
        assert_eq!(sel.rows[0].cells[1].as_deref(), Some("42"));

        // INSERT with typed values + RETURNING, including the rowid alias.
        let inserted = rshell_pg_insert_row(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            vec![
                FfiPgInsertColumn {
                    name: "id".into(),
                    type_name: "int4".into(),
                    value: Some("2".into()),
                },
                FfiPgInsertColumn {
                    name: "label".into(),
                    type_name: "text".into(),
                    value: None,
                },
            ],
            vec!["id".into(), "label".into(), "__pg_rowid__".into()],
        )
        .expect("insert row");
        assert_eq!(inserted.cells[0].as_deref(), Some("2"));
        assert_eq!(inserted.cells[1], None);
        let new_ctid = inserted.cells[2].clone().expect("returned ctid");

        // DELETE by the returned ctid; a stale id deletes nothing.
        let del = rshell_pg_delete_rows(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            vec![new_ctid.clone()],
        )
        .expect("delete row");
        assert_eq!(del.rows_affected, 1);
        let del = rshell_pg_delete_rows(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            vec![new_ctid],
        )
        .expect("delete stale ctid");
        assert_eq!(del.rows_affected, 0, "stale ctid should match nothing");

        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DROP TABLE IF EXISTS pg_agent_it_grid".into(),
            1,
        )
        .expect("drop teardown");
        let _ = rshell_pg_release_session(conn.clone(), sid);
        let _ = rshell_pg_disconnect(conn);
    }
}
