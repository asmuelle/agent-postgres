use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DoctorCollectorProfile {
    Host,
    Systemd,
    Nginx,
    Disk,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DoctorEvidenceKind {
    CommandOutput,
    LogExcerpt,
    ServiceStatus,
    MetricSample,
}

#[derive(Debug, Clone, Copy)]
pub struct DoctorCommand {
    pub id: &'static str,
    pub profile: DoctorCollectorProfile,
    pub display_name: &'static str,
    pub command: &'static str,
    pub evidence_kind: DoctorEvidenceKind,
}

pub fn commands_for_profiles(profiles: &[DoctorCollectorProfile]) -> Vec<DoctorCommand> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for profile in profiles {
        for command in commands_for_profile(*profile) {
            if seen.insert(command.id) {
                out.push(*command);
            }
        }
    }
    out
}

pub fn possible_file_sources(profiles: &[DoctorCollectorProfile]) -> Vec<String> {
    let mut out = Vec::new();
    if profiles.contains(&DoctorCollectorProfile::Nginx) {
        out.push("/var/log/nginx/error.log".to_string());
        out.push("/etc/nginx/".to_string());
    }
    if profiles.contains(&DoctorCollectorProfile::Disk) {
        out.push("/var/log/".to_string());
    }
    out
}

pub fn preview_notes() -> Vec<String> {
    vec![
        "All commands are read-only and come from a fixed allowlist.".to_string(),
        "No interactive sudo prompt is used.".to_string(),
        "Output is bounded before it is returned to the app.".to_string(),
    ]
}

fn commands_for_profile(profile: DoctorCollectorProfile) -> &'static [DoctorCommand] {
    match profile {
        DoctorCollectorProfile::Host => &HOST_COMMANDS,
        DoctorCollectorProfile::Systemd => &SYSTEMD_COMMANDS,
        DoctorCollectorProfile::Nginx => &NGINX_COMMANDS,
        DoctorCollectorProfile::Disk => &DISK_COMMANDS,
    }
}

pub fn command_is_read_only(command: &str) -> bool {
    let lowered = format!(" {} ", command.to_lowercase());
    let blocked = [
        " rm ",
        " mv ",
        " cp ",
        " chmod ",
        " chown ",
        " kill ",
        " pkill ",
        " systemctl restart ",
        " systemctl reload ",
        " systemctl start ",
        " systemctl stop ",
        " apt install ",
        " apt upgrade ",
        " apt remove ",
        " dnf install ",
        " yum install ",
        " tee ",
        " drop table ",
        " truncate table ",
    ];
    !blocked.iter().any(|token| lowered.contains(token))
}

pub fn permission_limited(output: &str) -> bool {
    let lower = output.to_lowercase();
    lower.contains("permission denied")
        || lower.contains("operation not permitted")
        || lower.contains("authentication is required")
        || lower.contains("a password is required")
        || lower.contains("access denied")
}

pub fn cap_text(input: &str, max_bytes: usize, max_lines: usize) -> (String, bool, u32, u32) {
    let original_bytes = input.len();
    let original_lines = input.lines().count();

    let mut bytes = 0usize;
    let mut lines = Vec::new();
    for line in input.lines().take(max_lines) {
        let line_bytes = line.len() + 1;
        if bytes + line_bytes > max_bytes {
            break;
        }
        bytes += line_bytes;
        lines.push(line);
    }

    let truncated = original_bytes > bytes || original_lines > lines.len();
    let mut text = lines.join("\n");
    if truncated {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str("[truncated]");
    }
    (
        text,
        truncated,
        original_bytes as u32,
        original_lines as u32,
    )
}

static HOST_COMMANDS: [DoctorCommand; 7] = [
    DoctorCommand {
        id: "host-uname",
        profile: DoctorCollectorProfile::Host,
        display_name: "Kernel and OS",
        command: "uname -a",
        evidence_kind: DoctorEvidenceKind::CommandOutput,
    },
    DoctorCommand {
        id: "host-uptime",
        profile: DoctorCollectorProfile::Host,
        display_name: "Uptime and Load",
        command: "uptime",
        evidence_kind: DoctorEvidenceKind::MetricSample,
    },
    DoctorCommand {
        id: "host-df",
        profile: DoctorCollectorProfile::Host,
        display_name: "Filesystem Usage",
        command: "df -hP",
        evidence_kind: DoctorEvidenceKind::MetricSample,
    },
    DoctorCommand {
        id: "host-df-inodes",
        profile: DoctorCollectorProfile::Host,
        display_name: "Inode Usage",
        command: "df -iP",
        evidence_kind: DoctorEvidenceKind::MetricSample,
    },
    DoctorCommand {
        id: "host-free",
        profile: DoctorCollectorProfile::Host,
        display_name: "Memory Summary",
        command: "if command -v free >/dev/null 2>&1; then free -m; else echo 'free unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::MetricSample,
    },
    DoctorCommand {
        id: "host-processes",
        profile: DoctorCollectorProfile::Host,
        display_name: "Top Processes",
        command: "ps -eo pid,ppid,user,pcpu,pmem,comm,args --sort=-pcpu 2>/dev/null | head -25",
        evidence_kind: DoctorEvidenceKind::CommandOutput,
    },
    DoctorCommand {
        id: "host-listeners",
        profile: DoctorCollectorProfile::Host,
        display_name: "Listening TCP Ports",
        command: "if command -v ss >/dev/null 2>&1; then ss -ltnp; elif command -v netstat >/dev/null 2>&1; then netstat -ltnp 2>/dev/null || netstat -ltn; else echo 'socket inventory unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::CommandOutput,
    },
];

static SYSTEMD_COMMANDS: [DoctorCommand; 3] = [
    DoctorCommand {
        id: "systemd-failed",
        profile: DoctorCollectorProfile::Systemd,
        display_name: "Failed Units",
        command: "if command -v systemctl >/dev/null 2>&1; then systemctl --no-pager --failed; else echo 'systemctl unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::ServiceStatus,
    },
    DoctorCommand {
        id: "systemd-list-failed",
        profile: DoctorCollectorProfile::Systemd,
        display_name: "Failed Unit List",
        command: "if command -v systemctl >/dev/null 2>&1; then systemctl --no-pager list-units --state=failed; else echo 'systemctl unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::ServiceStatus,
    },
    DoctorCommand {
        id: "systemd-warning-journal",
        profile: DoctorCollectorProfile::Systemd,
        display_name: "Recent Warning Journal",
        command: "if command -v journalctl >/dev/null 2>&1; then journalctl -p warning..alert -n 300 --no-pager; else echo 'journalctl unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::LogExcerpt,
    },
];

static NGINX_COMMANDS: [DoctorCommand; 5] = [
    DoctorCommand {
        id: "nginx-present",
        profile: DoctorCollectorProfile::Nginx,
        display_name: "nginx Availability",
        command: "if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; else echo 'nginx unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::CommandOutput,
    },
    DoctorCommand {
        id: "nginx-test",
        profile: DoctorCollectorProfile::Nginx,
        display_name: "nginx Config Test",
        command: "if command -v nginx >/dev/null 2>&1; then nginx -t 2>&1; else echo 'nginx unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::CommandOutput,
    },
    DoctorCommand {
        id: "nginx-status",
        profile: DoctorCollectorProfile::Nginx,
        display_name: "nginx Service Status",
        command: "if command -v systemctl >/dev/null 2>&1; then systemctl --no-pager status nginx 2>&1; else echo 'systemctl unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::ServiceStatus,
    },
    DoctorCommand {
        id: "nginx-journal",
        profile: DoctorCollectorProfile::Nginx,
        display_name: "nginx Journal",
        command: "if command -v journalctl >/dev/null 2>&1; then journalctl -u nginx -n 300 --no-pager 2>&1; else echo 'journalctl unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::LogExcerpt,
    },
    DoctorCommand {
        id: "nginx-error-log",
        profile: DoctorCollectorProfile::Nginx,
        display_name: "nginx Error Log",
        command: "if [ -r /var/log/nginx/error.log ]; then tail -n 300 /var/log/nginx/error.log; else echo 'nginx error log unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::LogExcerpt,
    },
];

static DISK_COMMANDS: [DoctorCommand; 4] = [
    DoctorCommand {
        id: "disk-df",
        profile: DoctorCollectorProfile::Disk,
        display_name: "Filesystem Usage",
        command: "df -hP",
        evidence_kind: DoctorEvidenceKind::MetricSample,
    },
    DoctorCommand {
        id: "disk-df-inodes",
        profile: DoctorCollectorProfile::Disk,
        display_name: "Inode Usage",
        command: "df -iP",
        evidence_kind: DoctorEvidenceKind::MetricSample,
    },
    DoctorCommand {
        id: "disk-var-log",
        profile: DoctorCollectorProfile::Disk,
        display_name: "Log Directory Sizes",
        command: "if [ -d /var/log ]; then du -xhd1 /var/log 2>/dev/null | sort -hr | head -30; else echo '/var/log unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::MetricSample,
    },
    DoctorCommand {
        id: "disk-journal-size",
        profile: DoctorCollectorProfile::Disk,
        display_name: "Journal Disk Usage",
        command: "if command -v journalctl >/dev/null 2>&1; then journalctl --disk-usage 2>&1; else echo 'journalctl unavailable'; fi",
        evidence_kind: DoctorEvidenceKind::MetricSample,
    },
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_slice_commands_are_guarded_read_only() {
        let profiles = [
            DoctorCollectorProfile::Host,
            DoctorCollectorProfile::Systemd,
            DoctorCollectorProfile::Nginx,
            DoctorCollectorProfile::Disk,
        ];
        for command in commands_for_profiles(&profiles) {
            assert!(
                command_is_read_only(command.command),
                "{} should be read-only",
                command.id
            );
        }
    }

    #[test]
    fn guard_rejects_mutation() {
        assert!(!command_is_read_only("systemctl restart nginx"));
        assert!(!command_is_read_only("rm -rf /var/log/nginx"));
        assert!(command_is_read_only(
            "journalctl -u nginx -n 100 --no-pager"
        ));
    }

    #[test]
    fn cap_text_tracks_truncation() {
        let input = "one\ntwo\nthree\nfour";
        let (capped, truncated, bytes, lines) = cap_text(input, 100, 2);
        assert!(truncated);
        assert_eq!(bytes, input.len() as u32);
        assert_eq!(lines, 4);
        assert!(capped.contains("[truncated]"));
    }
}
