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
