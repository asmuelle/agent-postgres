# ShellFish Catch-Up Plan

This plan closes the user-visible gaps where Secure ShellFish is ahead of pgAgent while preserving pgAgent's existing strengths in Postgres, monitoring, diagnostics, runbooks, and network tools.

## Phase 1: Foundation

1. Add a durable shared storage layer.
   - Extend shared models in `Sources/PgAgentMacOS/` for snippets, offline folders, forwarding profiles, cloud accounts, advanced auth identities, and background SSH operations.
   - Use explicit schema versions for migration-safe JSON files.
   - Store extension-shared files in the existing App Group container.

2. Add feature flags for the ShellFish-parity surfaces.
   - File Provider / Files app integration.
   - Share Sheet uploads.
   - Shortcuts automation.
   - Offline SFTP cache.
   - iCloud sync.
   - Filename-aware terminal.
   - tmux session manager.
   - General SSH port forwarding.
   - Advanced authentication.
   - Live Activities / watch surfaces.
   - Cloud server management.
   - Tailscale / Multipath network polish.

3. Add extension target scaffolding in `project.yml`.
   - File Provider extension.
   - Share extension.
   - App Intents / Shortcuts extension.
   - Later: iOS Widget / Live Activity and watchOS targets.

4. Create a shared background SSH operation model.
   - Record resumable uploads, downloads, offline syncs, Shortcuts runs, Share uploads, File Provider fetches, and port-forward sessions.
   - Persist status, progress, errors, requester, and approval policy.

## Phase 2: Files App Parity

1. Build a real File Provider extension.
   - Expose SFTP roots as Files/Finder locations.
   - Implement browse, download, upload, create folder, rename, delete, and metadata.
   - Reuse existing SFTP FFI calls and mobile bridge concepts.

2. Add offline folders.
   - Let users mark remote folders for offline use.
   - Sync to a local cache with freshness and conflict metadata.
   - Surface sync state in the app and File Provider UI.

3. Add in-place editing support.
   - Coordinate file versions between File Provider cache and SFTP.
   - Reuse safe-save semantics for remote config edits where possible.

4. Add Share Sheet uploads.
   - Upload files/directories from other apps to a saved server path.
   - Remember last destination per content kind and server.

## Phase 3: Shortcuts Automation

1. Add App Intents for:
   - List servers.
   - Upload file.
   - Download file.
   - Run command.
   - Open terminal.
   - Sync offline folder.
   - Tail log or start monitor.

2. Return useful automation results.
   - File URLs, stdout/stderr, exit status, transfer stats, and actionable errors.

3. Add an automation-safe credential policy.
   - Manual approval, biometric approval per run, or explicitly allowed background execution.

## Phase 4: Terminal Ergonomics

Implementation status: completed for first-pass ShellFish parity. The shipped slice covers terminal path detection with SFTP verification, mobile path preview/copy/download/share/drag actions, customizable accessory keys, snippet variables/delays/control tokens with shared snippet storage, tmux session/window/pane attachment, deep links, and Handoff-ready route activity declarations.

1. Add filename-aware terminal output.
   - Detect likely remote paths in output.
   - Verify through SFTP/stat before exposing file actions.
   - Add context menu actions: preview, copy path, download, share, drag.

2. Improve mobile keyboard and snippets.
   - Make accessory keys customizable.
   - Support delays, variables, and control sequences.
   - Sync snippets once sync exists.

3. Build a tmux session manager.
   - Detect tmux availability.
   - List sessions/windows/panes.
   - Let users connect directly to an existing session or create a named session.
   - Add reconnect flow after network loss or app backgrounding.

4. Add deep links and Handoff-ready routing.
   - Open a server, folder, terminal, or saved automation by URL.

## Phase 5: Sync

Implementation status: completed for first-pass ShellFish parity. The shipped slice adds migration-safe iCloud snapshot records for non-secret profile metadata, snippets, and terminal settings; preserves passwords and passphrases in local Keychain; applies timestamp-based conflict handling; and adds CSV import/export with diff preview and stable-ID updates.

1. Sync profile metadata.
   - Use iCloud Keychain or CloudKit for non-secret profile data.
   - Keep secrets in Keychain.

2. Sync snippets and settings.
   - Use migration-safe records and timestamp-based conflict handling.

3. Improve import/export.
   - Add CSV import with diff preview.
   - Update existing records by stable ID.

## Phase 6: Port Forwarding

Implementation status: completed for first-pass ShellFish parity. The shipped slice adds a Rust forwarding registry exposed through UniFFI, local `direct-tcpip` forwards, dynamic SOCKS5 proxying, profile/runtime persistence, macOS and iPad controls, auto-start support, widget snapshots, and app-group runtime records that Live Activity surfaces can consume. Remote forwarding profiles are modeled and editable, but starting them returns a typed unsupported error until `ssh-commander-core` exposes server-side `tcpip-forward` callbacks.

1. Add general SSH forwarding in the Rust/core layer.
   - Local forward.
   - Remote forward.
   - Dynamic SOCKS proxy.

2. Add a Swift UI.
   - Persist forwarding profiles.
   - Start/stop/restart.
   - Show duration, bytes in/out, bound ports, and errors.

3. Integrate forwarding with widgets and Live Activities.

## Phase 7: Advanced Authentication

Implementation status: completed for first-pass ShellFish parity. The shipped slice adds durable advanced-auth identity records, Secure Enclave P-256 identity generation with biometric-gated signing tests, manual OpenSSH certificate import, security-key public identity import, macOS and iPad vault surfaces, connection-profile references for advanced identities, ssh-agent approval prompts with Once / 5 minutes / 60 minutes / current session windows, and agent-backed authentication for imported SSH certificates or security-key identities when the matching identity is available from `SSH_AUTH_SOCK`. Secure Enclave identities remain non-exportable and can be generated/test-signed, but starting a real SSH connection with them returns a typed unsupported path until the Rust SSH layer exposes an external signer / agent bridge.

1. Add Secure Enclave keys.
   - Generate non-exportable identities.
   - Use biometric-gated signing.

2. Add security key support.
   - NFC first on iOS, then USB where platform and SSH library support allow it.

3. Add SSH certificate identities.
   - Manual certificate import first.
   - Then CA/OIDC issuance for short-lived certificates.

4. Add agent approval windows.
   - Once, 5 minutes, 60 minutes, or current connection/session.

## Phase 8: Widgets, Live Activity, Watch

Implementation status: completed for first-pass ShellFish parity. The shipped slice adds an iOS WidgetKit extension that reads the existing monitoring snapshot model, ActivityKit/Dynamic Island rendering for long-running commands, transfers, and tunnels, shared Live Activity snapshot persistence, server-controlled `pgAgent://notify`, `pgAgent://widget`, and `pgAgent://live-activity` shell integration commands parsed from PTY output, mobile session snapshot publishing, and a watch status payload with read-only items plus guarded quick-action records for approvals, tunnel stops, and open-in-app handoffs.

1. Add iOS widgets using the existing monitoring snapshot model.
2. Add Live Activities / Dynamic Island for long-running commands, transfers, and tunnels.
3. Add server-controlled widget/notify shell integration commands.
4. Add watchOS read-only status and guarded quick actions.

## Phase 9: Cloud Providers

Implementation status: completed for first-pass ShellFish parity. The shipped slice adds a shared cloud provider abstraction, app-group inventory snapshots, DigitalOcean and Hetzner HTTP clients for inventory/create/delete/reboot, secure macOS Keychain storage for provider API tokens, a macOS Cloud settings surface for account setup, refresh, server creation, reboot, deletion, and SSH profile generation, plus tests covering provider request/response mapping and stable profile generation from cloud metadata.

1. Add a provider abstraction for cloud APIs.
2. Implement DigitalOcean inventory/create/delete/reboot.
3. Implement Hetzner inventory/create/delete/reboot.
4. Generate SSH profiles from cloud server metadata.

## Phase 10: Network Polish

Implementation status: completed for first-pass ShellFish parity. The shipped slice adds per-profile network options, Tailscale-aware DNS preflight for system/prefer/require Tailnet modes, optional Tailnet host overrides on macOS and iPad connection editors, connect-time enforcement before opening SSH, URLSession Multipath TCP service selection for HTTP transports that can use it, and an explicit network audit surface. The audit keeps SSH Multipath and post-quantum KEX UI gated because the current Rust path uses `russh` over `tokio::net::TcpStream` and the bundled `russh` KEX list does not expose `sntrup761x25519-sha512@openssh.com` or `mlkem768x25519-sha256`.

1. Add Tailscale-aware host resolution.
2. Add Multipath TCP mode where the underlying transport supports it.
3. Audit post-quantum SSH KEX support in the Rust SSH stack before exposing UI.

## Recommended Order

Build in this order: File Provider, Shortcuts, Share extension, port forwarding, tmux manager, sync, advanced auth, Live Activities/watch, cloud providers, then network polish.

The largest risks are File Provider correctness, background credential access, general SSH forwarding in the Rust layer, and security-key support depending on what the SSH library exposes.
