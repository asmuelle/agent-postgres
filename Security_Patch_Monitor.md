# Security Patch Monitor

Implementation detail: see [`Security_Patch_Monitor_Implementation_Plan.md`](Security_Patch_Monitor_Implementation_Plan.md).

## Positioning

Midnight SSH can grow beyond "SSH client" into a security-aware development workspace. The user is already connecting to servers, browsing files, running commands, and managing infrastructure. That makes the app a natural place to answer:

> Which connected machines need security attention before they become incidents?

The feature should be sold as **Security Patch Monitor for SSH Workspaces**, not as a generic vulnerability scanner. The value is context: the app knows the user's saved hosts, SSH access paths, package managers, remote project files, and developer workflows.

## Core Promise

When a user opens a saved host, Midnight SSH should show whether that machine is:

- up to date
- missing security updates
- running vulnerable packages
- using risky SSH server settings
- waiting for a reboot after patching
- running an unsupported operating system
- exposing high-risk services

The app should prioritize what matters instead of dumping raw CVE lists.

## Feature Set

### Remote Update Monitor

Detect the remote operating system and package manager over SSH, then surface package and system maintenance status.

Supported package managers should include:

- `apt`
- `dnf`
- `yum`
- `zypper`
- `pacman`
- `apk`
- Homebrew

The monitor should show:

- security updates available
- normal updates available
- kernel update pending
- reboot required
- OS end-of-life warning
- last successful scan time
- package manager errors or stale metadata

Suggested host badges:

- `Secure`
- `Updates Available`
- `Security Updates`
- `Critical`
- `Reboot Needed`
- `Unsupported OS`

### Vulnerable Package Scanner

Inventory installed packages and match them against vulnerability data.

Use OS and distro vendor feeds where possible. This matters because Linux distributions often backport security patches without changing the upstream version number. A scanner that only compares upstream versions will create false positives.

Supplement vendor data with public vulnerability sources:

- [OSV](https://osv.dev/) for open-source package ecosystems
- [NVD CVE API](https://nvd.nist.gov/developers/vulnerabilities) for CVEs, CVSS, CPE data, and KEV metadata
- [GitHub Advisory Database](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/fix-reported-vulnerabilities/browsing-security-advisories-in-the-github-advisory-database) for language and package advisories
- [OpenSSF OSV Schema](https://openssf.org/osv-schema/) as a normalized vulnerability format
- [CISA Known Exploited Vulnerabilities Catalog](https://www.cisa.gov/known-exploited-vulnerabilities-catalog) for actively exploited CVE prioritization

### Risk Prioritization

The product should answer "What should I patch first?"

Prioritize issues by:

- CISA KEV / known exploited status
- CVSS severity
- whether the vulnerable package is installed only or actively running
- whether the affected service is listening on a network port
- whether the host is internet-facing
- whether the package is infrastructure-critical, such as OpenSSH, OpenSSL, kernel, sudo, nginx, Apache, Postgres, Docker, containerd, Git, curl, or systemd

Example finding:

> Critical: vulnerable OpenSSL package is used by an active nginx process listening on port 443.

### SSH-Specific Hardening Monitor

This is the most differentiated part of the feature because it fits the app's domain directly.

Checks should include:

- OpenSSH server version
- `sshd_config` risk flags
- root login enabled
- password authentication enabled
- empty-password login allowed
- weak ciphers
- weak MACs
- weak key exchange algorithms
- missing or high `MaxAuthTries`
- TCP forwarding exposure
- agent forwarding exposure
- public SSH exposure
- known-host trust state issues

Example warnings:

- `PermitRootLogin yes`
- `PasswordAuthentication yes`
- `PermitEmptyPasswords yes`
- `AllowTcpForwarding yes`
- weak legacy algorithms enabled

### One-Click Patch Plan

Do not start with fully automatic patching. That is risky and hard to sell to cautious operators.

Start with a reviewable patch plan:

- show proposed commands
- show packages that will change
- classify risk
- allow dry run
- run security updates over SSH
- save command transcript
- detect whether reboot is required
- optionally schedule or trigger reboot
- reconnect after reboot

Suggested actions:

- `Review Patch Plan`
- `Run Security Updates`
- `Run Dry Run`
- `Schedule Reboot`
- `Export Change Report`

### Dependency Scanning For Remote Projects

When the user browses files or opens a remote workspace, detect project dependency manifests and lockfiles.

Useful files to detect:

- `package-lock.json`
- `pnpm-lock.yaml`
- `yarn.lock`
- `requirements.txt`
- `Pipfile.lock`
- `poetry.lock`
- `Cargo.lock`
- `go.mod`
- `composer.lock`
- `Gemfile.lock`
- Dockerfiles
- container image references

Scan these through OSV and GitHub advisories. This turns Midnight SSH into a remote development security assistant, not just a server patching tool.

### Fleet Dashboard

For users with multiple saved hosts, add a security overview.

The dashboard should show:

- hosts with critical issues
- hosts with pending security updates
- unsupported operating systems
- pending reboots
- last scan time
- stale scan data
- vulnerable exposed services
- SSH hardening failures

This is the strongest team and business upsell surface.

### Reports For Teams

Export security evidence that teams can share internally or with clients.

Useful reports:

- patch status report
- vulnerability report
- SSH hardening report
- change report
- scan history per host
- evidence report with host, scan time, user, commands run, packages updated, and remaining CVEs

Reports make the feature easier to justify commercially because they help users prove that maintenance happened.

## Product Packaging

### Free / Basic

- manual scan for one host
- OS and package manager detection
- basic update status
- SSH hardening warnings
- reboot required detection

### Pro

- unlimited saved host scans
- vulnerable package matching
- security update categorization
- patch plans
- dry-run support
- command transcript
- language dependency scanning
- per-host security history

### Team / Business

- scheduled monitoring
- fleet dashboard
- shared host inventory
- policy rules
- Slack or email alerts
- report export
- compliance-style evidence
- team-visible remediation status

## MVP

The first version should avoid full enterprise scanner complexity. Build the narrow version that provides immediate value to SSH users.

MVP scope:

1. Detect remote OS and package manager over SSH.
2. Show security updates available.
3. Show normal updates available.
4. Detect reboot required.
5. Scan OpenSSH version.
6. Inspect risky `sshd_config` settings.
7. Add a per-host `Security` tab.
8. Add host-level badges for security state.

Later versions can add NVD, OSV, GitHub Advisory, and CISA KEV correlation.

## Suggested User Experience

Each saved host should have a visible security state in the connection list.

Example:

```text
production-api-01
Security Updates: 4
Critical: 1
Reboot Needed
Last Scan: 11 minutes ago
```

The host detail view should include a `Security` tab with sections:

- Summary
- Updates
- Vulnerabilities
- SSH Hardening
- Patch Plan
- History

The app should avoid alarm fatigue. Use strong language only when exploitation risk is real or the vulnerable package is actively used.

## Implementation Notes

The existing architecture already has a natural place for this:

- Swift UI: new `Security` tab and host badges
- Swift manager: `BridgeManager+Security.swift`
- Rust FFI: security scan functions in `src/ffi.rs`
- Rust bridge: run remote commands through the existing SSH connection manager where possible
- Persistence: per-host scan result cache and history

Proposed FFI concepts:

- `scan_host_security(host_id) -> FfiSecurityScanResult`
- `get_host_security_summary(host_id) -> FfiSecuritySummary`
- `build_patch_plan(host_id) -> FfiPatchPlan`
- `run_patch_plan(host_id, plan_id, dry_run) -> FfiPatchRunResult`

Remember that new FFI functions require regenerating the UniFFI bindings with `just mac-bindings`.

## Sales Message

The headline should be practical and direct:

> Your SSH client already knows your servers. Now it tells you which ones need security attention before they become incidents.

Supporting messages:

- See security updates before you start work.
- Know which SSH hosts need patching.
- Prioritize actively exploited vulnerabilities.
- Catch risky SSH server settings.
- Turn patching into a reviewable plan.
- Export proof that systems were checked and updated.

## Strategic Differentiation

Generic vulnerability scanners are noisy and external. Midnight SSH can be quieter and more useful because it operates from the developer's actual SSH workspace.

The differentiated angle is:

- SSH-native
- developer-friendly
- context-aware
- host and project aware
- patch-plan oriented
- low-friction for solo developers and small teams

The goal is not to replace enterprise vulnerability management platforms at first. The goal is to make every SSH session security-aware.
