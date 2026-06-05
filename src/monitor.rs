//! System-monitoring helpers for the macOS bridge.
//!
//! The FFI layer exposes per-connection stats (`rshell_get_system_stats`
//! etc.) that are populated by running shell commands over the live SSH
//! session. Output formats vary per server OS, so this module:
//!
//! 1. Detects the OS once via `uname -s`, cached per connection id.
//! 2. Routes each metric (stats / disks / processes) to a per-OS parser.
//! 3. Surfaces an `OsKind::Other` for unknown / unsupported hosts so
//!    the UI shows a friendly placeholder rather than a parse error.
//!
//! Adding a new OS means: (a) extend `OsKind`, (b) teach `detect` to
//! recognise the `uname -s` output, (c) add per-OS parsing for the
//! three categories.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OsKind {
    Linux,
    Darwin,
    Other(String),
}

/// Per-connection OS cache. Populated lazily on first stats call;
/// cleared when the connection is removed (caller's responsibility).
static OS_CACHE: OnceLock<Mutex<HashMap<String, OsKind>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<String, OsKind>> {
    OS_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn cached(connection_id: &str) -> Option<OsKind> {
    cache().lock().unwrap().get(connection_id).cloned()
}

pub fn store(connection_id: &str, os: OsKind) {
    cache()
        .lock()
        .unwrap()
        .insert(connection_id.to_string(), os);
}

pub fn evict(connection_id: &str) {
    cache().lock().unwrap().remove(connection_id);
}

/// Map a `uname -s` output line to a typed kind. Trims whitespace and
/// is case-insensitive on the comparison so trailing newlines or
/// stylised banners don't trip detection.
pub fn classify_uname(uname: &str) -> OsKind {
    let trimmed = uname.trim();
    match trimmed.to_ascii_lowercase().as_str() {
        "linux" => OsKind::Linux,
        "darwin" => OsKind::Darwin,
        _ => OsKind::Other(trimmed.to_string()),
    }
}

// ---------------------------------------------------------------------------
// Disk mount data
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct DiskMount {
    pub source: String,
    pub mount: String,
    pub fs_type: String,
    pub total: u64,
    pub used: u64,
}

// ---------------------------------------------------------------------------
// Process data
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ProcessRow {
    pub pid: u32,
    pub user: String,
    pub cpu_percent: f64,
    pub memory_percent: f64,
    /// `comm` from `ps` — the executable's basename, no args.
    pub command: String,
    /// Full command line including arguments. Useful when the command
    /// is something like `python` and the args carry the script name.
    pub args: String,
}

/// Pseudo-filesystems we always want to hide. `tmpfs`, `devtmpfs`,
/// `overlay`, `squashfs` etc. clutter the list and aren't meaningful
/// "disk usage" surfaces. macOS adds its own internal mounts.
pub fn is_pseudo_fs(fs_type: &str) -> bool {
    matches!(
        fs_type,
        "tmpfs"
            | "devtmpfs"
            | "devfs"
            | "proc"
            | "sysfs"
            | "cgroup"
            | "cgroup2"
            | "debugfs"
            | "tracefs"
            | "securityfs"
            | "pstore"
            | "bpf"
            | "mqueue"
            | "hugetlbfs"
            | "configfs"
            | "fusectl"
            | "binfmt_misc"
            | "rpc_pipefs"
            | "nsfs"
            | "ramfs"
            | "overlay"
            | "squashfs"
            | "autofs"
    )
}

// ---------------------------------------------------------------------------
// Linux parsers
// ---------------------------------------------------------------------------

pub mod linux {
    use super::DiskMount;

    /// Single command that prints all the stats sections separated by
    /// sentinel headers. CPU is sampled twice with a 200ms gap so the
    /// caller doesn't need to maintain prior state.
    pub const STATS_COMMAND: &str = "\
        cat /proc/stat | head -1; \
        echo '---SLEEP---'; \
        sleep 0.2; \
        cat /proc/stat | head -1; \
        echo '---MEM---'; \
        cat /proc/meminfo; \
        echo '---DISKS---'; \
        df -B1 -P -T 2>/dev/null | tail -n +2; \
        echo '---UPTIME---'; \
        cat /proc/uptime; \
        echo '---LOAD---'; \
        cat /proc/loadavg";

    pub fn parse_cpu_diff(s1: &str, s2: &str) -> Result<f64, String> {
        let extract = |s: &str| -> Result<(u64, u64), String> {
            let line = s
                .lines()
                .find(|l| l.starts_with("cpu "))
                .ok_or("no cpu line")?;
            let nums: Vec<u64> = line
                .split_whitespace()
                .skip(1)
                .filter_map(|t| t.parse().ok())
                .collect();
            if nums.len() < 4 {
                return Err("too few cpu fields".into());
            }
            let idle = nums[3] + nums.get(4).copied().unwrap_or(0); // idle + iowait
            let total: u64 = nums.iter().sum();
            Ok((total, idle))
        };
        let (t1, i1) = extract(s1)?;
        let (t2, i2) = extract(s2)?;
        let dt = t2.saturating_sub(t1);
        let di = i2.saturating_sub(i1);
        if dt == 0 {
            return Ok(0.0);
        }
        Ok(((dt - di) as f64 / dt as f64) * 100.0)
    }

    pub struct MemInfo {
        pub total: u64,
        pub used: u64,
        pub available: u64,
        pub swap_total: u64,
        pub swap_used: u64,
    }

    pub fn parse_meminfo(s: &str) -> Result<MemInfo, String> {
        let mut total = 0u64;
        let mut available = 0u64;
        let mut free = 0u64;
        let mut buffers = 0u64;
        let mut cached = 0u64;
        let mut swap_total = 0u64;
        let mut swap_free = 0u64;

        for line in s.lines() {
            let mut parts = line.split_whitespace();
            let key = parts.next().unwrap_or("");
            let value: u64 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(0) * 1024;
            match key {
                "MemTotal:" => total = value,
                "MemAvailable:" => available = value,
                "MemFree:" => free = value,
                "Buffers:" => buffers = value,
                "Cached:" => cached = value,
                "SwapTotal:" => swap_total = value,
                "SwapFree:" => swap_free = value,
                _ => {}
            }
        }
        if total == 0 {
            return Err("no MemTotal".into());
        }
        let avail = if available > 0 {
            available
        } else {
            free + buffers + cached
        };
        let used = total.saturating_sub(avail);
        let swap_used = swap_total.saturating_sub(swap_free);
        Ok(MemInfo {
            total,
            used,
            available: avail,
            swap_total,
            swap_used,
        })
    }

    /// Parse `df -B1 -P -T` rows (without the header). Each row:
    ///   filesystem fstype 1B-blocks used available capacity mountpoint
    pub fn parse_df_rows(s: &str) -> Vec<DiskMount> {
        s.lines()
            .filter_map(|line| {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() < 7 {
                    return None;
                }
                let fs_type = parts[1].to_string();
                if super::is_pseudo_fs(&fs_type) {
                    return None;
                }
                let total: u64 = parts[2].parse().ok()?;
                let used: u64 = parts[3].parse().ok()?;
                let mount = parts[6..].join(" ");
                Some(DiskMount {
                    source: parts[0].to_string(),
                    mount,
                    fs_type,
                    total,
                    used,
                })
            })
            .collect()
    }

    pub fn parse_uptime(s: &str) -> Result<u64, String> {
        let token = s.split_whitespace().next().ok_or("empty uptime")?;
        let secs: f64 = token
            .parse()
            .map_err(|e: std::num::ParseFloatError| e.to_string())?;
        Ok(secs as u64)
    }

    pub fn parse_loadavg(s: &str) -> Result<f64, String> {
        let token = s.split_whitespace().next().ok_or("empty loadavg")?;
        token
            .parse()
            .map_err(|e: std::num::ParseFloatError| e.to_string())
    }

    /// `ps` invocation that prints a stable, parseable shape for every
    /// running process. `--no-headers` is GNU-ps only; we use it on
    /// Linux. Field order matches `parse_processes` below.
    pub const PROCESSES_COMMAND: &str =
        "ps -eo pid,user:32,pcpu,pmem,comm,args --no-headers --sort=-pcpu";

    /// Parse `ps` output where each line is:
    ///   PID USER %CPU %MEM COMM ARGS...
    /// USER is right-padded to 32 chars by the `user:32` format spec
    /// so values containing spaces stay in one column.
    pub fn parse_processes(s: &str) -> Vec<super::ProcessRow> {
        s.lines()
            .filter_map(|line| super::parse_process_line(line))
            .collect()
    }
}

// ---------------------------------------------------------------------------
// macOS parsers
// ---------------------------------------------------------------------------

pub mod darwin {
    use super::DiskMount;

    /// macOS doesn't have /proc, so we lean on `top -l` (one snapshot
    /// with a 200 ms sample), `vm_stat`, `df`, and `sysctl`.
    /// `vm.loadavg` and `kern.boottime` are pre-formatted enough that
    /// parsing is straightforward. `hw.memsize` is the load-bearing
    /// total-memory value — `vm_stat` only reports page counts per
    /// category, not the system total.
    pub const STATS_COMMAND: &str = "\
        top -l 1 -n 0 -s 0 -i 1 | grep -E '^CPU usage'; \
        echo '---MEM---'; \
        vm_stat; \
        echo '---DISKS---'; \
        df -k -P | tail -n +2; \
        echo '---PAGESIZE---'; \
        sysctl -n hw.pagesize; \
        echo '---MEMSIZE---'; \
        sysctl -n hw.memsize; \
        echo '---SWAP---'; \
        sysctl -n vm.swapusage; \
        echo '---BOOTTIME---'; \
        sysctl -n kern.boottime; \
        echo '---LOAD---'; \
        sysctl -n vm.loadavg";

    /// `hw.memsize` / `hw.pagesize` print a single integer.
    pub fn parse_u64(s: &str) -> Result<u64, String> {
        s.trim()
            .parse()
            .map_err(|e: std::num::ParseIntError| e.to_string())
    }

    /// `CPU usage: 5.55% user, 11.11% sys, 83.33% idle`
    pub fn parse_cpu_top(s: &str) -> Result<f64, String> {
        let line = s.lines().next().ok_or("empty top output")?;
        let mut user = 0.0_f64;
        let mut sys = 0.0_f64;
        for token in line.split(',') {
            let trimmed = token.trim();
            if let Some(pct) = trimmed.strip_suffix("% user") {
                user = pct
                    .trim_start_matches("CPU usage:")
                    .trim()
                    .parse()
                    .unwrap_or(0.0);
            } else if let Some(pct) = trimmed.strip_suffix("% sys") {
                sys = pct.trim().parse().unwrap_or(0.0);
            }
        }
        Ok((user + sys).min(100.0))
    }

    /// `vm_stat` reports counts in pages. Caller passes `pagesize` so
    /// we don't have to make a second sysctl call here.
    pub fn parse_vm_stat(s: &str, pagesize: u64) -> Result<(u64, u64, u64), String> {
        // Returns (free, active, wired) page counts. "Pages free",
        // "Pages active", "Pages wired down" are the load-bearing
        // values for "used = active + wired" memory accounting.
        let mut free = 0u64;
        let mut active = 0u64;
        let mut wired = 0u64;
        let mut speculative = 0u64;
        let mut compressed = 0u64;
        for line in s.lines() {
            // e.g.: "Pages free:                          123456."
            if let Some((label, value)) = line.split_once(':') {
                let cleaned = value.trim().trim_end_matches('.');
                let count: u64 = cleaned.parse().unwrap_or(0);
                match label.trim() {
                    "Pages free" => free = count,
                    "Pages active" => active = count,
                    "Pages wired down" => wired = count,
                    "Pages speculative" => speculative = count,
                    "Pages occupied by compressor" => compressed = count,
                    _ => {}
                }
            }
        }
        let _ = (speculative, compressed); // silence unused-var if formatting
        Ok((free * pagesize, active * pagesize, wired * pagesize))
    }

    /// `vm.swapusage` example:
    ///   `total = 4096.00M  used = 123.45M  free = 3972.55M (encrypted)`
    /// `vm.swapusage` example:
    ///   `total = 4096.00M  used = 123.45M  free = 3972.55M (encrypted)`
    /// Walk token windows of three (`key = value`) so "total = NUM M" /
    /// "used = NUM M" are matched regardless of the field delimiter
    /// (comma or whitespace).
    pub fn parse_swapusage(s: &str) -> (u64, u64) {
        let mut total = 0u64;
        let mut used = 0u64;
        for chunk in s.split(',') {
            for kv_block in chunk.split_whitespace().collect::<Vec<_>>().windows(3) {
                if kv_block.len() == 3 && kv_block[1] == "=" {
                    let raw = kv_block[2].trim_end_matches('M');
                    let bytes = raw
                        .parse::<f64>()
                        .map(|v| (v * 1024.0 * 1024.0) as u64)
                        .unwrap_or(0);
                    match kv_block[0] {
                        "total" => total = bytes,
                        "used" => used = bytes,
                        _ => {}
                    }
                }
            }
        }
        (total, used)
    }

    /// `kern.boottime` example: `{ sec = 1714400000, usec = 0 } Sat Apr 29 …`
    pub fn parse_boottime(s: &str) -> Result<u64, String> {
        let after_sec = s.split("sec =").nth(1).ok_or("no sec field")?;
        let token = after_sec
            .split(',')
            .next()
            .ok_or("malformed boottime")?
            .trim();
        let boot: u64 = token
            .parse()
            .map_err(|e: std::num::ParseIntError| e.to_string())?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(boot);
        Ok(now.saturating_sub(boot))
    }

    /// `vm.loadavg` example: `{ 1.23 0.98 0.76 }`
    pub fn parse_loadavg(s: &str) -> Result<f64, String> {
        let cleaned = s.trim().trim_start_matches('{').trim_end_matches('}');
        let token = cleaned.split_whitespace().next().ok_or("empty loadavg")?;
        token
            .parse()
            .map_err(|e: std::num::ParseFloatError| e.to_string())
    }

    /// macOS `df -k -P` rows (without header). POSIX output keeps it
    /// to six columns:
    ///   Filesystem 1024-blocks Used Available Capacity Mounted-on
    /// — no inode columns, so the mount is always `parts[5..]`.
    /// Default `df` doesn't print fs type, so we label it "—" and rely
    /// on mount-path matching to drop macOS internals (Preboot, VM, …).
    pub fn parse_df_rows(s: &str) -> Vec<DiskMount> {
        s.lines()
            .filter_map(|line| {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() < 6 {
                    return None;
                }
                let source = parts[0].to_string();
                let total_kb: u64 = parts[1].parse().ok()?;
                let used_kb: u64 = parts[2].parse().ok()?;
                let mount = parts[5..].join(" ");

                // Hide the read-only system / preboot / VM volumes that
                // macOS surfaces. Users care about /, /System/Volumes/Data,
                // and external mounts.
                let is_macos_internal = mount.starts_with("/System/Volumes/")
                    && !mount.starts_with("/System/Volumes/Data");
                let is_macos_dev = matches!(mount.as_str(), "/dev" | "/private/var/vm");
                if is_macos_internal || is_macos_dev {
                    return None;
                }

                Some(DiskMount {
                    source,
                    mount,
                    fs_type: "—".to_string(),
                    total: total_kb * 1024,
                    used: used_kb * 1024,
                })
            })
            .collect()
    }

    /// macOS `ps` lacks `--no-headers`; we strip the header outside.
    /// Field order is identical to Linux so the same parser handles
    /// the body. `-r` sorts by CPU usage so the busiest processes
    /// surface first.
    pub const PROCESSES_COMMAND: &str = "ps -axo pid,user,pcpu,pmem,comm,args -r | tail -n +2";

    pub fn parse_processes(s: &str) -> Vec<super::ProcessRow> {
        s.lines()
            .filter_map(|line| super::parse_process_line(line))
            .collect()
    }
}

// Shared `ps` row parser: PID USER %CPU %MEM COMM ARGS...
//
// Walks fields once with a small state machine — splitting on
// whitespace only works through field 5 (`comm` is one token); the
// rest of the line is `args`, which can carry spaces. Keeping this in
// one place lets Linux and macOS share it; the only divergence is
// header handling and the `--no-headers` / `--sort=` flags, which
// each `PROCESSES_COMMAND` constant owns.
fn parse_process_line(line: &str) -> Option<ProcessRow> {
    let line = line.trim_start();
    if line.is_empty() {
        return None;
    }
    let mut iter = line.split_whitespace();
    let pid: u32 = iter.next()?.parse().ok()?;
    let user = iter.next()?.to_string();
    let cpu: f64 = iter.next()?.parse().ok()?;
    let mem: f64 = iter.next()?.parse().ok()?;
    let command = iter.next()?.to_string();
    let args = iter.collect::<Vec<_>>().join(" ");
    Some(ProcessRow {
        pid,
        user,
        cpu_percent: cpu,
        memory_percent: mem,
        command,
        args,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_uname_outputs() {
        assert_eq!(classify_uname("Linux\n"), OsKind::Linux);
        assert_eq!(classify_uname("Darwin"), OsKind::Darwin);
        assert_eq!(
            classify_uname("FreeBSD"),
            OsKind::Other("FreeBSD".to_string())
        );
    }

    #[test]
    fn linux_cpu_diff() {
        let s1 = "cpu  100 0 50 850 0 0 0 0 0 0\n";
        let s2 = "cpu  150 0 75 875 0 0 0 0 0 0\n";
        let pct = linux::parse_cpu_diff(s1, s2).unwrap();
        assert!((pct - 75.0).abs() < 0.01);
    }

    #[test]
    fn linux_meminfo() {
        let m = linux::parse_meminfo(
            "MemTotal:       16000000 kB\n\
             MemFree:         2000000 kB\n\
             MemAvailable:    8000000 kB\n\
             SwapTotal:       4000000 kB\n\
             SwapFree:        3000000 kB\n",
        )
        .unwrap();
        assert_eq!(m.total, 16_000_000 * 1024);
        assert_eq!(m.used, 8_000_000 * 1024);
        assert_eq!(m.swap_used, 1_000_000 * 1024);
    }

    #[test]
    fn linux_df_filters_pseudo() {
        // `df -B1 -P -T` rows; first row is sysfs (pseudo, dropped),
        // second is a real disk.
        let rows = linux::parse_df_rows(
            "sysfs sysfs 0 0 0 - /sys\n\
             /dev/sda1 ext4 100000000000 60000000000 40000000000 60% /\n",
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].mount, "/");
        assert_eq!(rows[0].total, 100_000_000_000);
    }

    #[test]
    fn darwin_cpu_top() {
        let pct = darwin::parse_cpu_top("CPU usage: 12.34% user, 5.66% sys, 82.0% idle").unwrap();
        assert!((pct - 18.0).abs() < 0.5);
    }

    #[test]
    fn darwin_loadavg() {
        let l = darwin::parse_loadavg("{ 1.23 0.98 0.76 }").unwrap();
        assert!((l - 1.23).abs() < 0.01);
    }

    #[test]
    fn darwin_boottime() {
        // Construct an artificial boot time 100 seconds in the past;
        // expect uptime ≈ 100. We tolerate a few seconds of drift since
        // the test reads its own clock.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let s = format!("{{ sec = {}, usec = 0 }} Sat", now - 100);
        let uptime = darwin::parse_boottime(&s).unwrap();
        assert!((100..=110).contains(&uptime), "uptime was {uptime}");
    }

    #[test]
    fn darwin_swapusage() {
        let (total, used) =
            darwin::parse_swapusage("total = 4096.00M  used = 123.45M  free = 3972.55M");
        assert_eq!(total, (4096.00 * 1024.0 * 1024.0) as u64);
        assert_eq!(used, (123.45 * 1024.0 * 1024.0) as u64);
    }

    #[test]
    fn parses_process_line() {
        // Linux `ps -eo pid,user:32,pcpu,pmem,comm,args` body row.
        let row = parse_process_line(
            "  1234 alice                            12.5  3.2 python /opt/app/server.py --port 8080",
        )
        .unwrap();
        assert_eq!(row.pid, 1234);
        assert_eq!(row.user, "alice");
        assert!((row.cpu_percent - 12.5).abs() < 0.01);
        assert!((row.memory_percent - 3.2).abs() < 0.01);
        assert_eq!(row.command, "python");
        assert!(row.args.contains("server.py"));
    }

    #[test]
    fn parse_process_skips_blank_lines() {
        assert!(parse_process_line("").is_none());
        assert!(parse_process_line("   ").is_none());
    }

    #[test]
    fn linux_processes_parses_multiple_rows() {
        let out = "  1 root  0.1 0.5 systemd /sbin/init\n\
                   42 alice 50.0 12.3 cargo cargo build --release\n";
        let rows = linux::parse_processes(out);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].pid, 1);
        assert_eq!(rows[1].pid, 42);
        assert!((rows[1].cpu_percent - 50.0).abs() < 0.01);
    }

    #[test]
    fn darwin_df_filters_internals() {
        // POSIX `df -k -P` rows: filesystem 1024-blocks used avail capacity mount
        let rows = darwin::parse_df_rows(
            "/dev/disk1s1 100000000 50000000 50000000 50% /\n\
             /dev/disk1s2 100000000 1000000 99000000 1% /System/Volumes/Preboot\n\
             /dev/disk1s5 100000000 70000000 30000000 70% /System/Volumes/Data\n",
        );
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|r| r.mount == "/"));
        assert!(rows.iter().any(|r| r.mount == "/System/Volumes/Data"));
    }
}
