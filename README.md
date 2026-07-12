# pgAgent

[![CI](https://github.com/asmuelle/agent-postgres/actions/workflows/ci.yml/badge.svg)](https://github.com/asmuelle/agent-postgres/actions/workflows/ci.yml)

Native macOS / iPadOS SSH workspace. AppKit + SwiftUI shell, SwiftTerm for the PTY, [`ssh-commander-core`](https://github.com/asmuelle/ssh-commander-core) for the protocol layer, [uniffi](https://mozilla.github.io/uniffi-rs/) for the FFI bridge.


## Stack

| Layer | Lives in | Notes |
|-------|----------|-------|
| App shell | `PgAgentApp/`, `PgAgentMobile/` | AppKit window + SwiftUI views, SwiftTerm |
| Swift framework | `Sources/PgAgentMacOS/` | Cross-target models, stores |
| FFI bridge | `src/` | Rust → Swift via uniffi proc-macros |
| Generated bindings | `bindings/` | `midnight_ssh.swift`, `midnight_sshFFI.h`, `module.modulemap` |
| Protocol layer | crates.io: `ssh-commander-core`, `ssh-commander-pg-parquet` | external |
| Xcode project | `Mc-Ssh.xcodeproj` | generated from `project.yml` by xcodegen |

## Prerequisites

- macOS 14+ with Xcode 15+ and command-line tools (`xcode-select --install`)
- PostgreSQL **14+** for database connections and fleet monitoring
- Rust **1.95+** (edition 2024) — `rustup default stable`
- [`just`](https://github.com/casey/just) — `brew install just`
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen` (auto-installed by `just mac-bootstrap`)

Verified backup and restore jobs run on the profile's SSH execution host. That
host needs compatible `pg_dump` / `pg_restore` / `psql` binaries and a mode-0600
`~/.pgpass` entry. Direct managed-cloud databases can use a small SSH runner or
jump host with network access to the provider endpoint.

```bash
just bootstrap          # one-time: xcodegen + macOS + iOS Rust targets
```

## Build & run

```bash
# Native macOS app (ad-hoc signed, opens Finder window)
just mac-build
just mac-run

# iPad simulator (boots a sim, installs, launches)
just run-on-ipad-sim "iPad Pro"

# Physical iPad connected over USB/Wi-Fi (auto-provisions, installs, launches)
just run-on-ipad Dashboard

# Full local CI pass
just ci-local
```

Run `just` (no args) for the full recipe list.

## Common workflows

### Edit Rust FFI surface

```bash
# 1. Edit src/ffi.rs or src/lib.rs
# 2. Regenerate Swift bindings
just mac-bindings
# 3. Rebuild
just mac-build
```

The bindings under `bindings/` are committed — regenerate and commit them whenever the FFI changes. Hand-patching `bindings/midnight_ssh.swift` will appear to work but the per-function uniffi checksums will diverge from what the Rust lib reports at runtime, and `rshellInit()` will panic with `_assertionFailure`.

### Edit `project.yml`

```bash
just mac-gen            # regenerate Mc-Ssh.xcodeproj
```

The xcodeproj is gitignored — `mac-gen` is automatic before any `mac-*` build via `_ensure-xcodeproj`.

### Sign + notarize a release DMG

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="…"
export APPLE_TEAM_ID="…"
export APPLE_APP_SPECIFIC_PASSWORD="…"

just mac-release true   # build → DMG → notarize → staple
```

For a build-only DMG without notarization, drop the env vars and run `just mac-release` (defaults to `false`).

### Sparkle auto-updates

```bash
just mac-sparkle-keygen            # one-time, populate Info.plist with the public key
just mac-sparkle-appcast ./dist    # generate appcast.xml from a folder of DMGs
```

## Repo layout

```
.
├── Cargo.toml              # FFI crate manifest
├── build.rs                # uniffi build hook
├── uniffi-bindgen.rs       # bindgen entry point (cargo run --bin uniffi-bindgen)
├── src/                    # Rust FFI bridge (bridge.rs, ffi.rs, monitor.rs)
├── bindings/               # generated Swift bindings (committed)
├── project.yml             # XcodeGen manifest (single source of truth)
├── Mc-Ssh.xcodeproj/      # generated; gitignored
├── Package.swift           # SPM wrapper around the static lib
├── Sources/PgAgentMacOS/    # cross-target Swift framework (models + stores)
├── PgAgentApp/              # macOS app target — SwiftUI views + managers
├── PgAgentMobile/           # iPadOS / iOS app target
├── Tests/                  # XCTest harness (PgAgentMacOS + PgAgentApp + Beta smoke)
├── scripts/                # release, notarize, find-sparkle-tool helpers
├── justfile                # command surface
├── README.md               # you are here
├── AGENTS.md               # AI-agent code tour
└── TOOLS.md                # in-app feature catalog
```

## Troubleshooting

**`error: There is no XCFramework found at .../Sparkle.xcframework`** — stale Xcode SourcePackages cache pinned to the old absolute path. Wipe and regenerate:
```bash
rm -rf build .build Mc-Ssh.xcodeproj
just mac-gen
just mac-build
```

**`Thread 3 Crashed: rshellInit() → _assertionFailure`** — uniffi binding checksums don't match the rebuilt Rust lib. Always regenerate via `just mac-bindings` after touching the FFI; never hand-edit the generated Swift.

**Build is slow on first run** — `russh` and `parquet` (transitive via `ssh-commander-pg-parquet`) compile from source. Subsequent incremental builds are fast.
