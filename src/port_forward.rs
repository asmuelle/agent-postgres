use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context as _, anyhow};
use ssh_commander_core::SshClient;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, RwLock};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortForwardKind {
    Local,
    Remote,
    DynamicSocks,
}

#[derive(Debug, Clone)]
pub struct PortForwardConfig {
    pub id: String,
    pub profile_id: String,
    pub connection_id: String,
    pub name: String,
    pub kind: PortForwardKind,
    pub bind_host: String,
    pub bind_port: u16,
    pub destination_host: Option<String>,
    pub destination_port: Option<u16>,
}

#[derive(Debug, Clone)]
pub struct PortForwardStatus {
    pub id: String,
    pub profile_id: String,
    pub connection_id: String,
    pub name: String,
    pub kind: PortForwardKind,
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

#[derive(Debug, thiserror::Error)]
pub enum PortForwardError {
    #[error("connection not found: {0}")]
    ConnectionNotFound(String),
    #[error("invalid forward configuration: {0}")]
    InvalidConfig(String),
    #[error("remote SSH forwarding is not available: {0}")]
    Unsupported(String),
    #[error("port forward not found: {0}")]
    NotFound(String),
    #[error("bind failed: {0}")]
    Bind(String),
}

#[derive(Debug, Default)]
struct ForwardStats {
    bytes_in: Arc<AtomicU64>,
    bytes_out: Arc<AtomicU64>,
    connection_count: Arc<AtomicU64>,
    last_error: Mutex<Option<String>>,
}

struct ActiveForward {
    config: PortForwardConfig,
    bound_port: u16,
    started_at_unix: u64,
    cancel: CancellationToken,
    stats: Arc<ForwardStats>,
    accept_task: JoinHandle<()>,
}

impl ActiveForward {
    async fn status(&self) -> PortForwardStatus {
        PortForwardStatus {
            id: self.config.id.clone(),
            profile_id: self.config.profile_id.clone(),
            connection_id: self.config.connection_id.clone(),
            name: self.config.name.clone(),
            kind: self.config.kind,
            bind_host: self.config.bind_host.clone(),
            bind_port: self.config.bind_port,
            bound_port: self.bound_port,
            destination_host: self.config.destination_host.clone(),
            destination_port: self.config.destination_port,
            started_at_unix: self.started_at_unix,
            duration_secs: now_unix().saturating_sub(self.started_at_unix),
            bytes_in: self.stats.bytes_in.load(Ordering::Relaxed),
            bytes_out: self.stats.bytes_out.load(Ordering::Relaxed),
            connection_count: self.stats.connection_count.load(Ordering::Relaxed),
            last_error: self.stats.last_error.lock().await.clone(),
        }
    }
}

pub struct PortForwardRegistry {
    active: Mutex<HashMap<String, ActiveForward>>,
}

impl PortForwardRegistry {
    fn new() -> Self {
        Self {
            active: Mutex::new(HashMap::new()),
        }
    }

    pub async fn start(
        &self,
        connection_manager: Arc<ssh_commander_core::ConnectionManager>,
        config: PortForwardConfig,
    ) -> Result<PortForwardStatus, PortForwardError> {
        validate_config(&config)?;

        if config.kind == PortForwardKind::Remote {
            return Err(PortForwardError::Unsupported(
                "ssh-commander-core does not expose tcpip-forward/session callbacks yet".into(),
            ));
        }

        let ssh_client = connection_manager
            .get_connection(&config.connection_id)
            .await
            .ok_or_else(|| PortForwardError::ConnectionNotFound(config.connection_id.clone()))?;

        if let Some(previous) = self.active.lock().await.remove(&config.id) {
            stop_active(previous).await;
        }

        let listener = TcpListener::bind((config.bind_host.as_str(), config.bind_port))
            .await
            .map_err(|e| PortForwardError::Bind(e.to_string()))?;
        let bound_port = listener
            .local_addr()
            .map_err(|e| PortForwardError::Bind(e.to_string()))?
            .port();
        let stats = Arc::new(ForwardStats::default());
        let cancel = CancellationToken::new();
        let task_cancel = cancel.clone();
        let task_config = config.clone();
        let task_stats = stats.clone();

        let accept_task = tokio::spawn(async move {
            match task_config.kind {
                PortForwardKind::Local => {
                    run_local_accept_loop(
                        listener,
                        ssh_client,
                        task_config,
                        task_stats,
                        task_cancel,
                    )
                    .await
                }
                PortForwardKind::DynamicSocks => {
                    run_socks_accept_loop(listener, ssh_client, task_stats, task_cancel).await
                }
                PortForwardKind::Remote => {}
            }
        });

        let active = ActiveForward {
            config: config.clone(),
            bound_port,
            started_at_unix: now_unix(),
            cancel,
            stats,
            accept_task,
        };
        let status = active.status().await;
        self.active.lock().await.insert(config.id.clone(), active);
        Ok(status)
    }

    pub async fn stop(&self, id: &str) -> Result<(), PortForwardError> {
        let active = self
            .active
            .lock()
            .await
            .remove(id)
            .ok_or_else(|| PortForwardError::NotFound(id.to_string()))?;
        stop_active(active).await;
        Ok(())
    }

    pub async fn stop_for_connection(&self, connection_id: &str) -> usize {
        let active = {
            let mut guard = self.active.lock().await;
            let ids: Vec<String> = guard
                .iter()
                .filter(|(_, active)| active.config.connection_id == connection_id)
                .map(|(id, _)| id.clone())
                .collect();
            ids.into_iter()
                .filter_map(|id| guard.remove(&id))
                .collect::<Vec<_>>()
        };

        let count = active.len();
        for forward in active {
            stop_active(forward).await;
        }
        count
    }

    pub async fn status(&self, id: &str) -> Result<PortForwardStatus, PortForwardError> {
        let guard = self.active.lock().await;
        let active = guard
            .get(id)
            .ok_or_else(|| PortForwardError::NotFound(id.to_string()))?;
        Ok(active.status().await)
    }

    pub async fn list(&self, connection_id: Option<&str>) -> Vec<PortForwardStatus> {
        let guard = self.active.lock().await;
        let active: Vec<&ActiveForward> = guard
            .values()
            .filter(|active| {
                connection_id
                    .map(|id| active.config.connection_id == id)
                    .unwrap_or(true)
            })
            .collect();
        let mut statuses = Vec::with_capacity(active.len());
        for forward in active {
            statuses.push(forward.status().await);
        }
        statuses.sort_by(|a, b| a.name.cmp(&b.name).then(a.id.cmp(&b.id)));
        statuses
    }
}

pub fn registry() -> &'static PortForwardRegistry {
    static REGISTRY: OnceLock<PortForwardRegistry> = OnceLock::new();
    REGISTRY.get_or_init(PortForwardRegistry::new)
}

async fn stop_active(active: ActiveForward) {
    active.cancel.cancel();
    active.accept_task.abort();
    let _ = active.accept_task.await;
}

fn validate_config(config: &PortForwardConfig) -> Result<(), PortForwardError> {
    if config.id.trim().is_empty() {
        return Err(PortForwardError::InvalidConfig("id is required".into()));
    }
    if config.profile_id.trim().is_empty() {
        return Err(PortForwardError::InvalidConfig(
            "profile_id is required".into(),
        ));
    }
    if config.connection_id.trim().is_empty() {
        return Err(PortForwardError::InvalidConfig(
            "connection_id is required".into(),
        ));
    }
    if config.bind_host.trim().is_empty() {
        return Err(PortForwardError::InvalidConfig(
            "bind_host is required".into(),
        ));
    }

    match config.kind {
        PortForwardKind::Local | PortForwardKind::Remote => {
            let host = config
                .destination_host
                .as_deref()
                .unwrap_or("")
                .trim()
                .to_string();
            if host.is_empty() {
                return Err(PortForwardError::InvalidConfig(
                    "destination_host is required".into(),
                ));
            }
            if config.destination_port.unwrap_or(0) == 0 {
                return Err(PortForwardError::InvalidConfig(
                    "destination_port is required".into(),
                ));
            }
        }
        PortForwardKind::DynamicSocks => {}
    }
    Ok(())
}

async fn run_local_accept_loop(
    listener: TcpListener,
    ssh_client: Arc<RwLock<SshClient>>,
    config: PortForwardConfig,
    stats: Arc<ForwardStats>,
    cancel: CancellationToken,
) {
    let remote_host = config.destination_host.unwrap_or_default();
    let remote_port = config.destination_port.unwrap_or_default();

    loop {
        tokio::select! {
            _ = cancel.cancelled() => return,
            accepted = listener.accept() => {
                match accepted {
                    Ok((local_stream, _peer)) => {
                        stats.connection_count.fetch_add(1, Ordering::Relaxed);
                        let ssh_client = ssh_client.clone();
                        let stats = stats.clone();
                        let remote_host = remote_host.clone();
                        let cancel = cancel.clone();
                        tokio::spawn(async move {
                            if let Err(e) = forward_direct_tcpip(
                                local_stream,
                                ssh_client,
                                &remote_host,
                                remote_port,
                                stats.clone(),
                                cancel,
                            ).await {
                                record_error(&stats, e.to_string()).await;
                            }
                        });
                    }
                    Err(e) => {
                        record_error(&stats, format!("accept failed: {e}")).await;
                        tokio::task::yield_now().await;
                    }
                }
            }
        }
    }
}

async fn run_socks_accept_loop(
    listener: TcpListener,
    ssh_client: Arc<RwLock<SshClient>>,
    stats: Arc<ForwardStats>,
    cancel: CancellationToken,
) {
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return,
            accepted = listener.accept() => {
                match accepted {
                    Ok((local_stream, _peer)) => {
                        stats.connection_count.fetch_add(1, Ordering::Relaxed);
                        let ssh_client = ssh_client.clone();
                        let stats = stats.clone();
                        let cancel = cancel.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_socks_client(
                                local_stream,
                                ssh_client,
                                stats.clone(),
                                cancel,
                            ).await {
                                record_error(&stats, e.to_string()).await;
                            }
                        });
                    }
                    Err(e) => {
                        record_error(&stats, format!("accept failed: {e}")).await;
                        tokio::task::yield_now().await;
                    }
                }
            }
        }
    }
}

async fn forward_direct_tcpip(
    local_stream: TcpStream,
    ssh_client: Arc<RwLock<SshClient>>,
    remote_host: &str,
    remote_port: u16,
    stats: Arc<ForwardStats>,
    cancel: CancellationToken,
) -> anyhow::Result<()> {
    let channel = {
        let guard = ssh_client.read().await;
        guard
            .open_direct_tcpip(remote_host, remote_port)
            .await
            .with_context(|| format!("open direct-tcpip to {remote_host}:{remote_port}"))?
    };
    splice_streams(local_stream, channel.into_stream(), stats, cancel).await
}

async fn handle_socks_client(
    mut local_stream: TcpStream,
    ssh_client: Arc<RwLock<SshClient>>,
    stats: Arc<ForwardStats>,
    cancel: CancellationToken,
) -> anyhow::Result<()> {
    let (target_host, target_port) = match read_socks_connect_request(&mut local_stream).await {
        Ok(target) => target,
        Err(e) => {
            let _ = local_stream.write_all(&[0x05, 0xff]).await;
            return Err(e);
        }
    };

    let channel = {
        let guard = ssh_client.read().await;
        match guard.open_direct_tcpip(&target_host, target_port).await {
            Ok(channel) => channel,
            Err(e) => {
                let _ = write_socks_reply(&mut local_stream, 0x01).await;
                return Err(anyhow!(
                    "open direct-tcpip to {target_host}:{target_port}: {e}"
                ));
            }
        }
    };

    write_socks_reply(&mut local_stream, 0x00).await?;
    splice_streams(local_stream, channel.into_stream(), stats, cancel).await
}

async fn read_socks_connect_request(stream: &mut TcpStream) -> anyhow::Result<(String, u16)> {
    let mut greeting = [0_u8; 2];
    stream.read_exact(&mut greeting).await?;
    if greeting[0] != 0x05 {
        return Err(anyhow!("unsupported SOCKS version {}", greeting[0]));
    }

    let methods_len = greeting[1] as usize;
    let mut methods = vec![0_u8; methods_len];
    stream.read_exact(&mut methods).await?;
    if !methods.contains(&0x00) {
        stream.write_all(&[0x05, 0xff]).await?;
        return Err(anyhow!("SOCKS client does not allow no-auth mode"));
    }
    stream.write_all(&[0x05, 0x00]).await?;

    let mut request = [0_u8; 4];
    stream.read_exact(&mut request).await?;
    if request[0] != 0x05 {
        return Err(anyhow!("unsupported SOCKS request version {}", request[0]));
    }
    if request[1] != 0x01 {
        let _ = write_socks_reply(stream, 0x07).await;
        return Err(anyhow!("SOCKS command {} is not supported", request[1]));
    }
    if request[2] != 0x00 {
        return Err(anyhow!("invalid SOCKS reserved byte {}", request[2]));
    }

    let host = match request[3] {
        0x01 => {
            let mut addr = [0_u8; 4];
            stream.read_exact(&mut addr).await?;
            IpAddr::V4(Ipv4Addr::from(addr)).to_string()
        }
        0x03 => {
            let mut len = [0_u8; 1];
            stream.read_exact(&mut len).await?;
            let mut bytes = vec![0_u8; len[0] as usize];
            stream.read_exact(&mut bytes).await?;
            String::from_utf8(bytes).context("SOCKS domain is not UTF-8")?
        }
        0x04 => {
            let mut addr = [0_u8; 16];
            stream.read_exact(&mut addr).await?;
            IpAddr::V6(Ipv6Addr::from(addr)).to_string()
        }
        other => {
            let _ = write_socks_reply(stream, 0x08).await;
            return Err(anyhow!("SOCKS address type {other} is not supported"));
        }
    };

    let mut port = [0_u8; 2];
    stream.read_exact(&mut port).await?;
    Ok((host, u16::from_be_bytes(port)))
}

async fn write_socks_reply(stream: &mut TcpStream, code: u8) -> std::io::Result<()> {
    stream
        .write_all(&[0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        .await
}

async fn splice_streams<S>(
    local_stream: TcpStream,
    ssh_stream: S,
    stats: Arc<ForwardStats>,
    cancel: CancellationToken,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (local_read, local_write) = tokio::io::split(local_stream);
    let (ssh_read, ssh_write) = tokio::io::split(ssh_stream);

    let mut local_read = CountingReader::new(local_read, stats.bytes_in.clone());
    let mut ssh_write = ssh_write;
    let mut ssh_read = CountingReader::new(ssh_read, stats.bytes_out.clone());
    let mut local_write = local_write;

    let local_to_ssh = async {
        let result = tokio::io::copy(&mut local_read, &mut ssh_write).await;
        let _ = ssh_write.shutdown().await;
        result
    };
    let ssh_to_local = async {
        let result = tokio::io::copy(&mut ssh_read, &mut local_write).await;
        let _ = local_write.shutdown().await;
        result
    };

    tokio::select! {
        _ = cancel.cancelled() => Ok(()),
        result = async {
            tokio::try_join!(local_to_ssh, ssh_to_local).map(|_| ())
        } => result.map_err(anyhow::Error::from),
    }
}

struct CountingReader<R> {
    inner: R,
    counter: Arc<AtomicU64>,
}

impl<R> CountingReader<R> {
    fn new(inner: R, counter: Arc<AtomicU64>) -> Self {
        Self { inner, counter }
    }
}

impl<R: AsyncRead + Unpin> AsyncRead for CountingReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let poll = Pin::new(&mut self.inner).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = &poll {
            let read = buf.filled().len().saturating_sub(before);
            if read > 0 {
                self.counter.fetch_add(read as u64, Ordering::Relaxed);
            }
        }
        poll
    }
}

async fn record_error(stats: &Arc<ForwardStats>, message: String) {
    *stats.last_error.lock().await = Some(message);
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}
