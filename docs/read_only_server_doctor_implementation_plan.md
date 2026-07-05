# Read-only Server Doctor Implementation Plan

## Objective

Implement Read-only Server Doctor as a safe, evidence-linked diagnostic workflow for connected SSH hosts. The first release should collect bounded read-only server facts, redact sensitive content locally, ask an LLM for structured findings, validate the model output, and render a native report with evidence links.

This plan turns the product spec in `read_only_server_doctor.md` into concrete work for the current Midnight SSH codebase.

## Implementation Principles

- The collector must be deterministic. The LLM never chooses shell commands.
- Swift sends collector scopes and options. Rust maps those scopes to allowlisted read-only commands.
- All raw server content is untrusted. Logs and config files may contain prompt injection.
- Redaction happens before any external model request.
- Every model finding must cite collected evidence IDs.
- Read-only mode renders no action button that mutates server state.
- The feature should reuse existing app surfaces: terminal, log panel, file browser, system monitor, diagnostics bundle, and command palette.

## Current Repo Touchpoints

Existing pieces to reuse:

- `PgAgentShared/BridgeManager.swift`: queue pattern for FFI calls and host command work.
- `PgAgentApp/BridgeManager+Tools.swift`: extension pattern for feature-specific bridge wrappers.
- `src/ffi.rs`: UniFFI exported types and functions.
- `src/bridge.rs`: global Tokio runtime and connection manager.
- `PgAgentApp/ServiceMonitorViews.swift`: `RemoteCommandRunner`, service diagnostics, parsers, and many useful shell snippets.
- `PgAgentApp/SystemMonitorView.swift`: deep-dive diagnostics and service-specific shell collection.
- `PgAgentApp/LogPanel.swift`: natural entry point for `Explain selected logs`.
- `PgAgentApp/SafeConfigSave.swift`: existing safety posture around config files.
- `PgAgentMobile/MobileServerDoctor.swift`: existing heuristic mobile doctor, useful as a first source of thresholds and categories.
- `PgAgentApp/DiagnosticsBundle.swift`: existing redaction patterns and diagnostics export behavior.
- `Sources/PgAgentMacOS/SharedJSONFileStore.swift`: persistence helper for shared Codable stores.
- `Sources/PgAgentMacOS/FeatureFlags.swift`: runtime feature gating.
- `PgAgentApp/SettingsView.swift`: privacy settings surface.

Generated files and build rules:

- Any FFI change requires `just mac-bindings`.
- Do not hand-edit `bindings/midnight_ssh.swift`.
- The Xcode project is generated from `project.yml`; new source files under `PgAgentApp/` and `Sources/PgAgentMacOS/` are picked up by folder references, but FFI binding regeneration is still required.

## Target First Slice

Build this exact first workflow:

```text
Host sidebar or command palette
-> Doctor: Diagnose Host
-> collection preview
-> Rust read-only collection for broad host + systemd + nginx + disk
-> Swift redaction
-> LLM structured report
-> validated findings UI
-> local evidence viewer and commands-run audit
```

The first slice intentionally excludes:

- Automated fixes.
- Report-aware chat.
- Arbitrary model-suggested commands.
- Full Docker/Postgres/firewall coverage.
- iPadOS parity, except for shared models that make parity easy later.

## Milestone 0: Foundation Decisions

### Decisions To Lock

1. Model provider for phase 1:
   - Recommended: provider abstraction with a disabled/mock provider and one HTTP provider behind settings.
   - Do not hardcode provider details into views.

2. Feature gate:
   - Add `FeatureFlags.serverDoctor`.
   - Keep enabled in Debug and disabled in Release until privacy and redaction tests are in place.

3. Entitlement or license:
   - Do not add license gating in the first implementation unless product requires it.
   - If needed later, add `AppFeature.serverDoctor` and gate from `EntitlementsStore`.

4. Persistence:
   - Store report metadata locally.
   - Store raw evidence separately with retention controls.
   - First slice can keep raw evidence in app support for 7 days by default.

5. LLM execution location:
   - Keep model/provider calls in Swift.
   - Keep Rust focused on SSH collection and safety enforcement.

### Deliverables

- Short engineering note at the top of the implementation PR describing these locked decisions.
- Feature flag added but no visible UI until core flow works.

## Milestone 1: Shared Models

### Files

Create:

- `Sources/PgAgentMacOS/ServerDoctorModels.swift`
- `Tests/PgAgentMacOSTests/ServerDoctorModelsTests.swift`

Update:

- `Sources/PgAgentMacOS/FeatureFlags.swift`

### Model Types

Add Codable, Equatable where practical, Sendable models:

```swift
public enum ServerDoctorScope: String, Codable, Sendable {
    case broadHost
    case selectedService
    case selectedLog
    case selectedConfig
}

public enum ServerDoctorCollectorProfile: String, Codable, CaseIterable, Sendable {
    case host
    case systemd
    case nginx
    case disk
}

public enum ServerDoctorSeverity: String, Codable, CaseIterable, Sendable {
    case critical
    case high
    case warning
    case info
    case unknown
}

public enum ServerDoctorConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public enum ServerDoctorEvidenceKind: String, Codable, CaseIterable, Sendable {
    case commandOutput
    case logExcerpt
    case configExcerpt
    case fileMetadata
    case metricSample
    case serviceStatus
}
```

Core records:

- `ServerDoctorCollectionRequest`
- `ServerDoctorCollectionPreview`
- `ServerDoctorCollectionBundle`
- `ServerDoctorCommandAudit`
- `ServerDoctorEvidence`
- `ServerDoctorFinding`
- `ServerDoctorSuggestedAction`
- `ServerDoctorReport`
- `ServerDoctorReportValidationResult`
- `ServerDoctorPrivacyPreset`
- `ServerDoctorRedactionSummary`
- `ServerDoctorProviderMetadata`

### Required Fields

`ServerDoctorEvidence`:

- `id`
- `kind`
- `title`
- `source`
- `collectedAt`
- `risk`
- `exitStatus`
- `excerpt`
- `redactedExcerpt`
- `rawRef`
- `byteCount`
- `lineCount`
- `permissionLimited`

`ServerDoctorCommandAudit`:

- `id`
- `collectorId`
- `displayName`
- `command`
- `startedAt`
- `durationMs`
- `exitStatus`
- `stdoutBytes`
- `stderrBytes`
- `truncated`
- `permissionLimited`
- `readOnlyRisk`

`ServerDoctorFinding`:

- `id`
- `title`
- `summary`
- `severity`
- `confidence`
- `affectedSubsystem`
- `affectedService`
- `evidenceIds`
- `safeNextSteps`
- `unsafeActionsToAvoid`
- `explanation`

### Tests

Add tests for:

- Report Codable round trip.
- Evidence IDs survive round trip.
- Finding with missing evidence IDs fails validation.
- Empty report is valid only if it has a clear no-findings state.
- Privacy presets encode stable raw values.

### Acceptance Criteria

- Models build in the pure Swift package.
- Unit tests run with `just test-rust` unaffected and Swift model tests pass under `just mac-test` or targeted xcodebuild.

## Milestone 2: Rust Collector Skeleton

### Files

Create:

- `src/doctor.rs`

Update:

- `src/lib.rs`
- `src/ffi.rs`

Regenerate:

- `bindings/midnight_ssh.swift`
- `bindings/midnight_sshFFI.h`
- `bindings/module.modulemap` if changed by the binding recipe.

### Rust Module Responsibilities

`src/doctor.rs` should own:

- Collector profile enum.
- Allowlisted command definitions.
- Command execution with timeout.
- Output byte and line caps.
- Command audit records.
- Evidence record creation.
- Basic deterministic parsing for first-slice findings.
- Permission-limited and command-missing classification.

Keep provider calls out of Rust.

### FFI Types

Add UniFFI records/enums in `src/ffi.rs`, mapping to internal Rust models:

```rust
#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiDoctorCollectorProfile {
    Host,
    Systemd,
    Nginx,
    Disk,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCollectRequest {
    pub connection_id: String,
    pub profiles: Vec<FfiDoctorCollectorProfile>,
    pub service_name: Option<String>,
    pub max_total_bytes: u32,
    pub per_command_timeout_ms: u32,
    pub log_line_limit: u32,
}
```

Return:

- `FfiDoctorCollectionBundle`
- `FfiDoctorEvidence`
- `FfiDoctorCommandAudit`
- `FfiDoctorWarning`

Errors:

- `FfiDoctorError::ConnectionNotFound`
- `FfiDoctorError::NotSshConnection`
- `FfiDoctorError::InvalidRequest`
- `FfiDoctorError::CollectorFailed`
- `FfiDoctorError::Internal`

### FFI Functions

Add:

```rust
#[uniffi::export]
pub fn rshell_doctor_preview(request: FfiDoctorCollectRequest) -> Result<FfiDoctorCollectionPreview, FfiDoctorError>

#[uniffi::export]
pub fn rshell_doctor_collect(request: FfiDoctorCollectRequest) -> Result<FfiDoctorCollectionBundle, FfiDoctorError>
```

`preview` should not touch the server. It should return the planned commands, files, caps, and privacy notes based on the requested profiles.

`collect` should run only known commands from the profile allowlist.

### Command Execution

Use the existing connection manager in `MacOsBridge::global()`.

For each command:

- Run with `execute_command_full` if available so exit status is captured.
- Wrap with `tokio::time::timeout`.
- Truncate stdout/stderr separately.
- Record truncation.
- Convert output into one or more evidence records.

If `execute_command_full` cannot be used for all target commands, return a command audit with unknown exit status instead of wrapping commands in mutable shell scripts.

### First-Slice Command Allowlist

Host:

- `uname -a`
- `uptime`
- `df -hP`
- `df -iP`
- `free -m` guarded by `command -v free`
- `ps -eo pid,ppid,user,pcpu,pmem,comm,args --sort=-pcpu | head -25`
- `ss -ltnp` guarded by `command -v ss`

Systemd:

- `systemctl --no-pager --failed`
- `systemctl --no-pager list-units --state=failed`
- `journalctl -p warning..alert -n 300 --no-pager`

nginx:

- `command -v nginx`
- `nginx -t`
- `systemctl --no-pager status nginx`
- `journalctl -u nginx -n 300 --no-pager`
- `tail -n 300 /var/log/nginx/error.log`

Disk:

- `df -hP`
- `df -iP`
- `du -xhd1 /var/log 2>/dev/null | sort -hr | head -30`
- `journalctl --disk-usage`

All command strings should be constants. No string interpolation except for validated service names in later milestones.

### Read-only Guard

Even with an allowlist, add a guard that rejects commands containing obvious mutation tokens unless explicitly marked safe:

- `rm`
- `mv`
- `cp`
- `chmod`
- `chown`
- `kill`
- `systemctl restart`
- `systemctl reload`
- `systemctl start`
- `systemctl stop`
- package manager install/remove/upgrade verbs
- `>`
- `>>`
- `tee`

This guard should be defense-in-depth. The real safety comes from only using constants.

### Rust Tests

Add tests for:

- `preview` returns expected command list for profiles.
- read-only guard rejects mutation-like commands.
- output truncation preserves metadata.
- command-to-evidence mapping creates stable IDs.
- no first-slice command contains mutation tokens.

If SSH execution cannot be integration-tested locally, keep collector unit tests pure and add a thin FFI construction test.

### Acceptance Criteria

- `cargo test` passes.
- `just mac-bindings` regenerates Swift bindings.
- Swift app compiles against the new FFI types.

## Milestone 3: Swift Bridge Wrapper

### Files

Create:

- `PgAgentApp/BridgeManager+ServerDoctor.swift`

### Responsibilities

- Convert shared Swift request models into FFI request models.
- Convert FFI bundles into shared Swift collection models.
- Map `FfiDoctorError` into localized Swift errors.
- Run on a dedicated concurrent utility queue, following `BridgeManager+Tools.swift`.

### API Shape

```swift
extension BridgeManager {
    func serverDoctorPreview(
        request: ServerDoctorCollectionRequest
    ) async throws -> ServerDoctorCollectionPreview

    func serverDoctorCollect(
        request: ServerDoctorCollectionRequest
    ) async throws -> ServerDoctorCollectionBundle
}
```

### Error Mapping

Add `ServerDoctorBridgeError`:

- `connectionNotFound`
- `notSshConnection`
- `invalidRequest`
- `collectorFailed`
- `internalFailure`

### Tests

If app tests can load FFI:

- Validate conversion between Swift request and FFI request.
- Validate conversion from synthetic FFI bundle to Swift bundle.

If not, keep converter helpers pure enough to test in `PgAgentMacOSTests`.

### Acceptance Criteria

- The app target builds.
- Preview and collect wrappers can be called from a temporary debug action without blocking the main thread.

## Milestone 4: Redaction Engine

### Files

Create:

- `Sources/PgAgentMacOS/ServerDoctorRedactor.swift`
- `Tests/PgAgentMacOSTests/ServerDoctorRedactorTests.swift`

Optionally refactor:

- Share patterns from `PgAgentApp/DiagnosticsBundle.swift`.
- Share patterns from `PgAgentMobile/MobileDiagnosticsBundle.swift`.

### Redaction Requirements

Always redact:

- `password=...`
- `passphrase=...`
- `secret=...`
- `token=...`
- `authorization: ...`
- private key blocks
- database URLs with credentials
- AWS-like access keys where detected
- `.env` style values for sensitive keys

Balanced preset keeps:

- service names
- ports
- paths
- hostnames
- public error messages

Strict preset additionally redacts:

- IP addresses
- hostnames
- domain names
- usernames
- email addresses

### Implementation Notes

The redactor should return both text and metadata:

```swift
public struct ServerDoctorRedactionResult: Codable, Equatable, Sendable {
    public var text: String
    public var replacementCount: Int
    public var categories: [String: Int]
}
```

Apply redaction to:

- evidence excerpt
- command output excerpts
- report prompt payload
- stored redacted report

Do not overwrite raw local evidence. Store raw and redacted versions separately.

### Tests

Add tests for:

- private key block redaction.
- URL credential redaction.
- authorization header redaction.
- token-like key-value redaction.
- strict IP/domain/email redaction.
- non-sensitive nginx path survives in Balanced mode.

### Acceptance Criteria

- Redactor tests pass.
- The first LLM prompt path only uses redacted evidence.

## Milestone 5: Report Validation and Deterministic Fallback Findings

### Files

Create:

- `Sources/PgAgentMacOS/ServerDoctorReportValidator.swift`
- `Sources/PgAgentMacOS/ServerDoctorHeuristics.swift`
- `Tests/PgAgentMacOSTests/ServerDoctorReportValidatorTests.swift`
- `Tests/PgAgentMacOSTests/ServerDoctorHeuristicsTests.swift`

### Validator Rules

Reject or downgrade model output when:

- Finding has no evidence IDs.
- Evidence ID does not exist.
- Finding claims a mutation happened.
- Suggested action has a mutating kind in read-only mode.
- Severity raw value is unknown.
- Model response is not valid JSON.
- Report is too large for local storage limits.

### Fallback Findings

Generate deterministic findings before or after model analysis:

- Disk usage above threshold.
- Inode usage above threshold.
- Failed systemd units present.
- `nginx -t` failed.
- nginx error log has permission denied, missing cert, bind failed, or upstream refused.
- Journal contains OOM kill signals.
- Command permission denied or missing tool warnings.

Fallback findings ensure the feature is useful when:

- model is disabled.
- provider request fails.
- model output fails validation.

### Acceptance Criteria

- With model disabled, Doctor still returns a useful structured report.
- Invalid model output does not crash or render unsafe actions.
- Missing evidence citation is caught in tests.

## Milestone 6: LLM Provider Abstraction

### Files

Create:

- `PgAgentApp/ServerDoctorLLMProvider.swift`
- `PgAgentApp/ServerDoctorPromptBuilder.swift`
- `PgAgentApp/ServerDoctorReportGenerator.swift`

Optional later:

- `PgAgentApp/ServerDoctorOpenAIProvider.swift`
- `PgAgentApp/ServerDoctorLocalProvider.swift`

### Protocol

```swift
protocol ServerDoctorLLMProviding: Sendable {
    var metadata: ServerDoctorProviderMetadata { get }

    func generateReport(
        prompt: ServerDoctorPromptPayload
    ) async throws -> ServerDoctorLLMRawResponse
}
```

### First Implementation

Start with:

- `DisabledServerDoctorLLMProvider`: always returns no model report.
- `MockServerDoctorLLMProvider`: deterministic test provider.

Then add an HTTP provider behind settings and explicit user consent.

### Prompt Builder

The prompt should include:

- role: read-only diagnostic interpreter.
- scope and profiles.
- redacted evidence graph.
- command audit summary.
- explicit prompt-injection warning.
- strict JSON schema.
- forbidden claims and forbidden action verbs.

Do not include:

- raw secrets.
- private keys.
- full unbounded logs.
- command execution permissions.

### Provider Settings

Add settings model:

- provider kind: disabled, custom HTTP, future local.
- endpoint URL.
- model name.
- API key keychain reference.
- privacy preset.
- raw evidence retention.
- external model calls allowed.

Keychain storage should follow existing credential patterns, not UserDefaults.

### Acceptance Criteria

- With provider disabled, heuristic-only report works.
- With mock provider, UI displays validated model findings.
- External provider cannot be called before explicit user consent.

## Milestone 7: Collection Preview UI

### Files

Create:

- `PgAgentApp/ServerDoctorCollectionPreview.swift`
- `PgAgentApp/ServerDoctorStore.swift`

### Store State

`ServerDoctorStore` should be `@MainActor ObservableObject`.

State:

- selected host/profile metadata.
- request.
- preview.
- collection progress.
- raw bundle.
- redacted bundle.
- report.
- errors.
- provider status.

Methods:

- `loadPreview()`
- `startCollection()`
- `cancelCollection()`
- `generateReport()`
- `openEvidence(_:)`
- `rerun()`

### Preview Sheet

Show:

- profiles selected.
- exact commands planned.
- expected file/log sources.
- caps: bytes, lines, timeout.
- privacy preset.
- model provider state.
- sudo policy: no interactive sudo.
- storage retention.

Controls:

- `Start Diagnosis`
- `Customize`
- `Cancel`

For first slice, `Customize` can be limited to profile toggles:

- Host basics
- systemd
- nginx
- disk

### Acceptance Criteria

- User sees exactly what will run before collection.
- User can cancel before any remote command runs.
- Preview uses `rshell_doctor_preview`; it is not hand-built separately in Swift.

## Milestone 8: Report UI

### Files

Create:

- `PgAgentApp/ServerDoctorView.swift`
- `PgAgentApp/ServerDoctorReportView.swift`
- `PgAgentApp/ServerDoctorFindingList.swift`
- `PgAgentApp/ServerDoctorFindingDetail.swift`
- `PgAgentApp/ServerDoctorEvidenceView.swift`
- `PgAgentApp/ServerDoctorCommandsRunView.swift`

### Layout

macOS:

- Three-column split layout.
- Left: findings list.
- Center: selected finding detail.
- Right: evidence inspector.

iPad later:

- Navigation stack.
- Summary screen to finding detail to evidence detail.

### Summary Header

Show:

- host label.
- collected timestamp.
- scope.
- overall severity.
- provider.
- privacy preset.
- number of findings.
- permission-limited warning count.

### Finding Row

Show:

- severity icon.
- title.
- affected subsystem.
- confidence.
- evidence count.

### Finding Detail

Show:

- summary.
- explanation.
- evidence citations.
- safe next steps.
- what to avoid.
- confidence reason.

No mutating buttons in phase 1.

Allowed buttons:

- `Open Evidence`
- `Open Log`
- `Open Config`
- `Copy Evidence`
- `Save to Incident Report` if available
- `Draft Fix Plan` disabled or unavailable until later phase

### Evidence View

Show:

- raw local excerpt.
- redacted model excerpt.
- source command/path.
- timestamp.
- exit status.
- truncation state.
- permission state.

### Commands Run

Audit table:

- command.
- duration.
- exit.
- bytes.
- truncated.
- permission limited.

### Acceptance Criteria

- Report is usable without a chat surface.
- Every rendered finding has clickable evidence.
- Commands-run audit is always visible.
- Unknown/partial collection states are clear.

## Milestone 9: App Entry Points

### Files To Update

- `PgAgentApp/SidebarView.swift`
- `PgAgentApp/CommandPaletteView.swift`
- `PgAgentApp/SystemMonitorView.swift`
- `PgAgentApp/LogPanel.swift`
- `PgAgentApp/FileEditView.swift`

### First-Slice Entry Points

Implement now:

- Sidebar context action: `Diagnose Host`.
- Command palette action: `Doctor: Diagnose Host`.
- System monitor toolbar action: `Diagnose Host`.

Defer:

- `Explain selected logs`.
- `Explain current config`.
- Service-specific contextual Doctor actions.

### Routing

Use existing window/sheet conventions. Recommended:

- On macOS, open `ServerDoctorView` in a separate utility window or sheet tied to the selected connection.
- Avoid embedding inside existing monitor panels for the first slice.

### Acceptance Criteria

- A connected host can launch Doctor from at least two entry points.
- Feature flag hides all entry points when disabled.

## Milestone 10: Persistence and Retention

### Files

Create:

- `Sources/PgAgentMacOS/ServerDoctorReportStoreModels.swift`
- `PgAgentApp/ServerDoctorReportStore.swift`

### Storage Layout

Use Application Support:

```text
Application Support/com.mc-ssh/server_doctor/
  reports.json
  evidence/
    <report-id>/
      raw/
      redacted/
```

`reports.json` stores metadata and redacted findings. Raw evidence files are stored separately so retention can delete them without deleting the report.

### Retention

First slice:

- Default raw evidence retention: 7 days.
- Keep redacted report until manually deleted.
- Add cleanup on app launch or store initialization.

Settings later:

- until app quits.
- 7 days.
- 30 days.
- manually delete.

### Acceptance Criteria

- Reports survive app restart.
- Raw evidence can be deleted while report remains.
- Cleanup does not delete active in-memory report.

## Milestone 11: Privacy Settings and Consent

### Files To Update

- `PgAgentApp/SettingsView.swift`
- `PgAgentShared/KeychainManager.swift` if adding provider API key storage helpers.

### Settings Section

Add to Privacy tab:

- Server Doctor enabled.
- Model provider.
- Privacy preset.
- External model calls toggle.
- Raw evidence retention.
- Clear Doctor reports.
- Clear raw evidence.

### First External Model Consent

Before first external provider call, show:

- provider name and endpoint.
- data categories sent.
- redaction preset.
- reminder that raw server evidence may contain sensitive operational data.
- link/button to preview redacted payload.

Store consent in UserDefaults with provider identity and timestamp. If provider endpoint changes, require consent again.

### Acceptance Criteria

- External model calls cannot happen by accident.
- User can run local heuristic-only Doctor with no provider configured.
- User can inspect redacted payload before sending.

## Milestone 12: Integration With Existing Surfaces

### Log Panel

After first slice:

- Add `Summarize Visible Logs`.
- Use selected log entries from `MonitorPollingManager.shared.logEntries`.
- Build a `selectedLog` scope without running broad host collectors.

### File Editor

After first slice:

- Add `Explain Config`.
- Use current file content and path.
- Include nearby include/import context only if already loaded or safely readable.

### System Monitor

Add:

- `Diagnose This Finding` for CPU, memory, disk, systemd, UFW drill-downs.
- Pass current monitor snapshot as evidence to avoid rerunning everything.

### Diagnostics Bundle

Add:

- Include redacted Server Doctor report in diagnostics export.
- Include raw evidence only if user explicitly opts in.

### Mobile Doctor Alignment

Later:

- Move shared findings model into `Sources/PgAgentMacOS`.
- Adapt `PgAgentMobile/MobileServerDoctor.swift` to produce `ServerDoctorReport`.
- Keep mobile UI touch-first but use the same evidence and validation model.

## Milestone 13: Tests and Quality Gates

### Rust Tests

Run:

```bash
just test-rust
```

Add:

- collector allowlist tests.
- read-only guard tests.
- truncation tests.
- command audit construction tests.
- FFI request validation tests.

### Swift Tests

Run targeted Swift tests if full `just mac-test` is too slow during development, then run full before merge.

Add:

- model Codable tests.
- redactor tests.
- report validator tests.
- prompt builder snapshot tests.
- mock provider report generation tests.
- store retention tests.

### App-Level Smoke

Manual debug smoke:

1. Connect to a Linux host.
2. Launch Doctor from sidebar.
3. Preview appears before commands run.
4. Collection completes.
5. Report appears with at least one finding or no-finding state.
6. Commands-run audit lists commands.
7. Evidence opens.
8. Feature works with provider disabled.
9. Feature works with mock provider.
10. Permission-limited commands produce warnings, not failure.

### Security Tests

Add redaction fixtures:

- `.env` file.
- nginx log with token query string.
- authorization header.
- fake private key block.
- database URL.
- prompt-injection log line.

Validate:

- redacted payload contains no secret fixture values.
- prompt-injection line remains evidence text, not instruction.
- model output with mutating action is rejected or downgraded.

## Milestone 14: First Beta Cut

### Beta Feature Scope

Ship behind `FeatureFlags.serverDoctor` with:

- broad host collector.
- systemd collector.
- nginx collector.
- disk collector.
- local redaction.
- provider disabled/mock path.
- optional external provider if consent and settings are complete.
- report UI.
- evidence UI.
- commands-run audit.
- report persistence.

Do not ship:

- automated fixes.
- mutating follow-up actions.
- unrestricted chat.
- model-generated command execution.

### Beta Exit Criteria

- No known redaction leak from test fixtures.
- No mutating command in collector allowlist.
- All model findings are evidence validated.
- Permission-limited reports remain readable.
- App does not freeze during collection.
- FFI checksums match regenerated bindings.
- Feature flag can hide all UI entry points for release builds.

## Task Breakdown

### Task 1: Add Feature Flag

Files:

- `Sources/PgAgentMacOS/FeatureFlags.swift`

Steps:

1. Add `case serverDoctor = "Server Doctor"`.
2. Return `false` in Release switch.
3. Add UI guards only after entry points exist.

Verification:

- Build pure Swift package or app target.

### Task 2: Add Shared Models

Files:

- `Sources/PgAgentMacOS/ServerDoctorModels.swift`
- `Tests/PgAgentMacOSTests/ServerDoctorModelsTests.swift`

Steps:

1. Define enums.
2. Define collection request/preview/bundle.
3. Define evidence, command audit, finding, report.
4. Add validation conveniences but keep heavy validator separate.
5. Add Codable tests.

Verification:

- Swift unit tests compile.

### Task 3: Add Rust Doctor Module

Files:

- `src/doctor.rs`
- `src/lib.rs`
- `src/ffi.rs`

Steps:

1. Add internal profile enum and command definition struct.
2. Add profile-to-command mapping.
3. Add read-only guard.
4. Add preview builder.
5. Add collection runner.
6. Add output cap helper.
7. Add evidence ID helper.
8. Add Rust tests.

Verification:

- `cargo test`.

### Task 4: Export FFI

Files:

- `src/ffi.rs`
- `bindings/*`

Steps:

1. Add UniFFI records/enums/errors.
2. Add `rshell_doctor_preview`.
3. Add `rshell_doctor_collect`.
4. Run `just mac-bindings`.
5. Verify generated Swift compiles.

Verification:

- `just mac-bindings`.
- App build or targeted compile.

### Task 5: Add Swift Bridge

Files:

- `PgAgentApp/BridgeManager+ServerDoctor.swift`

Steps:

1. Add dedicated queue.
2. Add preview wrapper.
3. Add collect wrapper.
4. Add FFI-to-shared model mappers.
5. Add typed Swift error.

Verification:

- Temporary debug call returns preview.

### Task 6: Add Redactor

Files:

- `Sources/PgAgentMacOS/ServerDoctorRedactor.swift`
- `Tests/PgAgentMacOSTests/ServerDoctorRedactorTests.swift`

Steps:

1. Implement balanced preset.
2. Implement strict preset.
3. Add metadata counts.
4. Add fixtures.
5. Wire into report generation path.

Verification:

- Redaction tests pass.

### Task 7: Add Heuristics and Validator

Files:

- `Sources/PgAgentMacOS/ServerDoctorHeuristics.swift`
- `Sources/PgAgentMacOS/ServerDoctorReportValidator.swift`
- Tests.

Steps:

1. Add deterministic finding builder.
2. Add report validator.
3. Add mutating action detector for model output.
4. Add invalid evidence tests.

Verification:

- Heuristic report works without model provider.

### Task 8: Add Provider Abstraction

Files:

- `PgAgentApp/ServerDoctorLLMProvider.swift`
- `PgAgentApp/ServerDoctorPromptBuilder.swift`
- `PgAgentApp/ServerDoctorReportGenerator.swift`

Steps:

1. Define provider protocol.
2. Add disabled provider.
3. Add mock provider.
4. Build prompt payload from redacted bundle.
5. Decode and validate model JSON.

Verification:

- Mock provider generates validated report.
- Disabled provider uses heuristics.

### Task 9: Add Store

Files:

- `PgAgentApp/ServerDoctorStore.swift`

Steps:

1. Add observable state.
2. Load preview.
3. Start collection.
4. Redact bundle.
5. Generate report.
6. Publish progress.
7. Handle cancellation.

Verification:

- Store can run from a temporary debug UI.

### Task 10: Add Preview UI

Files:

- `PgAgentApp/ServerDoctorCollectionPreview.swift`

Steps:

1. Render planned commands.
2. Render selected profiles.
3. Render caps and privacy preset.
4. Add start/cancel.
5. Add profile toggles.

Verification:

- No remote command runs before `Start Diagnosis`.

### Task 11: Add Report UI

Files:

- `PgAgentApp/ServerDoctorView.swift`
- `PgAgentApp/ServerDoctorReportView.swift`
- `PgAgentApp/ServerDoctorFindingList.swift`
- `PgAgentApp/ServerDoctorFindingDetail.swift`
- `PgAgentApp/ServerDoctorEvidenceView.swift`
- `PgAgentApp/ServerDoctorCommandsRunView.swift`

Steps:

1. Build split view.
2. Render summary header.
3. Render findings.
4. Render evidence.
5. Render command audit.
6. Add copy/open actions.

Verification:

- All findings have clickable evidence.

### Task 12: Add Entry Points

Files:

- `PgAgentApp/SidebarView.swift`
- `PgAgentApp/CommandPaletteView.swift`
- `PgAgentApp/SystemMonitorView.swift`

Steps:

1. Add feature-flagged sidebar context action.
2. Add command palette item.
3. Add monitor toolbar item.
4. Route to `ServerDoctorView`.

Verification:

- Feature is hidden when flag is disabled.
- Connected host launches Doctor.

### Task 13: Add Persistence

Files:

- `Sources/PgAgentMacOS/ServerDoctorReportStoreModels.swift`
- `PgAgentApp/ServerDoctorReportStore.swift`

Steps:

1. Create app support directory.
2. Save report metadata.
3. Save raw/redacted evidence.
4. Load report history.
5. Add retention cleanup.

Verification:

- Report survives restart.
- Raw evidence cleanup works.

### Task 14: Add Settings

Files:

- `PgAgentApp/SettingsView.swift`
- `PgAgentShared/KeychainManager.swift` if needed.

Steps:

1. Add Server Doctor section under Privacy.
2. Add privacy preset picker.
3. Add retention picker.
4. Add provider disabled/mock/custom options.
5. Add external consent state.

Verification:

- External provider path cannot run without consent.

### Task 15: Final Verification

Run:

```bash
just test-rust
just mac-bindings
just mac-build
```

Run `just mac-test` before merge if local environment allows it.

Manual:

- Broad host diagnosis on Linux.
- nginx missing config or command-not-found scenario.
- permission denied journal scenario.
- provider disabled.
- mock provider.
- strict privacy preset.
- report persistence cleanup.

## Suggested PR Split

PR 1: Models, redactor, validator, heuristics.

PR 2: Rust collector and FFI bindings.

PR 3: Swift bridge and store.

PR 4: Preview/report UI and entry points.

PR 5: Provider settings, persistence, and beta hardening.

This split keeps generated binding churn isolated and makes security review easier.

## Risks and Mitigations

### Risk: FFI Surface Gets Too Large

Mitigation:

- Keep first FFI records simple.
- Avoid deeply nested optional types where not needed.
- Move complex provider/report logic to Swift Codable JSON, not UniFFI.

### Risk: Collector Accidentally Mutates State

Mitigation:

- Constant-only allowlist.
- Read-only guard tests.
- No LLM-generated command execution.
- Manual command audit in preview.

### Risk: Redaction Misses Secrets

Mitigation:

- Test fixtures.
- Strict mode.
- Payload preview.
- External provider consent.
- Never send raw evidence by default.

### Risk: Model Hallucinates

Mitigation:

- Structured schema.
- Evidence ID validation.
- Deterministic fallback findings.
- Confidence rules.
- Render uncited claims as invalid, not as findings.

### Risk: UI Feels Like A Chatbot

Mitigation:

- Report-first design.
- Evidence inspector.
- Commands-run audit.
- Optional scoped Q&A only after first slice.

### Risk: Collection Is Slow Or Blocks Terminal

Mitigation:

- Dedicated bridge queue.
- Per-command timeout.
- Total byte cap.
- Progress UI.
- Cancellation support.

## Open Questions Before Coding

1. Which model provider should be supported first after disabled/mock?
   A: local llama
2. Should provider API keys be stored in the existing Keychain manager or a new Server Doctor credential kind?
   A: keychain manager
3. Should reports sync across devices later, or remain local-only?
   A: syc across devices
4. Should external model support be macOS-only at first?
   A: yes
5. Should the first beta include nginx only, or generic web service detection?
   A: nginx only
6. Should raw evidence be included in diagnostics bundles by default, or always require explicit opt-in?
   A: opt in

## Definition Of Done For First Slice

- Feature flag exists.
- Shared models compile and test.
- Rust preview and collect functions exist.
- Bindings are regenerated.
- Swift bridge can collect a bundle.
- Redaction runs before provider calls.
- Heuristic report works with provider disabled.
- Mock model report validates and renders.
- Collection preview lists exact commands.
- Report UI shows findings, evidence, and command audit.
- Entry point exists from sidebar or command palette.
- No mutating commands exist in the first-slice collector.
- Permission-limited collection produces partial reports.
- Final verification commands have been run or explicitly documented as unavailable.
