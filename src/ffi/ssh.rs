// SSH connection lifecycle, typed connect errors, PTY sessions, and
// remote command execution. Part of `crate::ffi` via include! — see
// the note in mod.rs.

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

#[cfg(test)]
mod ssh_tests {
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
}
