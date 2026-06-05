# Security Patch Monitor Implementation Plan

## Objective

Implement Security Patch Monitor as an SSH-native, evidence-backed maintenance workflow for saved hosts. The first release should detect the remote OS and package manager, show update and reboot status, inspect risky SSH daemon settings, and render a per-host `Security` view without making system changes.

This plan turns the product proposal in `Security_Patch_Monitor.md` into concrete work for the current Midnight SSH codebase.

## Implementation Principles

- Start read-only. The first shippable version must not install, upgrade, restart, reload, or reboot anything.
- Use fixed command allowlists in Rust, following the existing Server Doctor collector pattern.
- Treat package-manager metadata as possibly stale and show that state explicitly.
- Prefer distro-native security signals over upstream version comparison.
- Avoid raw CVE alarm dumps. Every finding needs a reason, severity, and evidence source.
- Do not require `sudo` for the first slice. If permissions are limited, report the limitation.
- Keep external advisory lookups out of the MVP path. Add OSV/NVD/CISA correlation after local scanning is stable.
- Do not hand-edit UniFFI bindings. Any FFI change requires `just mac-bindings`.

## Current Repo Touchpoints

Existing pieces to reuse:

- `src/doctor.rs`: read-only collector allowlist, text caps, permission detection, command tests.
- `src/ffi.rs`: UniFFI exported functions and existing remote command execution patterns.
- `PgAgentApp/BridgeManager+ServerDoctor.swift`: Swift bridge wrapper pattern for feature-specific FFI calls.
- `PgAgentApp/ServerDoctorStore.swift`: async store pattern for preview, collection, generated report, and UI state.
- `PgAgentApp/ServerDoctorView.swift`: report-style diagnostic UI that can inform the security tab layout.
- `Sources/PgAgentMacOS/ServerDoctorModels.swift`: shared model style for Codable, Equatable, Sendable records.
- `Sources/PgAgentMacOS/ServerDoctorHeuristics.swift`: local heuristic report pattern.
- `Sources/PgAgentMacOS/FeatureFlags.swift`: add a feature flag before exposing UI broadly.
- `PgAgentApp/NetworkToolsWindow.swift` and `BridgeManager+Tools.swift`: patterns for network inventory and tool-specific queues.
- `Sources/PgAgentMacOS/SharedJSONFileStore.swift`: likely persistence helper for per-host scan cache and history.

Generated/build rules:

- New FFI types and functions go through `src/ffi.rs`.
- Regenerate Swift bindings with `just mac-bindings`.
- Do not hand-edit `bindings/midnight_ssh.swift`.
- Xcode project changes go through `project.yml` and `just mac-gen` if a new target or build setting is needed.

## Target First Slice

Build this first workflow:

```text
Connected host
-> Security tab
-> Preview read-only security checks
-> Run scan
-> Rust allowlisted package/SSH collectors
-> Swift parses and scores findings
-> Per-host summary, evidence, and host badge
```

First-slice checks:

- OS and distro detection.
- Package manager detection.
- Total updates available when supported.
- Security updates available when supported.
- Package metadata freshness when detectable.
- Reboot required detection.
- OpenSSH server version detection.
- Effective `sshd_config` inspection using `sshd -T` when available.
- Fallback inspection of readable SSH config files.
- Listening SSH port visibility from existing host/network collector output when available.

First-slice non-goals:

- Running package updates.
- Running `apt update`, `dnf makecache`, or equivalent metadata refresh automatically.
- Rebooting.
- Restarting `sshd`.
- Full CVE-to-package correlation.
- Container image scanning.
- Remote project dependency scanning.
- Scheduled background monitoring.
- Team fleet dashboard.

## Architecture

Use a separate Security Patch Monitor domain, but reuse the Server Doctor collector style.

Recommended files:

- `src/security_patch.rs`
- `Sources/PgAgentMacOS/SecurityPatchMonitorModels.swift`
- `Sources/PgAgentMacOS/SecurityPatchMonitorParsers.swift`
- `Sources/PgAgentMacOS/SecurityPatchMonitorScoring.swift`
- `PgAgentApp/BridgeManager+SecurityPatchMonitor.swift`
- `PgAgentApp/SecurityPatchMonitorStore.swift`
- `PgAgentApp/SecurityPatchMonitorView.swift`
- `Tests/PgAgentMacOSTests/SecurityPatchMonitorTests.swift`

Optional later files:

- `Sources/PgAgentMacOS/SecurityPatchMonitorPersistence.swift`
- `PgAgentApp/SecurityPatchMonitorHistoryStore.swift`
- `PgAgentApp/SecurityPatchMonitorFleetView.swift`
- `src/security_advisory.rs`

## Data Model

Create shared Swift models first. Keep the model useful for both macOS and iPadOS later.

Core enums:

```swift
public enum SecurityPatchPackageManager: String, Codable, Sendable, CaseIterable {
    case apt
    case dnf
    case yum
    case zypper
    case pacman
    case apk
    case homebrew
    case unknown
}

public enum SecurityPatchSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case critical
    case high
    case warning
    case info
    case unknown
}

public enum SecurityPatchFindingKind: String, Codable, Sendable, CaseIterable {
    case securityUpdatesAvailable
    case normalUpdatesAvailable
    case rebootRequired
    case unsupportedOs
    case stalePackageMetadata
    case riskySshdSetting
    case weakSshAlgorithm
    case permissionLimited
    case scannerUnsupported
}
```

Core records:

- `SecurityPatchScanRequest`
- `SecurityPatchScanPreview`
- `SecurityPatchPlannedCommand`
- `SecurityPatchCommandAudit`
- `SecurityPatchEvidence`
- `SecurityPatchOsInfo`
- `SecurityPatchPackageSummary`
- `SecurityPatchSshdSummary`
- `SecurityPatchFinding`
- `SecurityPatchScanResult`
- `SecurityPatchHostSummary`

Required `SecurityPatchScanResult` fields:

- `id`
- `connectionId`
- `hostLabel`
- `scannedAt`
- `osInfo`
- `packageSummary`
- `sshdSummary`
- `findings`
- `evidence`
- `commandAudits`
- `warnings`
- `overallSeverity`
- `summaryLabel`
- `isPermissionLimited`

Acceptance criteria:

- Models are `Codable`, `Equatable` where practical, and `Sendable`.
- JSON fixtures round-trip cleanly.
- Severity sorting is deterministic.
- Empty or unsupported scan results render as `unknown`, not `secure`.

## Rust Collector

Add `src/security_patch.rs` with a fixed command registry similar to `src/doctor.rs`.

Collector profiles:

- `Os`
- `PackageManager`
- `Reboot`
- `Sshd`
- `NetworkExposure`

Base OS commands:

```sh
if [ -r /etc/os-release ]; then cat /etc/os-release; fi
uname -a
command -v apt-get dnf yum zypper pacman apk brew 2>/dev/null || true
```

Reboot commands:

```sh
if [ -f /var/run/reboot-required ]; then cat /var/run/reboot-required; else echo 'reboot-required-file absent'; fi
if command -v needs-restarting >/dev/null 2>&1; then needs-restarting -r 2>&1; else echo 'needs-restarting unavailable'; fi
```

OpenSSH commands:

```sh
if command -v sshd >/dev/null 2>&1; then sshd -V 2>&1; else echo 'sshd unavailable'; fi
if command -v sshd >/dev/null 2>&1; then sshd -T 2>&1; else echo 'sshd unavailable'; fi
if [ -r /etc/ssh/sshd_config ]; then sed -n '1,260p' /etc/ssh/sshd_config; else echo 'sshd_config unreadable'; fi
```

Package-manager commands:

- `apt`: `apt-get -s upgrade`, `apt list --upgradable 2>/dev/null`, optional Ubuntu `/usr/lib/update-notifier/apt-check 2>&1` when present.
- `dnf`: `dnf check-update --security`, `dnf updateinfo list security`.
- `yum`: `yum check-update --security`, `yum updateinfo list security`.
- `zypper`: `zypper --non-interactive list-patches --category security`, `zypper --non-interactive patch-check`.
- `pacman`: `pacman -Qu`.
- `apk`: `apk version -l '<'`.
- `homebrew`: `brew outdated --json=v2`.

Important command behavior:

- Some package manager commands return non-zero when updates exist. The collector must not treat those as hard failures without parsing the command semantics.
- Do not run metadata-refresh commands automatically.
- Cap output per command and total scan output.
- Record permission-limited evidence instead of failing the whole scan.

Rust deliverables:

- FFI request/result mirror types.
- `rshell_security_patch_preview(request)`.
- `rshell_security_patch_scan(request)`.
- Unit tests that every command is allowed and read-only.
- Unit tests for command output capping and permission-limited detection.
- FFI integration test fixture where practical.

## Swift Parsing And Scoring

Keep parsing and scoring in Swift initially. Rust should collect bounded evidence; Swift can iterate faster on product behavior and tests.

Parsers:

- `/etc/os-release` parser.
- Package-manager detector.
- Apt output parser.
- DNF/YUM security output parser.
- Zypper patch output parser.
- Pacman update output parser.
- APK update output parser.
- Homebrew JSON parser.
- Reboot-required parser.
- `sshd -T` parser.
- OpenSSH version parser.

Scoring rules for MVP:

- `critical`: known dangerous SSH daemon setting such as `PermitRootLogin yes` plus password authentication enabled, or security updates detected for OpenSSH/OpenSSL/kernel/sudo when package names are known.
- `high`: any security updates available, reboot required after security update, weak SSH algorithms enabled.
- `warning`: normal updates available, package metadata stale, SSH config unreadable, scanner permission-limited.
- `info`: no updates detected with fresh-enough metadata and SSH checks completed.
- `unknown`: unsupported OS/package manager, no usable evidence, or stale metadata with no update signal.

Risky `sshd -T` settings:

- `permitrootlogin yes`
- `passwordauthentication yes`
- `kbdinteractiveauthentication yes`
- `permitemptypasswords yes`
- `allowtcpforwarding yes` as warning unless explicitly expected later
- legacy `ciphers`
- legacy `macs`
- legacy `kexalgorithms`
- high or missing `maxauthtries`

Do not overstate certainty:

- If package metadata is stale or cannot be checked, show `Unknown` or `Stale`, not `Secure`.
- If a package manager cannot distinguish security updates, show total updates and mark security count unsupported.
- If distro vendor data says patched, prefer that over upstream version comparison.

## Swift Bridge And Store

Bridge pattern:

- Add `BridgeManager+SecurityPatchMonitor.swift`.
- Use a dedicated dispatch queue, like `BridgeManager+ServerDoctor.swift` and `BridgeManager+Tools.swift`.
- Map FFI errors into `SecurityPatchBridgeError`.
- Convert FFI evidence and command audits into shared Swift models.

Store pattern:

- Add `SecurityPatchMonitorStore`.
- State:
  - `preview`
  - `result`
  - `errorMessage`
  - `isLoadingPreview`
  - `isScanning`
  - `selectedFindingId`
  - `selectedEvidenceId`
- Methods:
  - `loadPreview()`
  - `runScan()`
  - `reset()`
  - `finding(id:)`
  - `evidence(id:)`

Acceptance criteria:

- Long-running scans never block the main thread.
- Result state is stable if the user switches tabs while a scan is running.
- Errors render as actionable messages.
- Permission limitations do not hide partial findings.

## UI Plan

Add a `Security` tab for an active SSH connection.

Sections:

- Summary
- Updates
- SSH Hardening
- Evidence
- Commands Run

Summary content:

- overall severity badge
- scan timestamp
- package manager
- OS/distro
- security update count
- normal update count
- reboot status
- SSH hardening status

Update section:

- package manager detected
- security updates count
- total updates count
- important packages list when parsed
- metadata freshness
- unsupported limitations

SSH hardening section:

- OpenSSH version
- risky settings list
- weak algorithm findings
- config/effective-setting evidence
- permission warnings

Commands Run section:

- display command allowlist audit
- exit status
- duration
- truncation state
- permission-limited state

Host-level badges:

- `Secure`
- `Security Updates`
- `Updates Available`
- `Critical`
- `Reboot Needed`
- `Unknown`
- `Unsupported`

UI acceptance criteria:

- A host is not shown as secure unless the scan completed with usable package and SSH evidence.
- Every finding links to evidence.
- The user can copy evidence and commands.
- The scan can be re-run manually.
- Empty, unsupported, permission-limited, stale, healthy, and critical states all have distinct UI.

## Persistence

MVP persistence:

- Cache the latest scan result per connection.
- Store enough data for host badges after app restart.
- Keep raw command output local.
- Do not sync scan evidence through iCloud in the first version.

Recommended storage:

- `SecurityPatchMonitorHistoryStore` using `SharedJSONFileStore` if it fits current patterns.
- One compact summary index for host list badges.
- Optional detail files keyed by scan ID for full evidence.

Retention:

- Latest result per host by default.
- Keep last 10 scans per host only after history UI exists.
- Add a setting later for evidence retention.

## Patch Plan Phase

Patch planning should be a second shippable phase after read-only scanning.

Plan generation:

- Build distro-specific proposed commands.
- Show exactly what will run.
- Support dry-run where package manager supports it.
- Require explicit confirmation before any mutating command.

Mutating commands should remain out of the first release:

- `apt upgrade`
- `dnf upgrade`
- `yum update`
- `zypper patch`
- `pacman -Syu`
- `apk upgrade`
- `brew upgrade`
- `systemctl restart sshd`
- `reboot`

When this phase starts, add a separate command risk model:

- `readOnly`
- `metadataRefresh`
- `packageUpgrade`
- `serviceRestart`
- `reboot`

The UI must separate dry-run, package metadata refresh, upgrade execution, and reboot.

## Milestones

### Milestone 0: Design Lock

Deliverables:

- Add this implementation plan.
- Decide whether first UI entry point is only active-host tab or also command palette.
- Decide whether scan results are macOS-only in v1 or shared with iPadOS models from day one.
- Add `FeatureFlags.securityPatchMonitor`, default enabled in Debug and disabled in Release.

### Milestone 1: Shared Models And Fixtures

Deliverables:

- `SecurityPatchMonitorModels.swift`.
- JSON fixture for healthy host.
- JSON fixture for security-updates host.
- JSON fixture for unsupported host.
- Unit tests for Codable round trips and severity sorting.

Acceptance:

- Pure Swift package tests pass.
- No UI or FFI dependency in the model tests.

### Milestone 2: Rust Read-only Collector

Deliverables:

- `src/security_patch.rs`.
- FFI types in `src/ffi.rs`.
- Preview and scan FFI functions.
- Rust unit tests for command allowlist and output capping.
- Regenerated UniFFI bindings.

Acceptance:

- `just test-rust` passes.
- `bindings/midnight_ssh.swift` is regenerated, not hand-edited.
- Scan returns partial evidence if some commands fail.

### Milestone 3: Swift Bridge And Parsers

Deliverables:

- `BridgeManager+SecurityPatchMonitor.swift`.
- `SecurityPatchMonitorParsers.swift`.
- Parser unit tests using real captured command-output fixtures.

Acceptance:

- Parser tests cover apt, dnf/yum, zypper, pacman, apk, Homebrew, `sshd -T`, and reboot detection where fixtures exist.
- Package manager commands with update-exists exit codes are treated correctly.

### Milestone 4: Scoring And Summary

Deliverables:

- `SecurityPatchMonitorScoring.swift`.
- Host summary derivation.
- Unit tests for severity and badge derivation.

Acceptance:

- Unsupported does not become secure.
- Stale metadata does not become secure.
- Security updates rank above normal updates.
- OpenSSH/OpenSSL/kernel/sudo package updates receive elevated severity when package names are available.

### Milestone 5: Active Host Security UI

Deliverables:

- `SecurityPatchMonitorStore.swift`.
- `SecurityPatchMonitorView.swift`.
- Active-host tab integration.
- Command palette action if low-risk.

Acceptance:

- Scan runs from the UI.
- Loading, error, unsupported, healthy, warning, and critical states render.
- Findings link to evidence.
- Commands-run audit is visible.

### Milestone 6: Latest Result Cache And Host Badges

Deliverables:

- Latest-result persistence.
- Host summary cache.
- Connection list badge integration.

Acceptance:

- Badges survive app restart.
- Stale scan state is visible.
- Cache failures do not break connections.

### Milestone 7: SSH Hardening Polish

Deliverables:

- Better algorithm classification.
- Config readability warnings.
- Safer wording around SSH forwarding settings.
- Tests for risky `sshd -T` combinations.

Acceptance:

- Root login plus password auth escalates severity.
- Password auth alone is warning or high depending on context.
- Forwarding warnings are factual and not overclassified.

### Milestone 8: Advisory Correlation

Deliverables:

- Optional local advisory client abstraction.
- CISA KEV matching by CVE where package manager output exposes CVEs.
- NVD/OSV integration only where package identity and ecosystem mapping are trustworthy.
- Rate-limit and cache handling.

Acceptance:

- External lookups are opt-in or clearly disclosed.
- No raw host inventory is sent unless the user enables it.
- Results preserve source attribution.
- Vendor package security status remains primary for distro packages.

### Milestone 9: Patch Plan

Deliverables:

- Reviewable patch-plan model.
- Dry-run support.
- Explicit mutating command confirmation.
- Transcript capture.
- Reboot detection after patch run.

Acceptance:

- No mutating command runs without a confirmation sheet.
- Dry-run and real run are visually distinct.
- The app records command, start time, exit status, output, and resulting scan summary.

## Testing Strategy

Rust tests:

- Collector command allowlist.
- Blocked mutating command detection.
- Output truncation.
- Permission-limited output detection.
- FFI conversion smoke tests.

Swift model tests:

- Codable round trips.
- Severity ordering.
- Badge derivation.
- Empty and unsupported scan behavior.

Swift parser tests:

- OS release parsing.
- Apt simulated output.
- DNF/YUM security output.
- Zypper patch output.
- Pacman update output.
- APK update output.
- Homebrew JSON output.
- Reboot-required output.
- `sshd -T` risky settings.

UI tests:

- Empty scan state.
- Running scan state.
- Healthy result.
- Security updates result.
- Permission-limited result.
- Unsupported package manager result.

Manual test matrix:

- Ubuntu LTS with `apt`.
- Debian with `apt`.
- Fedora with `dnf`.
- RHEL-like host with `yum` or `dnf`.
- openSUSE with `zypper`.
- Arch with `pacman`.
- Alpine with `apk`.
- macOS/Homebrew host if remote shell access is relevant.

## Security And Privacy Risks

Risk: false positives from upstream version comparison.

Mitigation: use distro-native security update status first. Treat NVD/OSV matching as later enrichment, not the primary OS package truth.

Risk: accidentally mutating a host.

Mitigation: MVP commands are read-only and fixed in Rust. Metadata refresh and package upgrades are separate later phases with explicit risk labels.

Risk: leaking package inventory to external advisory services.

Mitigation: MVP uses local command output only. Later advisory correlation must be disclosed, cached, and optionally disabled.

Risk: overstating secure state.

Mitigation: require fresh package evidence and SSH evidence before showing `Secure`. Otherwise show `Unknown`, `Unsupported`, or `Stale`.

Risk: `sshd -T` output may differ from match blocks for specific users, hosts, or addresses.

Mitigation: label it as effective default daemon config. Add advanced match-context scanning later if needed.

## Open Decisions

- Should the first UI entry live in the existing inspector, a new tab, or both?
- Should scan summaries appear in the main connection list immediately or after persistence lands?
- Should iPadOS expose read-only scan results in v1, or only consume shared models for future parity?
- Should package metadata refresh be offered in v1 as a separate explicit action?
- Should Team/Business scheduled monitoring depend on a future helper process, or only run while the app is open?

## Recommended First PR Sequence

1. Add feature flag, shared models, fixtures, and tests.
2. Add Rust collector and FFI preview/scan with generated bindings.
3. Add Swift bridge, parsers, and parser tests.
4. Add scoring and latest host summary derivation.
5. Add active-host `Security` view behind the feature flag.
6. Add latest-result cache and connection-list badges.

This sequence keeps each PR reviewable and avoids mixing FFI, parser logic, persistence, and UI in one large change.
