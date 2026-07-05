// Host-key trust management. SSH domain, but kept in its own include
// after system_stats.rs because `rshell_forget_host_key` sits between
// the monitoring functions and the Postgres surface in the original
// exported-item order, which the bindings pin (see mod.rs).

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
