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

// ---------------------------------------------------------------------------
// File layout: this module is split across the files below with `include!`
// rather than `mod` declarations. That is deliberate, not an oversight:
// UniFFI (0.31) bakes each exported item's `module_path!()` into its
// per-function API checksum and emits bindings in metadata (declaration)
// order. Moving any `#[uniffi::export]` item into a real submodule — or
// reordering exported items across files — changes `bindings/pg_agent.swift`
// and breaks the Swift/Rust checksum handshake at startup. `include!` keeps
// everything in `crate::ffi` with its original order, so the generated
// bindings stay byte-identical while the source lives in reviewable,
// domain-sized files. Non-exported helpers and tests live next to the code
// they support; the include order below is load-bearing — do not reorder.
// ---------------------------------------------------------------------------
include!("ssh.rs");
include!("sftp.rs");
include!("system_stats.rs");
include!("host_key.rs");
include!("postgres/connect.rs");
include!("postgres/query.rs");
include!("postgres/grid_dml.rs");
include!("postgres/schema.rs");
include!("postgres/activity.rs");
include!("keychain.rs");
include!("port_forward.rs");
include!("doctor.rs");
include!("security_patch.rs");
include!("tools.rs");
