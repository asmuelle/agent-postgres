use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SecurityPatchCollectorProfile {
    Os,
    PackageManager,
    Reboot,
    Sshd,
    NetworkExposure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecurityPatchEvidenceKind {
    CommandOutput,
    OsRelease,
    PackageStatus,
    RebootStatus,
    SshdConfig,
    NetworkExposure,
}

#[derive(Debug, Clone, Copy)]
pub struct SecurityPatchCommand {
    pub id: &'static str,
    pub profile: SecurityPatchCollectorProfile,
    pub display_name: &'static str,
    pub command: &'static str,
    pub evidence_kind: SecurityPatchEvidenceKind,
}

pub fn commands_for_profiles(
    profiles: &[SecurityPatchCollectorProfile],
) -> Vec<SecurityPatchCommand> {
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

pub fn preview_notes() -> Vec<String> {
    vec![
        "All commands are fixed read-only inspection commands.".to_string(),
        "No package upgrades, service restarts, or reboots are performed.".to_string(),
        "Package metadata refresh is not run automatically.".to_string(),
        "Some package-manager checks use local cache only and may report stale data.".to_string(),
    ]
}

fn commands_for_profile(profile: SecurityPatchCollectorProfile) -> &'static [SecurityPatchCommand] {
    match profile {
        SecurityPatchCollectorProfile::Os => &OS_COMMANDS,
        SecurityPatchCollectorProfile::PackageManager => &PACKAGE_MANAGER_COMMANDS,
        SecurityPatchCollectorProfile::Reboot => &REBOOT_COMMANDS,
        SecurityPatchCollectorProfile::Sshd => &SSHD_COMMANDS,
        SecurityPatchCollectorProfile::NetworkExposure => &NETWORK_COMMANDS,
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
        " reboot ",
        " shutdown ",
        " systemctl restart ",
        " systemctl reload ",
        " systemctl start ",
        " systemctl stop ",
        " service ssh restart ",
        " apt install ",
        " apt upgrade ",
        " apt full-upgrade ",
        " apt-get install ",
        " apt-get upgrade ",
        " apt-get dist-upgrade ",
        " dnf install ",
        " dnf upgrade ",
        " dnf update ",
        " yum install ",
        " yum upgrade ",
        " yum update ",
        " zypper patch ",
        " zypper update ",
        " pacman -syu ",
        " pacman -s ",
        " apk add ",
        " apk upgrade ",
        " brew upgrade ",
        " tee ",
        " > ",
        " >> ",
    ];

    if lowered.contains(" apt-get -s upgrade ") || lowered.contains(" apt-get --simulate upgrade ")
    {
        return !blocked
            .iter()
            .filter(|token| **token != " apt-get upgrade ")
            .any(|token| lowered.contains(token));
    }

    !blocked.iter().any(|token| lowered.contains(token))
}

pub fn permission_limited(output: &str) -> bool {
    let lower = output.to_lowercase();
    lower.contains("permission denied")
        || lower.contains("operation not permitted")
        || lower.contains("authentication is required")
        || lower.contains("a password is required")
        || lower.contains("access denied")
        || lower.contains("must be root")
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

static OS_COMMANDS: [SecurityPatchCommand; 2] = [
    SecurityPatchCommand {
        id: "os-release",
        profile: SecurityPatchCollectorProfile::Os,
        display_name: "OS Release",
        command: "if [ -r /etc/os-release ]; then cat /etc/os-release; elif [ \"$(uname -s 2>/dev/null)\" = \"Darwin\" ]; then sw_vers 2>/dev/null; else echo 'os-release unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::OsRelease,
    },
    SecurityPatchCommand {
        id: "os-uname",
        profile: SecurityPatchCollectorProfile::Os,
        display_name: "Kernel",
        command: "uname -a",
        evidence_kind: SecurityPatchEvidenceKind::CommandOutput,
    },
];

static PACKAGE_MANAGER_COMMANDS: [SecurityPatchCommand; 12] = [
    SecurityPatchCommand {
        id: "pm-detect",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "Package Manager Detection",
        command: "for c in apt-get dnf yum zypper pacman apk brew; do if command -v \"$c\" >/dev/null 2>&1; then command -v \"$c\"; fi; done",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "apt-list-upgradable",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "apt Upgradable Packages",
        command: "if command -v apt >/dev/null 2>&1; then apt list --upgradable 2>/dev/null; else echo 'apt unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "apt-simulated-upgrade",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "apt Simulated Upgrade",
        command: "if command -v apt-get >/dev/null 2>&1; then apt-get -s upgrade 2>&1; else echo 'apt-get unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "apt-check",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "apt Security Count",
        command: "if [ -x /usr/lib/update-notifier/apt-check ]; then /usr/lib/update-notifier/apt-check 2>&1; else echo 'apt-check unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "dnf-security-check",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "dnf Security Check",
        command: "if command -v dnf >/dev/null 2>&1; then dnf --cacheonly check-update --security 2>&1; else echo 'dnf unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "dnf-updateinfo-security",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "dnf Security Update Info",
        command: "if command -v dnf >/dev/null 2>&1; then dnf --cacheonly updateinfo list security 2>&1; else echo 'dnf unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "yum-security-check",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "yum Security Check",
        command: "if command -v yum >/dev/null 2>&1; then yum -C --security check-update 2>&1; else echo 'yum unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "yum-updateinfo-security",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "yum Security Update Info",
        command: "if command -v yum >/dev/null 2>&1; then yum -C updateinfo list security 2>&1; else echo 'yum unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "zypper-security-patches",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "zypper Security Patches",
        command: "if command -v zypper >/dev/null 2>&1; then zypper --no-refresh --non-interactive list-patches --category security 2>&1; else echo 'zypper unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "pacman-updates",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "pacman Updates",
        command: "if command -v pacman >/dev/null 2>&1; then pacman -Qu 2>&1; else echo 'pacman unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "apk-updates",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "apk Updates",
        command: "if command -v apk >/dev/null 2>&1; then apk version -l '<' 2>&1; else echo 'apk unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
    SecurityPatchCommand {
        id: "brew-outdated",
        profile: SecurityPatchCollectorProfile::PackageManager,
        display_name: "Homebrew Outdated Packages",
        command: "if command -v brew >/dev/null 2>&1; then HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --json=v2 2>&1; else echo 'brew unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::PackageStatus,
    },
];

static REBOOT_COMMANDS: [SecurityPatchCommand; 2] = [
    SecurityPatchCommand {
        id: "reboot-required-file",
        profile: SecurityPatchCollectorProfile::Reboot,
        display_name: "Reboot Required File",
        command: "if [ -f /var/run/reboot-required ]; then cat /var/run/reboot-required; else echo 'reboot-required-file absent'; fi",
        evidence_kind: SecurityPatchEvidenceKind::RebootStatus,
    },
    SecurityPatchCommand {
        id: "needs-restarting",
        profile: SecurityPatchCollectorProfile::Reboot,
        display_name: "Needs Restarting",
        command: "if command -v needs-restarting >/dev/null 2>&1; then needs-restarting -r 2>&1; else echo 'needs-restarting unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::RebootStatus,
    },
];

static SSHD_COMMANDS: [SecurityPatchCommand; 3] = [
    SecurityPatchCommand {
        id: "sshd-version",
        profile: SecurityPatchCollectorProfile::Sshd,
        display_name: "OpenSSH Server Version",
        command: "if command -v sshd >/dev/null 2>&1; then sshd -V 2>&1; else echo 'sshd unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::CommandOutput,
    },
    SecurityPatchCommand {
        id: "sshd-effective-config",
        profile: SecurityPatchCollectorProfile::Sshd,
        display_name: "Effective sshd_config",
        command: "if command -v sshd >/dev/null 2>&1; then sshd -T 2>&1; else echo 'sshd unavailable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::SshdConfig,
    },
    SecurityPatchCommand {
        id: "sshd-config-file",
        profile: SecurityPatchCollectorProfile::Sshd,
        display_name: "Readable sshd_config",
        command: "if [ -r /etc/ssh/sshd_config ]; then sed -n '1,260p' /etc/ssh/sshd_config; else echo 'sshd_config unreadable'; fi",
        evidence_kind: SecurityPatchEvidenceKind::SshdConfig,
    },
];

static NETWORK_COMMANDS: [SecurityPatchCommand; 1] = [SecurityPatchCommand {
    id: "ssh-listeners",
    profile: SecurityPatchCollectorProfile::NetworkExposure,
    display_name: "SSH Listening Ports",
    command: "if command -v ss >/dev/null 2>&1; then ss -ltnp 2>/dev/null | grep -E '(:22|sshd)' || true; elif command -v netstat >/dev/null 2>&1; then netstat -ltnp 2>/dev/null | grep -E '(:22|sshd)' || true; else echo 'socket inventory unavailable'; fi",
    evidence_kind: SecurityPatchEvidenceKind::NetworkExposure,
}];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_slice_commands_are_guarded_read_only() {
        let profiles = [
            SecurityPatchCollectorProfile::Os,
            SecurityPatchCollectorProfile::PackageManager,
            SecurityPatchCollectorProfile::Reboot,
            SecurityPatchCollectorProfile::Sshd,
            SecurityPatchCollectorProfile::NetworkExposure,
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
    fn guard_rejects_mutation_but_allows_simulation() {
        assert!(command_is_read_only("apt-get -s upgrade"));
        assert!(!command_is_read_only("apt-get upgrade"));
        assert!(!command_is_read_only("dnf upgrade -y"));
        assert!(!command_is_read_only("systemctl restart sshd"));
        assert!(!command_is_read_only("reboot"));
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

    #[test]
    fn permission_limited_detects_common_phrases() {
        assert!(permission_limited("Permission denied"));
        assert!(permission_limited("Error: this command must be root"));
        assert!(!permission_limited("No updates available"));
    }
}
