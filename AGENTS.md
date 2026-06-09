# AGENTS.md — AI Agent Guide for pgAgent

A code-tour for AI agents (Claude Code, Cursor, etc.) joining this repo cold. Pair with [`README.md`](README.md) (build) and [`TOOLS.md`](TOOLS.md) (features).

## Project shape

Native **macOS + iPadOS** SSH workspace. Swift on top, Rust at the bottom, [uniffi](https://mozilla.github.io/uniffi-rs/) gluing them together.

- **Swift app shell** — AppKit window with SwiftUI views (`PgAgentApp/`), iOS / iPadOS variant (`PgAgentMobile/`), shared models in an SPM framework (`Sources/PgAgentMacOS/`).
- **PTY terminal** — [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (vendored via SPM).
- **Rust FFI crate** (`src/`) — single `[package]`, depends on:
  - [`ssh-commander-core`](https://github.com/asmuelle/ssh-commander-core) — SSH, SFTP, FTP/FTPS, Postgres explorer, connection manager, event bus, macOS Keychain
  - [`ssh-commander-pg-parquet`](https://github.com/asmuelle/ssh-commander-core) — Parquet export pipeline
- **Bindings** (`bindings/`) — uniffi-generated Swift + C header + modulemap. Committed.
- **Xcode project** — generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is gitignored.

## Architecture in one diagram

```
┌─────────────────────────────────────────────────────────────┐
│ PgAgentApp / PgAgentMobile (Xcode targets)                    │
│   SwiftUI views + *Manager / *Store classes                 │
│   SwiftTerm for PTY rendering                               │
└──────────────────────────┬──────────────────────────────────┘
                           │ Swift method calls
┌──────────────────────────▼──────────────────────────────────┐
│ Sources/PgAgentMacOS (SPM framework)                         │
│   Cross-target models, stores, helpers                      │
└──────────────────────────┬──────────────────────────────────┘
                           │ Swift → uniffi → C
┌──────────────────────────▼──────────────────────────────────┐
│ bindings/pg_agent.swift  (generated, committed)             │
│   Swift facade over the Rust FFI                            │
└──────────────────────────┬──────────────────────────────────┘
                           │ C ABI
┌──────────────────────────▼──────────────────────────────────┐
│ src/ffi.rs, src/lib.rs, src/bridge.rs  (uniffi proc-macros) │
│   FFI surface; owns a Tokio runtime; block_on per call      │
└──────────────────────────┬──────────────────────────────────┘
                           │ Rust async
┌──────────────────────────▼──────────────────────────────────┐
│ ssh-commander-core (crates.io)                              │
│   russh + russh-sftp + suppaftp + tokio-postgres + …        │
└─────────────────────────────────────────────────────────────┘
```

## Key files & entry points

| What | Where | Why it matters |
|------|-------|----------------|
| App entry | `PgAgentApp/PgAgentApp.swift` | `@main` SwiftUI App, scene setup |
| FFI entry point on Swift side | `PgAgentApp/BridgeManager.swift` | The single `BridgeManager.initialize()` call routes everything |
| FFI extensions per feature | `BridgeManager+Postgres.swift`, `BridgeManager+Tools.swift` | Postgres explorer, network tools |
| FFI surface | `src/ffi.rs` | The uniffi-exported functions and types — most edits land here |
| FFI runtime | `src/bridge.rs` | Owns the Tokio runtime + connection-manager singleton |
| Swift bindings | `bindings/pg_agent.swift` | **Generated, do not hand-edit** — see "FFI checksum gotcha" below |
| XcodeGen manifest | `project.yml` | Single source of truth for Xcode targets, deps, build phases |
| Rust → static lib | `PgAgentApp/build_cargo.sh` | Xcode build phase: `cargo build` for arm64 + x86_64, `lipo` into `target/universal/release/libpg_agent.a` |
| iOS variant | `PgAgentMobile/Mobile*.swift` | Separate views/stores for iPadOS — keychain, SFTP bridge, etc. |
| Sparkle integration | `PgAgentApp/UpdateManager.swift`, `scripts/find_sparkle_tool.sh` | Auto-updates via Sparkle 2.x |
| Postgres UI | `PgAgentApp/Postgres*.swift` | Browser, query tabs, results table, history, saved queries |
| Network tools UI | `PgAgentApp/NetworkToolsWindow.swift`, `BridgeManager+Tools.swift` | DNS, ports, tcpdump, git status |

## FFI lifecycle

1. **Compile-time** — `cargo build --release` produces `libpg_agent.a` (static for app linking) and `libpg_agent.dylib` (for `uniffi-bindgen` to scan).
2. **Bind-gen** — `cargo run --bin uniffi-bindgen -- generate --library libpg_agent.dylib --language swift` writes `bindings/pg_agent.swift` + `pg_agentFFI.h` + `pg_agentFFI.modulemap`. The justfile recipe (`just mac-bindings`) renames the modulemap to `module.modulemap` so Swift auto-discovers it.
3. **Build** — Xcode links the static lib with `-lpg_agent`; the bindings expose Swift-native types.
4. **Init** — Swift calls `BridgeManager.initialize()` once at app start. This invokes `rshellInit()` which uniffi-runtime-checks contract version + per-function checksums against the lib. **Mismatch = `_assertionFailure`**.

## Coding conventions

### Rust (FFI)

- `PascalCase` for types, `snake_case` for functions
- `Result<T, FfiPg…>` (or `String`) at the FFI boundary; `anyhow::Result<T>` internally
- Every FFI fn that hits the network does `RUNTIME.block_on(async { … })` — see existing patterns in `ffi.rs`
- New FFI fn: define in `ffi.rs` with `#[uniffi::export]`, then run `just mac-bindings`, then **commit the regenerated bindings**

### Swift

- SwiftUI views + dedicated `*Store` / `*Manager` classes for state
- `BridgeManager` is the single FFI entry point; per-feature extensions follow `BridgeManager+<Feature>.swift`
- `@MainActor` on UI-mutating code; off-main work goes through `Task` or `DispatchQueue.global()`
- Keychain access via `KeychainManager.swift` (macOS) / `MobileSSHKeyVault.swift` (iOS)

## Common pitfalls (read before debugging)

1. **FFI checksum gotcha.** Hand-editing `bindings/pg_agent.swift` will appear to work — symbols resolve fine — but uniffi computes a per-function checksum from the FFI signature and bakes it into both the lib and the bindings. They have to match. Always regenerate via `just mac-bindings`. Symptom: `Thread … Crashed: rshellInit() → _assertionFailure`.
2. **Stale Xcode SourcePackages.** Xcode caches absolute paths to SPM artifacts (Sparkle, SwiftTerm). Renaming or moving the repo root breaks them. Symptom: `error: There is no XCFramework found at .../Sparkle.xcframework`. Fix: `rm -rf build .build Mc-Ssh.xcodeproj && just mac-gen && just mac-build`.
3. **Bundle ids and Xcode schemes still say `mc-ssh` / `PgAgent*`.** Intentional — repo was extracted from the upstream mc-ssh project; renaming the bundle id changes app-data paths and signing identities, so it's deferred. The build artifacts (`pgAgent.app`, `libpg_agent.a`) carry the new brand.
4. **TOFU host-key store.** SSH known-hosts live at `$XDG_CONFIG_HOME/pgAgent/known_hosts` via `ssh-commander-core`. Unreadable / unwritable trust state fails closed — do not loosen.
5. **iPad simulator selection.** `just run-on-ipad` defaults to any booted iPad sim, falls back to the first available. Pass a name fragment to pin: `just run-on-ipad "iPad Pro"`.
6. **`build_cargo.sh` runs every build.** The Xcode build phase is intentionally not gated by dependency analysis (cargo's incremental layer handles that). The "will be run during every build" note in xcodebuild output is expected, not a misconfiguration.
7. **Universal lib lipo step.** `mac-rust` builds `aarch64-apple-darwin` + `x86_64-apple-darwin` separately and `lipo`s them — the resulting fat archive is what Xcode actually links. CI runners that build only one slice (`mac-ci-build`) skip the lipo and link single-arch.

## Tests

```bash
just test               # cargo test + xcodebuild test (framework + app)
just test-rust          # Rust only
just mac-test           # Swift only (PgAgentMacOS framework + PgAgentApp FFI integration)
```

Test targets in `Tests/`:
- `PgAgentMacOSTests/` — pure-Swift unit tests over models / helpers
- `PgAgentAppTests/` — exercises the uniffi bindings inside the app's process (real FFI, no mocks)
- `PgAgentBetaSmokeTests` — end-to-end smoke covering the connect / list / disconnect path

## When in doubt

- The build pipeline is `just`-driven. Read [`justfile`](justfile) before inventing your own commands.
- The FFI surface lives in [`src/ffi.rs`](src/ffi.rs). The Swift facade lives in [`bindings/pg_agent.swift`](bindings/pg_agent.swift) — generated.
- The Xcode project is regenerated from [`project.yml`](project.yml) — never hand-edit the `.xcodeproj`.
- For protocol-layer questions (SSH, SFTP, Postgres), the source is in the [`ssh-commander-core`](https://github.com/asmuelle/ssh-commander-core) repo, not here.
