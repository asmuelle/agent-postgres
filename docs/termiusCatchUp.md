# Termius Catch-Up

Generated: 2026-05-11

Scope: Termius features that are publicly advertised by Termius, but are not currently documented in pgAgent / mc-ssh and are also not publicly advertised by Secure ShellFish. I treated disabled `FeatureFlags` in mc-ssh as not shipped.

## Sources Checked

- Local mc-ssh feature catalog: `README.md`, `TOOLS.md`, `Sources/PgAgentMacOS/FeatureFlags.swift`
- Existing ShellFish parity notes: `shellfisch_catchup.md`
- Termius product, docs, pricing, App Store, and ecosystem pages:
  - https://termius.com/
  - https://termius.com/pricing
  - https://termius.com/documentation
  - https://termius.com/documentation/set-up-vaults
  - https://termius.com/documentation/collaborate
  - https://termius.com/vault
  - https://apps.apple.com/us/app/termius-modern-ssh-client/id549039908
  - https://termius.com/blog/keep-connection-details-up-to-date-with-api-bridge
  - https://termius.com/blog/termius-integration-with-ansible
  - https://sshid.io/
  - https://termius.com/gloria
- Secure ShellFish product and App Store pages:
  - https://secureshellfish.app/
  - https://apps.apple.com/us/app/ssh-client-secure-shellfish/id1336634154

## Excluded Because ShellFish or mc-ssh Already Covers It

These Termius features are not catch-up gaps for this filtered list: SSH, SFTP, multi-tab terminals, split views, custom keyboard bars, snippets in general, Files/Finder integration, offline SFTP folders, Share Sheet uploads, Shortcuts automation, filename-aware terminal actions, tmux session picker/reconnect, general port forwarding, SOCKS/HTTP proxy, DigitalOcean management, security keys, Secure Enclave or biometric Apple keys, SSH certificates, Live Activities, widgets, Tailscale polish, Multipath TCP, post-quantum KEX, remote log viewing, basic key generation/import, and local password/keychain storage.

## Platform And Protocol Gaps

1. Windows client.
2. Linux client.
3. Android client.
4. Cross-platform account sync across macOS, Windows, Linux, iOS, iPadOS, and Android.
5. Telnet protocol support.
6. Mosh protocol support.
7. Serial connection support.
8. Local terminal mode.
9. Jump host / host chain support for SSH connection routing.
10. SSH agent forwarding.

## Vault, Sync, And Team Sharing Gaps

1. End-to-end encrypted Termius-style cloud vault for hosts, groups, keys, credentials, snippets, port-forwarding rules, and known hosts.
2. Personal cloud vault separate from purely local storage.
3. Team vault for shared infrastructure data.
4. Multiple shared vaults for separating projects, clients, environments, or departments.
5. Granular vault-level access control.
6. Secure sharing of passwords, keys, certificates, snippets, hosts, and forwarding rules with teammates.
7. Shared known-host fingerprints so one verified host key can be reused by the team.
8. Shared port-forwarding rules managed centrally for team members.
9. Shared snippet packages that act like a terminal-runbook knowledge base.
10. Group-level configuration inheritance for hosts.
11. Host model that can carry multiple protocols/settings for the same machine rather than only independent connection profiles.
12. Cross-device offline vault cache backed by cloud sync.
13. Import paths explicitly covering CSV, `~/.ssh/config`, PuTTY, SecureCRT, and MobaXTerm.

## Collaboration And Audit Gaps

1. Real-time terminal multiplayer.
2. Terminal sharing via link.
3. Team-visible session logs by host.
4. Session logs synced across devices.
5. Session logs shared with team members for handoff and audit.
6. Session-log bookmarks.
7. Session-log comments.
8. Session-log retention policies.
9. Custom retention controls for enterprise teams.
10. Recent session views by host, device, and team member.

## Terminal Productivity Gaps

1. AI-powered / IDE-style terminal autocomplete for commands, arguments, and paths.
2. AI command widget with generated-command history.
3. AI command generation from selected terminal-output context.
4. Generated-command snippet packages.
5. Host-level CLI agent launch profiles for tools like Gemini, Claude Code, and OpenCode.
6. Unified shell command history across terminal sessions.
7. Shell command history synced across devices.
8. Custom environment variables per host or connection.
9. Startup snippets that run automatically at connection start.
10. Snippet multi-execution across multiple sessions or servers.
11. Per-connection terminal theme and font profiles.

## Inventory And Automation Integration Gaps

1. AWS infrastructure integration.
2. Azure infrastructure integration.
3. API Bridge: a self-hosted REST bridge that accepts infrastructure data, encrypts it locally, and syncs it into Termius vaults.
4. NetBox / private-cloud style inventory synchronization through API Bridge.
5. Ansible role for creating/updating Termius hosts and groups from provisioning playbooks.
6. Vanta integration.

DigitalOcean is intentionally excluded because ShellFish already advertises DigitalOcean server management. Hetzner is also excluded because ShellFish advertises it and Termius does not currently surface it as a top-level pricing-matrix integration.

## Security And Compliance Gaps

1. Account-level two-factor authentication.
2. SAML SSO.
3. Approved-domain controls.
4. Team management console.
5. SOC 2 Type II report access / trust-center posture.
6. App-level PIN lock as a first-class account/device protection surface.
7. SSH.id-style public-key handle for provisioning device-bound SSH passkeys.
8. Cross-platform biometric key support beyond Apple platforms, including Windows Hello and Android biometrics.
9. ML-DSA key generation and authentication, where server support exists.

## Commercial And Enterprise Account Gaps

1. Consolidated team billing.
2. Purchase-order support.
3. Bank-transfer payment support.
4. Custom commercial terms.
5. Priority support tier.
6. Dedicated success manager.
7. Migration and onboarding support.
8. Enterprise SLA.

## Adjacent Termius Ecosystem Gap

Termius is also promoting Gloria / GloriaOps as an adjacent AI DevOps agent rather than a core SSH-client feature. It is not a direct ShellFish or mc-ssh parity item, but it is part of the broader Termius competitive surface.

1. AI agent for routine DevOps tasks over SSH.
2. Run services on a remote server with installation, port binding, and verification.
3. Install and run Docker containers on a remote host.
4. Containerize a simple app, build an image, and run it.
5. Analyze logs and suggest/apply fixes. Termius marks this as in progress.
6. Manage disk space. Termius marks this as planned.
7. Provision/deprovision access. Termius marks this as planned.
8. Spin up cloud machines and preconfigure access. Termius marks this as planned.

## Recommended Catch-Up Order

1. Protocol and routing basics: Telnet, Mosh, serial, local terminal, jump hosts / host chains, and agent forwarding.
2. Terminal productivity: unified command history, environment variables, startup snippets, snippet multi-execution, and AI autocomplete.
3. Vault foundation: personal cloud vault, cross-platform sync-ready data model, imports, and group inheritance.
4. Team vaults: sharing, granular access, shared known hosts, shared snippets, and shared forwarding rules.
5. Collaboration and audit: multiplayer, share links, session logs, bookmarks, comments, and retention.
6. Infrastructure integrations: AWS, Azure, API Bridge, Ansible, and Vanta.
7. Enterprise controls: SSO, 2FA, approved domains, team console, billing, SOC 2 posture, SLA, and onboarding.
8. Optional ecosystem bet: Gloria-style AI DevOps agent only after the vault/team substrate exists.
