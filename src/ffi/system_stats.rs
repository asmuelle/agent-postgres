// System monitoring + process signalling FFI wrappers over
// src/monitor.rs. Part of `crate::ffi` via include! — see mod.rs.

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
