# TOOLS.md — In-app feature catalog

What pgAgent actually does, surface by surface. Pair with [`AGENTS.md`](AGENTS.md) (architecture) and [`README.md`](README.md) (build).

> Conventions: each section names the **user-visible feature**, the **Swift entry point** (where the UI lives), and the **FFI / Rust call** behind it (where the work happens). When a feature is iPadOS-only, mac-only, or both, it's marked.

---

## Connection management

### Profiles & sidebar

- **macOS**: `SidebarView.swift`, `ConnectionStoreManager.swift`, `ConnectionEditView.swift`
- **iPadOS**: `MobileConnectionStore.swift`, `MobileConnectionEditorView.swift`, `MobileContentView.swift`
- Persistent connection profiles, grouped by tag, drag-and-drop reordering, import/export.

### SSH key vault

- `SSHKeyVault.swift`, `SSHKeyAccessCoordinator.swift` (macOS) / `MobileSSHKeyVault.swift`, `MobileSSHKeyImportStore.swift` (iPadOS)
- Stores generated and imported private keys in the macOS Keychain / iOS Keychain. Coordinates per-key access prompts so a single SSH session doesn't trigger the auth dialog repeatedly.

### Credentials

- `CredentialResolver.swift`, `KeychainManager.swift`
- FFI: `rshell_keychain_*` (load / save / list / delete / is_supported)
- Passwords and key passphrases live in Keychain only; never on disk in plaintext.

### Host-key trust

- `HostKeyPrompt.swift`
- FFI: surfaced via the SSH `connect` flow as `HostKeyVerificationFailure` enums (unknown host, mismatch). UI offers trust-and-continue or abort.
- TOFU known-hosts file at `$XDG_CONFIG_HOME/pgAgent/known_hosts`. Unreadable trust state fails closed.

---

## Terminal

### PTY sessions (macOS)

- `TerminalView.swift`, `TerminalSessionManager.swift`, `TerminalTabsStore.swift`, `TerminalThemes.swift`, `TerminalSearchBar.swift`
- SwiftTerm renderer, full xterm-256color, regex search, theme picker.
- FFI: `rshell_connect`, PTY data flows through the typed event bus (`PtyOutput` events) into the SwiftTerm view.

### Tabs & layout

- `TabBarView.swift`, `LayoutManager.swift`, `WorkspaceSplitController.swift`
- Tabbed sessions, split panes, layout presets persisted via `LayoutManager`.

### Command palette

- `CommandPaletteView.swift`
- ⌘K palette over connections, saved queries, layout presets.

---

## File transfer

### Dual-pane file browser (macOS)

- `DualPaneFileBrowserView.swift`, `FileBrowserView.swift`, `LocalFileBrowserView.swift`, `FileOperationsManager.swift`, `FilePermissionsEditor.swift`
- Side-by-side local / remote, drag-and-drop transfer, chmod, rename, recursive copy.
- FFI: `rshell_listing_*`, `rshell_transfer_*` — emits `TransferProgress` events to the UI.

### File diff & edit

- `FileDiffReviewSheet.swift`, `FileEditView.swift`, `SafeConfigSave.swift`
- Three-way diff before overwriting remote configs. `SafeConfigSave` enforces "snapshot before write" so a typo in `nginx.conf` doesn't take a host down.

### Transfer queue

- `TransferQueueStore.swift`
- Queued + in-flight uploads / downloads, pause / resume, retry on failure.

---

## PostgreSQL workspace

### Browser & schema tree

- `PostgresBrowserView.swift`, `PostgresBrowserWindow.swift`, `PgSchemaStore.swift`
- Multi-database tree (databases → schemas → tables / views / mat-views / partitioned / foreign tables / sequences / functions).
- FFI: `rshell_pg_list_databases`, `rshell_pg_list_schemas`, `rshell_pg_list_relations`, `rshell_pg_list_schema_contents`.

### Query tabs

- `PostgresQueryTab.swift`, `PostgresQueryTabView.swift`, `PostgresWorkspaceView.swift`, `PostgresResultsTable.swift`
- Per-tab cursor, multi-statement scripts (`SET … ; SELECT …`), paginated results, column affinity inference, history, saved queries.
- FFI: `rshell_pg_execute`, `rshell_pg_fetch_page`, `rshell_pg_close_query`, `rshell_pg_cancel`.

### Inline editing

- `PostgresInsertRowSheet.swift`, `PostgresColumnWidthStore.swift`, `PostgresColumnAffinity.swift`
- Click-to-edit cells with unsaved-edits indicator, type coercion via column affinity.
- FFI: `rshell_pg_update_cell`, `rshell_pg_insert_row`, `rshell_pg_delete_rows`.

### Export

- `PostgresExportProgressSheet.swift`
- Cursor-paginated CSV / JSONL / Parquet export — drains the cursor, streams to disk, handles unbounded results.
- FFI: `rshell_pg_parquet_*` (depends on `ssh-commander-pg-parquet`).

### History & saved queries

- `PostgresHistoryPopover.swift`, `PostgresHistoryStore.swift`, `PostgresSavedQueriesPopover.swift`, `PostgresSavedQueriesStore.swift`, `PostgresSavedQueryEditSheet.swift`
- Per-profile history with full-text search, pinned saved queries.

### SSH tunneling

- Configured in `PostgresConnectionEditView.swift`; profile carries `SshTunnelRef` referencing an SSH connection.
- FFI: tunnels are opened lazily by `ssh-commander-core` when the pool first dials in. One tunnel per Postgres profile, shared by every pooled connection.

---

## Network tools

### Tools window

- `NetworkToolsWindow.swift`, `BridgeManager+Tools.swift`
- Single window with tabs for each tool, runs over an existing SSH connection (no separate auth).

| Tool | FFI | What it does |
|------|-----|---------------|
| **DNS** | `rshell_dns_resolve` | Multi-perspective resolution across all currently-connected hosts |
| **Listening ports** | `rshell_listening_ports` | `ss` / `netstat` listening-port inventory with PID + process name |
| **tcpdump** | `rshell_tcpdump_*` | Streaming packet capture (`tcpdump -lnn`), lines emitted to event bus for real-time UI |
| **git status** | `rshell_git_status` | Deploy-state snapshot of a remote repo (branch, ahead/behind, dirty flag) |

---

## System monitoring

### macOS

- `SystemMonitorView.swift`, `MonitorPanel.swift`, `MonitorPollingManager.swift`, `MonitorTabView.swift`
- CPU, memory, disk, load average; per-host poller with configurable cadence.
- FFI: `rshell_get_system_stats`.

### Charts

- `ChartView.swift`
- SwiftUI Charts-based time-series for any monitor metric.

### Process list

- `ProcessListView.swift`, `ProcessPanel.swift`
- `top` / `ps` parsed remotely; sortable, filterable, kill action.
- FFI: `rshell_get_processes`.

### iPadOS overview

- `MobileServiceMonitorViews.swift`, `MobileSystemHealthMobileView.swift`, `MobileServerDoctorView.swift`, `MobileConnectionConfidenceView.swift`
- Read-mostly cards optimized for touch; "is this host healthy?" at a glance.

---

## Logs

- `LogPanel.swift`
- Stream a remote log file (or `journalctl` unit) into a scrollable panel with regex highlight + follow-tail.

---

## Runbooks (iPadOS)

- `RunbooksPanelView.swift` (macOS), `MobileRunbookExecutionStore.swift`, `MobileRunbookFlightDeck.swift`, `MobileRunbookLibraryView.swift`, `MobileRunbookFlightDeckScripts.swift`
- Repeatable command sequences (e.g., "rotate logs", "drain → restart → reattach"). Each step is recorded; partial failures are flagged for triage.

---

## iPadOS-specific surfaces

| Feature | File | Purpose |
|---------|------|---------|
| Activity log | `MobileActivityLogStore.swift` | Per-session timeline of every command + result |
| Connection map | `MobileConnectionMapView.swift` | Visual overview of which hosts are reachable, by latency bucket |
| Privacy gate | `MobilePrivacyGateView.swift` | Per-feature "are you sure" — locks destructive surfaces (kill process, delete file) behind Face ID |
| Security vault | `MobileSecurityVaultView.swift` | Master view of stored keys, certs, known hosts |
| Incident report builder | `MobileIncidentReportBuilder.swift` | Capture state + commands + screenshots into a shareable bundle for postmortem |
| Diagnostics bundle | `MobileDiagnosticsBundle.swift` | Self-diag dump (Keychain reachability, FFI version, network status) |
| Remote task runner | `MobileRemoteTaskRunner.swift` | Long-running tasks survive backgrounding via `BGTaskScheduler` |
| SFTP bridge | `MobileSFTPBridge.swift` | Files-app integration so SFTP shows up as a Files location |

---

## App-level tooling

| Surface | File | Purpose |
|---------|------|---------|
| Auto-updates | `UpdateManager.swift`, Sparkle 2 | Background check + delta updates (macOS) |
| Crash reporter | `CrashReporter.swift` | Capture, store, and offer to upload crash logs |
| Diagnostics bundle | `DiagnosticsBundle.swift` (macOS), `MobileDiagnosticsBundle.swift` (iPadOS) | One-shot "give me a state dump for support" |
| Settings | `SettingsView.swift` | Themes, fonts, default shells, Sparkle channel |
| Import manager | `ImportManager.swift` | Bring in connections / keys from other clients |
| Workspace notifications | `WorkspaceNotifications.swift` | Notification center hub for transfer progress, monitor alerts, runbook completion |
| Connection confidence | `ConnectionConfidenceView.swift` | Per-host signal: "this connection has been reliable" / "flaking lately" |

---

## Build & FFI tooling

| Tool | Where | Run via |
|------|-------|---------|
| Universal Rust static lib | `PgAgentApp/build_cargo.sh` | Xcode build phase, or `just mac-rust` |
| iOS Rust slices | `scripts/build_cargo_ios.sh` | Xcode build phase for the iOS target |
| Swift binding regen | `cargo run --bin uniffi-bindgen` | `just mac-bindings` |
| Xcode project regen | `xcodegen generate` | `just mac-gen` |
| DMG packaging | `PgAgentApp/build_dmg.sh` | `just mac-dmg` |
| Release bundle | `scripts/mac_release.sh` | `just mac-release [notarize=true]` |
| Sparkle keygen / appcast | `scripts/find_sparkle_tool.sh` | `just mac-sparkle-keygen`, `just mac-sparkle-appcast` |

---

## Feature flags

`EntitlementsStore.swift` (macOS) / `MobileEntitlementsStore.swift` (iPadOS) gate work-in-progress features behind a runtime toggle. Flip a flag → feature surfaces in the UI. Use this for any feature that isn't ready for the default UI but needs to be reachable for testing.
