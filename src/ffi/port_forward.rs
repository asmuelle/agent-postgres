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

#[cfg(test)]
mod port_forward_tests {
    use super::*;

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
}
