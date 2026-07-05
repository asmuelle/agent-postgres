//! Shared helpers for the doctor and security-patch collectors.
//!
//! Both `doctor` and `security_patch` build a fixed, per-profile
//! read-only command allowlist and run every command through the same
//! three guards before it's ever executed over SSH: reject mutating
//! commands, detect permission-limited output, and cap captured output
//! to a bounded size. The two modules used to hand-roll near-identical
//! copies of all three; this module holds the single implementation
//! each wraps with its own domain-specific extras.

/// Tokens that mark a command as mutating rather than read-only. This is
/// the union of every token either collector module has ever needed to
/// block. A command is rejected here even if the blocking token doesn't
/// appear in that caller's own fixed command list — that's always safe
/// (strictly more conservative, and never rejects either collector's own
/// commands; see each module's `first_slice_commands_are_guarded_read_only`
/// test).
const BLOCKED_TOKENS: &[&str] = &[
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
    " apt remove ",
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
    " drop table ",
    " truncate table ",
];

/// The one token exempted from the blocklist when `allow_apt_get_simulate`
/// is set — see `command_is_read_only`.
const APT_GET_UPGRADE_TOKEN: &str = " apt-get upgrade ";

/// Returns `true` when `command` contains none of the blocked mutation
/// tokens.
///
/// When `allow_apt_get_simulate` is set, an `apt-get -s upgrade` /
/// `apt-get --simulate upgrade` invocation is allowed through even
/// though it contains `apt-get upgrade` as a substring — the
/// security-patch scanner needs the simulated dry run (which never
/// mutates the system) to report upgradable security packages.
pub fn command_is_read_only(command: &str, allow_apt_get_simulate: bool) -> bool {
    let lowered = format!(" {} ", command.to_lowercase());

    if allow_apt_get_simulate
        && (lowered.contains(" apt-get -s upgrade ")
            || lowered.contains(" apt-get --simulate upgrade "))
    {
        return !BLOCKED_TOKENS
            .iter()
            .filter(|token| **token != APT_GET_UPGRADE_TOKEN)
            .any(|token| lowered.contains(token));
    }

    !BLOCKED_TOKENS.iter().any(|token| lowered.contains(token))
}

const BASE_PERMISSION_PHRASES: &[&str] = &[
    "permission denied",
    "operation not permitted",
    "authentication is required",
    "a password is required",
    "access denied",
];

/// Detects command output indicating the SSH session lacked the
/// privilege to complete the command. `extra_phrases` lets a caller add
/// its own domain-specific phrases (e.g. security-patch's "must be
/// root") without duplicating the base set.
pub fn permission_limited(output: &str, extra_phrases: &[&str]) -> bool {
    let lower = output.to_lowercase();
    BASE_PERMISSION_PHRASES.iter().any(|p| lower.contains(p))
        || extra_phrases.iter().any(|p| lower.contains(p))
}

/// Caps `input` to at most `max_lines` lines and `max_bytes` bytes,
/// appending a `[truncated]` marker when either limit was hit. Returns
/// `(capped_text, truncated, original_byte_count, original_line_count)`.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_rejects_mutation_and_common_read_only_commands_pass() {
        assert!(!command_is_read_only("systemctl restart nginx", false));
        assert!(!command_is_read_only("rm -rf /var/log/nginx", false));
        assert!(command_is_read_only(
            "journalctl -u nginx -n 100 --no-pager",
            false
        ));
    }

    #[test]
    fn guard_rejects_mutation_but_allows_simulation_when_enabled() {
        assert!(command_is_read_only("apt-get -s upgrade", true));
        assert!(!command_is_read_only("apt-get upgrade", true));
        assert!(!command_is_read_only("dnf upgrade -y", true));
        assert!(!command_is_read_only("systemctl restart sshd", true));
        assert!(!command_is_read_only("reboot", true));
        // The plain `apt-get upgrade` token still isn't a substring of
        // `apt-get -s upgrade`, so this stays read-only either way —
        // the simulate flag only matters for commands that would
        // otherwise trip the `apt-get upgrade` block.
        assert!(command_is_read_only("apt-get -s upgrade", false));
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
    fn permission_limited_detects_base_and_extra_phrases() {
        assert!(permission_limited("Permission denied", &[]));
        assert!(!permission_limited("Error: this command must be root", &[]));
        assert!(permission_limited(
            "Error: this command must be root",
            &["must be root"]
        ));
        assert!(!permission_limited(
            "No updates available",
            &["must be root"]
        ));
    }
}
