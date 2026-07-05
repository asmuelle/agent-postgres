// SFTP operations and the per-transfer cancellation registry. Part of
// `crate::ffi` via include! — see the note in mod.rs.

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
    // A poisoned lock here just means some other holder panicked while
    // touching this plain `HashMap` — the map itself is still a valid,
    // usable value, so recovering it is safe. Propagating the panic
    // instead would cross the FFI boundary and abort the whole app.
    transfer_registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(transfer_id.to_string(), token.clone());
    token
}

fn unregister_transfer(transfer_id: &str) {
    transfer_registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(transfer_id);
}

/// Cancel an in-flight transfer by its Swift-side UUID. Returns true
/// if a transfer was found and cancelled, false if the id wasn't
/// registered (already finished, never started, or unknown). The
/// running transfer's loop notices on its next chunk boundary and
/// returns `SftpError::Cancelled`.
#[uniffi::export]
pub fn rshell_sftp_cancel(transfer_id: String) -> bool {
    if let Some(token) = transfer_registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&transfer_id)
    {
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
                    ssh_commander_core::FileEntryType::File => FfiFileKind::File,
                    ssh_commander_core::FileEntryType::Directory => FfiFileKind::Directory,
                    ssh_commander_core::FileEntryType::Symlink => FfiFileKind::Symlink,
                },
            })
            .collect())
    })
}
